import SwiftData
import SwiftUI

/// A single memory: its text, its original attachments, and the metadata that
/// makes it findable.
@MainActor
struct MemoryDetailView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Bindable var item: MemoryItem

    /// The whole library, used only to work out what this memory connects to.
    /// Same query the other tabs run, so it costs a fetch that is already warm.
    @Query(filter: #Predicate<MemoryItem> { !$0.isTrashed })
    private var library: [MemoryItem]

    @State private var connections: [RelatedMemory] = []
    @State private var isEditing = false
    @State private var newTag = ""
    @State private var showExtractedText = false
    @State private var pdfPreview: MemoryAttachment?
    @State private var draftSummary: DiscussionSummarizer.Summary?
    @State private var isSummarizing = false
    @State private var summaryNotice: String?

    var body: some View {
        List {
            titleSection
            summarySection
            if !item.sortedAttachments.isEmpty { attachmentSection }
            if !item.extractedText.isEmpty { extractedSection }
            connectionSection
            tagSection
            metadataSection
            actionSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "Done" : "Edit") {
                    if isEditing { commitEdits() }
                    isEditing.toggle()
                }
            }
        }
        // Recomputed when you open a different memory, when this one is edited,
        // and when the library grows — not on every redraw.
        .task(id: connectionSignature) { await rebuildConnections() }
        .sheet(item: $pdfPreview) { attachment in
            NavigationStack {
                Group {
                    if let payload = attachment.payload {
                        PDFKitView(data: payload)
                    } else {
                        EmptyStateView(
                            systemImage: "doc.questionmark",
                            title: "Still downloading",
                            message: "This file hasn't finished syncing from iCloud yet."
                        )
                    }
                }
                .navigationTitle(attachment.filename)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { pdfPreview = nil }
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var titleSection: some View {
        Section {
            if isEditing {
                TextField("Title", text: $item.title, axis: .vertical)
                    .font(.headline)
                TextEditor(text: $item.text)
                    .frame(minHeight: 200)
            } else {
                Text(item.displayTitle)
                    .font(.title3.weight(.semibold))
                if item.text.isEmpty {
                    Text("No typed text. \(item.extractedText.isEmpty ? "Nothing was extracted from the attachment." : "See the extracted text below.")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(item.text)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// Only appears when there is something to summarize, or a summary already
    /// saved — a two-line note has no business showing a Summary heading.
    @ViewBuilder
    private var summarySection: some View {
        if item.hasSummary || canSummarize {
            Section {
                if let draftSummary {
                    SummaryBody(summary: draftSummary)
                    Button {
                        save(draftSummary)
                    } label: {
                        Label("Save summary", systemImage: "tray.and.arrow.down")
                    }
                    Button("Discard draft") { self.draftSummary = nil }
                } else {
                    if item.hasSummary {
                        Text(item.summary)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    if canSummarize {
                        Button {
                            makeSummary()
                        } label: {
                            if isSummarizing {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Summarizing…")
                                }
                            } else {
                                Label(
                                    item.hasSummary ? "Summarize again" : "Create summary",
                                    systemImage: "list.bullet.rectangle"
                                )
                            }
                        }
                        .disabled(isSummarizing)
                    }
                }
                if let summaryNotice {
                    Text(summaryNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Summary")
            } footer: {
                Text("Every line is quoted from this memory's own words — nothing is generated. A saved summary is searchable, so you can find a long recording by the few things that mattered in it.")
            }
        }
    }

    private var attachmentSection: some View {
        Section("Attachments") {
            ForEach(item.sortedAttachments) { attachment in
                AttachmentCell(attachment: attachment) {
                    if attachment.kind == .pdf { pdfPreview = attachment }
                }
            }
        }
    }

    private var extractedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showExtractedText) {
                Text(item.extractedText)
                    .font(.callout)
                    .textSelection(.enabled)
            } label: {
                Label("Extracted text (\(item.extractedText.count) characters)", systemImage: "text.viewfinder")
            }
        } footer: {
            Text("Pulled out automatically with on-device text recognition. It's indexed for search even when collapsed.")
        }
    }

    private var tagSection: some View {
        Section("Tags") {
            if item.tagNames.isEmpty && !isEditing {
                Text("No tags")
                    .foregroundStyle(.secondary)
            } else {
                WrappingTags(names: item.tagNames, isEditing: isEditing) { name in
                    remove(tag: name)
                }
            }
            if isEditing {
                HStack {
                    TextField("Add a tag", text: $newTag)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { addTag() }
                    Button("Add", action: addTag)
                        .disabled(MemoryTag.normalize(newTag).isEmpty)
                }
            }
        }
    }

    private var metadataSection: some View {
        Section("Details") {
            LabeledContent("Captured", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Updated", value: item.updatedAt.formatted(date: .abbreviated, time: .shortened))
            if !item.source.isEmpty {
                LabeledContent("Source", value: item.source)
            }
            LabeledContent("Search index", value: item.embeddingData == nil ? "Keywords only" : "Keywords + meaning")
            if !item.keywords.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keywords").font(.caption).foregroundStyle(.secondary)
                    Text(item.keywords.prefix(12).joined(separator: ", "))
                        .font(.caption)
                }
            }
        }
    }

    /// Memories this one belongs with, found without anybody linking anything.
    ///
    /// Absent when nothing clears the bar rather than padded with near-misses:
    /// see `ConnectionFinder` for why a wrong link costs more than an empty
    /// space.
    @ViewBuilder
    private var connectionSection: some View {
        if !connections.isEmpty {
            Section {
                ForEach(connections) { related in
                    NavigationLink(value: related.item) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(related.item.displayTitle)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                Text(related.reason)
                                    .foregroundStyle(Color.accentColor)
                                Text(related.item.createdAt.filedDateDescription)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }
            } header: {
                Label("Connected in your brain", systemImage: "point.3.filled.connected.trianglepath.dotted")
            } footer: {
                Text("Found from shared tags, shared uncommon words and meaning — you don't have to link anything yourself.")
            }
        }
    }

    private var actionSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { item.isPinned },
                set: { item.isPinned = $0; item.touch() }
            )) {
                Label("Pin to top", systemImage: "pin")
            }

            Button {
                Task { await services.ingest.finalize(item, in: modelContext, activity: "Re-indexing") }
            } label: {
                Label("Rebuild search index", systemImage: "arrow.clockwise")
            }

            if item.isTrashed {
                Button {
                    services.ingest.restore(item, in: modelContext)
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                Button(role: .destructive) {
                    services.ingest.deletePermanently(item, in: modelContext)
                    dismiss()
                } label: {
                    Label("Delete permanently", systemImage: "trash")
                }
            } else {
                Button(role: .destructive) {
                    services.ingest.moveToTrash(item, in: modelContext)
                    dismiss()
                } label: {
                    Label("Move to trash", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Summarizing

    /// A transcript, but also a long OCR'd scan or an imported PDF — anything
    /// with enough words in it to be worth condensing.
    private var summarizableText: String {
        item.text.isEmpty ? item.extractedText : item.text
    }

    private var canSummarize: Bool {
        summarizableText
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .count >= DiscussionSummarizer.minimumWords
    }

    private func makeSummary() {
        guard !isSummarizing else { return }
        let body = summarizableText
        isSummarizing = true
        summaryNotice = nil
        Task {
            // Two `NLTagger` passes over a long document; keep it off the main actor.
            let result = await Task.detached(priority: .userInitiated) {
                DiscussionSummarizer.summarize(body)
            }.value
            isSummarizing = false
            if let result {
                draftSummary = result
            } else {
                summaryNotice = "There isn't enough distinct material here to summarize."
            }
        }
    }

    private func save(_ summary: DiscussionSummarizer.Summary) {
        let text = summary.text
        draftSummary = nil
        Task { await services.ingest.setSummary(text, on: item, in: modelContext) }
    }

    // MARK: - Connections

    private var connectionSignature: String {
        "\(item.identifier)-\(library.count)-\(Int(item.updatedAt.timeIntervalSince1970))"
    }

    /// Snapshots to plain values on the main actor, then scores off it.
    ///
    /// Cosine similarity across a whole library is real arithmetic, and
    /// `MemoryItem` is not `Sendable`, so the model never crosses the boundary —
    /// only the flattened candidates do, and only identifiers come back.
    private func rebuildConnections() async {
        let subject = ConnectionCandidate(item)
        let candidates = library.map(ConnectionCandidate.init)
        guard candidates.count > 1 else {
            connections = []
            return
        }

        let found = await Task.detached(priority: .utility) {
            ConnectionFinder.related(to: subject, among: candidates)
        }.value

        let byIdentifier = Dictionary(
            library.map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        connections = found.compactMap { connection in
            guard let match = byIdentifier[connection.id] else { return nil }
            return RelatedMemory(item: match, reason: connection.reason)
        }
    }

    // MARK: - Actions

    /// Editing text changes what the note means, so the index is rebuilt rather
    /// than left pointing at the old wording.
    private func commitEdits() {
        // From here on this title is the user's, and bulk re-derivation leaves
        // it alone.
        if !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.hasCustomTitle = true
        }
        Task { await services.ingest.finalize(item, in: modelContext, activity: "Re-indexing") }
    }

    private func addTag() {
        let name = MemoryTag.normalize(newTag)
        guard !name.isEmpty else { return }
        newTag = ""
        services.ingest.setTags(item.tagNames + [name], on: item, in: modelContext)
    }

    private func remove(tag name: String) {
        services.ingest.setTags(item.tagNames.filter { $0 != name }, on: item, in: modelContext)
    }
}

/// A found link, ready to render.
private struct RelatedMemory: Identifiable {
    let item: MemoryItem
    let reason: String

    var id: UUID { item.identifier }
}

/// Renders one attachment inline: images preview, audio plays, PDFs open.
@MainActor
private struct AttachmentCell: View {
    let attachment: MemoryAttachment
    var onTap: () -> Void

    var body: some View {
        switch attachment.kind {
        case .image:
            imageCell
        case .audio:
            audioCell
        case .pdf, .file:
            fileCell
        }
    }

    private var imageCell: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let payload = attachment.payload, let image = UIImage(data: payload) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                syncingPlaceholder
            }
            Text("\(attachment.filename) · \(attachment.formattedSize)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var audioCell: some View {
        AudioPlayerRow(attachment: attachment)
    }

    private var fileCell: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if let thumbnail = attachment.thumbnail, let image = UIImage(data: thumbnail) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(systemName: attachment.kind.systemImage)
                        .font(.title2)
                        .frame(width: 44, height: 56)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(attachment.filename)
                        .font(.subheadline)
                        .lineLimit(2)
                    Text(detailLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if attachment.kind == .pdf {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(attachment.kind != .pdf)
    }

    private var detailLine: String {
        var parts = [attachment.formattedSize]
        if attachment.pageCount > 0 {
            parts.append(attachment.pageCount == 1 ? "1 page" : "\(attachment.pageCount) pages")
        }
        if attachment.payload == nil { parts.append("downloading from iCloud") }
        return parts.joined(separator: " · ")
    }

    private var syncingPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(.secondarySystemBackground))
            .frame(height: 140)
            .overlay {
                Label("Downloading from iCloud", systemImage: "icloud.and.arrow.down")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
    }
}

/// Simple flow layout for tag chips.
private struct WrappingTags: View {
    let names: [String]
    let isEditing: Bool
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    TagChip(name: name, onRemove: isEditing ? { onRemove(name) } : nil)
                }
            }
            .padding(.vertical, 2)
        }
    }
}
