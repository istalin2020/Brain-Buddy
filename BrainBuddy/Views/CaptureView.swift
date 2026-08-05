import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The inbox. Anything you want to remember goes in here, in whatever form it
/// arrives — typed, spoken, photographed, or dropped in as a file.
@MainActor
struct CaptureView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<MemoryItem> { !$0.isTrashed },
        sort: \MemoryItem.createdAt,
        order: .reverse
    )
    private var memories: [MemoryItem]

    @State private var draft: String = ""
    @State private var showVoiceCapture = false
    @State private var showPhotoPicker = false
    @State private var showScanner = false
    @State private var showFileImporter = false
    @State private var photoSelections: [PhotosPickerItem] = []
    @State private var errorMessage: String?
    /// The draft as it stood when dictation started. Non-nil exactly while *this*
    /// screen owns the recognizer, which is also how the UI knows to show itself
    /// as listening — `transcriber.isListening` alone would light up while the
    /// Ask tab is the one holding the microphone.
    @State private var dictationBase: String?
    @FocusState private var isEditorFocused: Bool

    private var transcriber: SpeechTranscriber { services.transcriber }
    private var isDictating: Bool { dictationBase != nil }

    private var recentMemories: [MemoryItem] { Array(memories.prefix(4)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    editor
                    captureButtons
                    if services.ingest.isBusy { progressBanner }
                    recentSection
                }
                .padding()
            }
            .navigationTitle("Capture")
            .navigationDestination(for: MemoryItem.self) { item in
                MemoryDetailView(item: item)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { saveDraft() }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) {
                    if isEditorFocused {
                        Button("Done") { isEditorFocused = false }
                    }
                }
            }
            .sheet(isPresented: $showVoiceCapture) {
                VoiceCaptureView()
            }
            .sheet(isPresented: $showScanner) {
                DocumentScannerView(
                    onFinish: { pages in
                        showScanner = false
                        Task { await services.ingest.capture(scan: pages, in: modelContext) }
                    },
                    onCancel: { showScanner = false }
                )
                .ignoresSafeArea()
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $photoSelections,
                maxSelectionCount: 10,
                matching: .images
            )
            .fileImporter(
                isPresented: $showFileImporter,
                // `.data` is the catch-all: anything not specially handled is
                // still stored intact rather than being rejected at the picker.
                allowedContentTypes: [.pdf, .image, .text, .audio, .data],
                allowsMultipleSelection: true
            ) { result in
                handleFileImport(result)
            }
            .onChange(of: photoSelections) { _, newValue in
                guard !newValue.isEmpty else { return }
                importPhotos(newValue)
            }
            // Words appear in the note as they're recognized, rather than in a
            // separate preview that gets copied over at the end.
            .onChange(of: transcriber.liveTranscript) { _, spoken in
                // The `isListening` half matters on the way out: cancelling
                // blanks the live transcript, and without this the blank would
                // be merged in and wipe what was just dictated.
                guard let base = dictationBase, transcriber.isListening else { return }
                draft = Self.appending(spoken, to: base)
            }
            .onDisappear { if isDictating { transcriber.cancelListening() } }
            .onChange(of: services.ingest.lastError) { _, newValue in
                errorMessage = newValue
            }
            .alert(
                "Capture problem",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {
                    errorMessage = nil
                    // Clear the source too, so an identical second failure still
                    // registers as a change and re-raises the alert.
                    services.ingest.clearError()
                }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Sections

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty, !isDictating {
                    Text("What do you want to remember?\nType it, or tap the mic to speak it.\nTip: add #tags anywhere in the text.")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .focused($isEditorFocused)
            }
            .padding(8)
            // Room along the bottom edge for the dictation controls, so growing
            // text never slides under them.
            .padding(.bottom, 30)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            // One row rather than two corner overlays, so a long status line can
            // never slide under the button.
            .overlay(alignment: .bottom) {
                HStack(spacing: 8) {
                    dictationStatus
                    Spacer(minLength: 0)
                    dictationButton
                }
                .padding(.leading, 12)
                .padding(.trailing, 2)
            }
            .animation(.easeInOut(duration: 0.2), value: isDictating)

            Text("The mic types what you say straight into the note. “Voice note” below keeps the recording itself.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if !TextAnalysis.hashtags(in: draft).isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(TextAnalysis.hashtags(in: draft), id: \.self) { name in
                            TagChip(name: name)
                        }
                    }
                }
            }
        }
    }

    private var dictationButton: some View {
        Button(action: toggleDictation) {
            Image(systemName: isDictating ? "waveform.circle.fill" : "mic.circle.fill")
                .font(.title2)
                .symbolEffect(.pulse, isActive: isDictating)
                .foregroundStyle(isDictating ? Color.red : Color.accentColor)
        }
        .buttonStyle(.plain)
        .padding(10)
        .disabled(services.ingest.isBusy)
        .accessibilityLabel(isDictating ? "Stop dictating" : "Dictate into this note")
    }

    @ViewBuilder
    private var dictationStatus: some View {
        if isDictating {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text(transcriber.liveTranscript.isEmpty ? "Listening…" : "Tap the mic when you're done")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .transition(.opacity)
        }
    }

    private var captureButtons: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            captureButton("Voice note", systemImage: "mic.fill") { showVoiceCapture = true }
            captureButton("Photo", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
            captureButton("Scan document", systemImage: "doc.viewfinder") {
                if DocumentScannerView.isSupported {
                    showScanner = true
                } else {
                    errorMessage = "Document scanning isn't available on this device."
                }
            }
            captureButton("Import file / PDF", systemImage: "folder") { showFileImporter = true }
        }
    }

    private func captureButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(services.ingest.isBusy)
    }

    private var progressBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(services.ingest.activity ?? "Working…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var recentSection: some View {
        if recentMemories.isEmpty {
            EmptyStateView(
                systemImage: "brain.head.profile",
                title: "Your brain is empty",
                message: "Capture a thought, record a voice note, snap a photo or import a PDF. Everything becomes searchable."
            )
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recently captured")
                    .font(.headline)
                ForEach(recentMemories) { item in
                    NavigationLink(value: item) {
                        MemoryRow(item: item)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    // MARK: - Actions

    // These go through `IngestService.capture(…)` rather than `save*`: the view
    // has no use for the created model, and the `capture` overloads return
    // `Void` so no SwiftData model ever becomes a `Task`'s result type. This
    // view is `@MainActor`, so the tasks inherit that isolation.

    private func saveDraft() {
        if isDictating { transcriber.cancelListening() }
        let text = draft
        draft = ""
        isEditorFocused = false
        Task { await services.ingest.capture(text: text, in: modelContext) }
    }

    // MARK: - Dictation

    /// Speaks into the note itself, as opposed to the "Voice note" button, which
    /// keeps the audio as a memory of its own. Both are useful and they are not
    /// the same thing: this one is a keyboard, that one is a recording.
    private func toggleDictation() {
        if isDictating {
            // Ends audio capture; the recognizer's final, punctuated pass lands
            // a moment later through `onFinalTranscript`.
            transcriber.stopListening()
            return
        }
        // The Ask tab holds the microphone. Leave it alone rather than fighting
        // over one recognizer.
        guard !transcriber.isListening else {
            errorMessage = "Dictation is already running on the Ask tab. Stop it there first."
            return
        }

        let base = draft
        dictationBase = base
        isEditorFocused = false

        transcriber.onFinalTranscript = { spoken in
            // The final pass is better punctuated than the partial results, so it
            // replaces rather than appends to what's on screen.
            draft = Self.appending(spoken, to: base)
        }
        transcriber.onSessionEnd = { dictationBase = nil }

        Task {
            do {
                try await transcriber.startListening(autoStop: false)
                // Starting is asynchronous — it may wait on a permission prompt —
                // and a tab change ends the session in the meantime. If that
                // happened, don't leave a recognizer running with no owner.
                if dictationBase == nil { transcriber.cancelListening() }
            } catch {
                dictationBase = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Joins dictated text onto the draft, inserting a space only where one is
    /// actually missing — so speaking twice doesn't run words together, and
    /// doesn't leave a gap after a newline either.
    static func appending(_ spoken: String, to base: String) -> String {
        let addition = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return base }
        guard !base.isEmpty else { return addition }
        let separator = (base.last?.isWhitespace ?? false) ? "" : " "
        return base + separator + addition
    }

    private func importPhotos(_ selections: [PhotosPickerItem]) {
        photoSelections = []
        Task {
            for selection in selections {
                guard let data = try? await selection.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { continue }
                await services.ingest.capture(image: image, source: "Photo", in: modelContext)
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task {
                for url in urls {
                    await services.ingest.capture(fileAt: url, in: modelContext)
                }
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}
