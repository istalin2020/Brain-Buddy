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

    @State private var isEditing = false
    @State private var newTag = ""
    @State private var showExtractedText = false
    @State private var pdfPreview: MemoryAttachment?

    var body: some View {
        List {
            titleSection
            if !item.sortedAttachments.isEmpty { attachmentSection }
            if !item.extractedText.isEmpty { extractedSection }
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

    // MARK: - Actions

    /// Editing text changes what the note means, so the index is rebuilt rather
    /// than left pointing at the old wording.
    private func commitEdits() {
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

/// Renders one attachment inline: images preview, audio plays, PDFs open.
@MainActor
private struct AttachmentCell: View {
    let attachment: MemoryAttachment
    var onTap: () -> Void

    @State private var player = AudioPlayerController()

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
        HStack(spacing: 12) {
            Button {
                if player.duration == 0, let url = attachment.temporaryFileURL() {
                    player.load(url: url)
                }
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
            }
            .buttonStyle(.plain)
            .disabled(attachment.payload == nil)

            VStack(alignment: .leading, spacing: 4) {
                Text(attachment.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(player.duration > 0
                     ? "\(format(player.currentTime)) / \(format(player.duration))"
                     : attachment.formattedDuration)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
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

    private func format(_ time: TimeInterval) -> String {
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
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
