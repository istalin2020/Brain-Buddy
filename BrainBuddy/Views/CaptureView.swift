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
    @FocusState private var isEditorFocused: Bool

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
                if draft.isEmpty {
                    Text("What do you want to remember?\nTip: add #tags anywhere in the text.")
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
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

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
        let text = draft
        draft = ""
        isEditorFocused = false
        Task { await services.ingest.capture(text: text, in: modelContext) }
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
