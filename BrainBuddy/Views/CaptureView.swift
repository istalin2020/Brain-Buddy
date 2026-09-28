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
    /// Where the cursor is in `draft`, in the text view's own units. Dictation
    /// starts here, and follows it if you move it while speaking.
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var showVoiceCapture = false
    @State private var showPhotoPicker = false
    @State private var showScanner = false
    @State private var showFileImporter = false
    @State private var photoSelections: [PhotosPickerItem] = []
    @State private var errorMessage: String?
    /// Where the words being heard sit in the note. Non-nil exactly while
    /// *this* screen owns the recognizer, which is also how the UI knows to
    /// show itself as listening — `transcriber.isListening` alone would light
    /// up while the Ask tab is the one holding the microphone.
    ///
    /// It used to be a snapshot of the whole note, rebuilt as *snapshot +
    /// everything heard* on every word — which erased any edit made while
    /// listening and could only ever add at the end. See `DictationSplice`.
    @State private var dictation: DictationSplice?
    @State private var isEditorFocused = false

    private var transcriber: SpeechTranscriber { services.transcriber }
    private var isDictating: Bool { dictation != nil }

    private var recentMemories: [MemoryItem] { Array(memories.prefix(4)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    editor
                    captureButtons
                    if services.ingest.isBusy { progressBanner }
                    if let notice = services.ingest.lastNotice { noticeBanner(notice) }
                    recentSection
                }
                .padding()
            }
            .navigationTitle("Input")
            .navigationDestination(for: MemoryItem.self) { item in
                MemoryDetailView(item: item)
            }
            // No Save in the toolbar. Saving belongs on the ↑ button inside the
            // box, next to the mic — the two things you do to a draft, in the
            // place you are already looking.
            .toolbar {
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
            // Words appear in the note as they're recognized, at the cursor,
            // rather than in a separate preview that gets copied over at the end.
            .onChange(of: transcriber.liveTranscript) { _, spoken in
                // The `isListening` half matters on the way out: cancelling
                // blanks the live transcript, and without this the blank would
                // be merged in and wipe what was just dictated.
                guard transcriber.isListening else { return }
                hear(spoken)
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
                DraftTextView(
                    text: draft,
                    selection: selection,
                    isFocused: $isEditorFocused,
                    // Trimmed to pay for the taller mic below it, so the box as
                    // a whole didn't grow back.
                    minHeight: 104,
                    onEdit: userEdited,
                    onSelect: userSelected
                )
            }
            .padding(8)
            // Room along the bottom edge for the two controls, so growing text
            // never slides under them.
            .padding(.bottom, 46)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            // One row rather than corner overlays, so a long status line can
            // never slide under the buttons.
            .overlay(alignment: .bottom) {
                HStack(spacing: 2) {
                    dictationStatus
                    Spacer(minLength: 0)
                    micButton
                    commitButton
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
            }
            .animation(.easeInOut(duration: 0.2), value: isDictating)

            Text("Mic types what you say at the cursor — you can edit while it listens. Tap stop or ✓ when done, then ↑ to save. “Voice note” below keeps the recording itself.")
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

    /// Left of the pair: starts dictating, and stops it.
    ///
    /// While listening it is a **stop** button. It used to be a waveform, which
    /// says "sound is happening" and not "tap here to finish" — the one thing
    /// the control is for. Tapping it finishes the same way the tick does. Two
    /// ways to stop is deliberate: there is no gesture here that can lose words
    /// you have already spoken.
    private var micButton: some View {
        Button(action: toggleDictation) {
            Image(systemName: isDictating ? "stop.circle.fill" : "mic.circle.fill")
                // Sized to be hit without looking, mid-thought, one-handed.
                .font(.system(size: 34))
                .symbolEffect(.pulse, isActive: isDictating)
                .foregroundStyle(isDictating ? Color.red : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .padding(6)
        .disabled(services.ingest.isBusy)
        .accessibilityLabel(isDictating ? "Stop dictating" : "Dictate into this note at the cursor")
    }

    /// Right of the pair, and it means one thing at a time.
    ///
    /// **✓ while listening**: take the words into the box. **↑ otherwise**: save
    /// the note. Those are two separate decisions — accepting a transcript is not
    /// the same as being finished with the thought — and running them together is
    /// how a dictated note gets saved before you have had a chance to fix the one
    /// word the recognizer got wrong.
    private var commitButton: some View {
        Button(action: commit) {
            Image(systemName: isDictating ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(canCommit ? Color.accentColor : Color.secondary.opacity(0.4))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .padding(6)
        .disabled(!canCommit)
        .accessibilityLabel(isDictating ? "Accept what you said" : "Save this note")
    }

    /// Accepting is always available while listening — even before any words
    /// arrive, because stopping has to work. Saving needs something to save.
    private var canCommit: Bool {
        if isDictating { return true }
        guard !services.ingest.isBusy else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var dictationStatus: some View {
        if isDictating {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text(transcriber.liveTranscript.isEmpty
                     ? "Listening…"
                     : "Edit or move the cursor any time · tap stop when done")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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

    /// A duplicate isn't a failure, so it doesn't get an alert. It gets a line
    /// that says what happened and goes away when you dismiss it — because the
    /// alternative, silently saving a fourth copy of the same screenshot, is
    /// what filled the library up.
    private func noticeBanner(_ notice: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(Color.accentColor)
            Text(notice)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                services.ingest.clearNotice()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    /// One button, one meaning at a time: take the words, or save the note.
    private func commit() {
        if isDictating {
            // Ends audio capture and keeps everything recognized so far. The
            // recognizer's final, better-punctuated pass lands a moment later
            // through `onFinalTranscript` and replaces what is on screen.
            transcriber.stopListening()
            return
        }
        saveDraft()
    }

    private func saveDraft() {
        // The words heard so far are already in the note — the splice puts them
        // there as they arrive — so stopping first loses nothing.
        if isDictating {
            transcriber.cancelListening()
            dictation = nil
        }
        let text = draft
        draft = ""
        selection = NSRange(location: 0, length: 0)
        isEditorFocused = false
        // Clear last time's notice so the one this capture produces — or the
        // absence of one — is unambiguous.
        services.ingest.clearNotice()
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

        // Starts where the cursor is. The keyboard is left as it is: if it is
        // up you can see the cursor and edit while speaking, and if it is down
        // the cursor is still where you last left it.
        dictation = DictationSplice(text: draft, cursor: selection)

        transcriber.onFinalTranscript = { spoken in
            // The final pass is better punctuated than the partial results. It
            // goes through the splice, so it can only reword the words still
            // live — never anything you typed or corrected.
            hear(spoken)
        }
        transcriber.onSessionEnd = { dictation = nil }

        Task {
            do {
                try await transcriber.startListening(autoStop: false)
                // Starting is asynchronous — it may wait on a permission prompt —
                // and a tab change ends the session in the meantime. If that
                // happened, don't leave a recognizer running with no owner.
                if dictation == nil { transcriber.cancelListening() }
            } catch {
                dictation = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Words heard: they go into the live span, and the cursor follows them.
    private func hear(_ spoken: String) {
        guard var splice = dictation else { return }
        splice.hear(spoken)
        dictation = splice
        draft = splice.text
        selection = splice.caret
    }

    /// You typed, deleted or pasted. While dictating, the splice works out
    /// where the words being heard are now; otherwise it is just typing.
    private func userEdited(_ text: String, _ cursor: NSRange) {
        if var splice = dictation {
            splice.userEdited(to: text, selection: cursor)
            dictation = splice
        }
        draft = text
        selection = cursor
    }

    /// You moved the cursor. Ignored if the text on screen is not the text we
    /// hold — that is a cursor move arriving just ahead of its own edit, and
    /// the edit carries the same cursor.
    private func userSelected(_ text: String, _ cursor: NSRange) {
        guard text == draft else { return }
        if var splice = dictation {
            splice.userMoved(cursor)
            dictation = splice
        }
        selection = cursor
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
