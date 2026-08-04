import Foundation
import Observation
import SwiftData
import UIKit
import UniformTypeIdentifiers

/// The single door every capture walks through.
///
/// Text, voice, image and PDF all end up as a `MemoryItem` with the same
/// enrichment applied — title, keywords, embedding — which is what lets one
/// search path cover every input type.
@MainActor
@Observable
final class IngestService {
    /// Human-readable description of the work in flight, for the capture UI.
    private(set) var activity: String?
    var isBusy: Bool { activity != nil }

    private(set) var lastError: String?

    func clearError() {
        lastError = nil
    }

    // MARK: - Text

    @discardableResult
    func saveNote(text: String, in context: ModelContext) async -> MemoryItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A capture that is only a URL is a link, not a note — it gets a
        // readable title instead of showing the raw address as its own name.
        if let url = TextAnalysis.bareURL(in: trimmed) {
            return await saveLink(url, in: context)
        }

        let item = MemoryItem(text: trimmed, kind: .note)
        context.insert(item)
        await finalize(item, in: context, activity: "Saving note")
        return item
    }

    // MARK: - Links

    @discardableResult
    func saveLink(_ url: URL, in context: ModelContext) async -> MemoryItem? {
        let item = MemoryItem(text: url.absoluteString, kind: .link, source: url.absoluteString)
        item.title = TextAnalysis.linkTitle(for: url)
        context.insert(item)
        await finalize(item, in: context, activity: "Saving link", fallbackTitle: url.absoluteString)
        return item
    }

    // MARK: - Voice

    /// Saves the recording immediately, then transcribes.
    ///
    /// The note is inserted before transcription finishes on purpose: losing a
    /// recording because speech recognition failed would be the worst possible
    /// outcome for a capture tool.
    @discardableResult
    func saveVoiceNote(audioURL: URL, duration: TimeInterval, in context: ModelContext) async -> MemoryItem? {
        guard let data = try? Data(contentsOf: audioURL) else {
            lastError = "The recording couldn't be read."
            return nil
        }

        activity = "Saving recording"
        let item = MemoryItem(kind: .voice, source: "Voice note")
        let attachment = MemoryAttachment(
            filename: audioURL.lastPathComponent,
            kind: .audio,
            payload: data,
            duration: duration
        )
        attachment.memory = item
        context.insert(item)
        context.insert(attachment)
        item.title = "Voice note · \(Date().formatted(date: .abbreviated, time: .shortened))"
        try? context.save()

        activity = "Transcribing"
        do {
            let transcript = try await SpeechTranscriber.transcribe(fileAt: audioURL)
            let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                item.text = clean
                attachment.extractedText = clean
                item.title = ""
            }
        } catch {
            lastError = "Saved the recording, but couldn't transcribe it: \(error.localizedDescription)"
        }

        await finalize(item, in: context, activity: "Indexing", fallbackTitle: "Voice note")
        try? FileManager.default.removeItem(at: audioURL)
        return item
    }

    // MARK: - Images

    @discardableResult
    func saveImage(_ image: UIImage, source: String = "Photo", in context: ModelContext) async -> MemoryItem? {
        activity = "Reading image"
        guard let payload = TextRecognizer.normalizedImageData(from: image) else {
            activity = nil
            lastError = "That image couldn't be processed."
            return nil
        }

        let recognized = await TextRecognizer.recognizeText(in: image)
        let item = MemoryItem(kind: .image, source: source)
        item.extractedText = recognized

        let attachment = MemoryAttachment(
            filename: "\(source.replacingOccurrences(of: " ", with: "-").lowercased())-\(UUID().uuidString.prefix(8)).jpg",
            kind: .image,
            payload: payload,
            extractedText: recognized,
            thumbnail: TextRecognizer.thumbnail(from: image)
        )
        attachment.memory = item

        context.insert(item)
        context.insert(attachment)

        await finalize(item, in: context, activity: "Indexing", fallbackTitle: source)
        return item
    }

    /// Multi-page scans become one memory with one attachment per page, so a
    /// scanned contract stays a single thing in your library.
    @discardableResult
    func saveScan(pages: [UIImage], in context: ModelContext) async -> MemoryItem? {
        guard !pages.isEmpty else { return nil }
        activity = "Reading scan"

        let item = MemoryItem(kind: .document, source: "Scan")
        context.insert(item)

        var pageTexts: [String] = []
        for (index, page) in pages.enumerated() {
            activity = "Reading page \(index + 1) of \(pages.count)"
            guard let payload = TextRecognizer.normalizedImageData(from: page) else { continue }
            let recognized = await TextRecognizer.recognizeText(in: page)
            if !recognized.isEmpty { pageTexts.append(recognized) }

            let attachment = MemoryAttachment(
                filename: "scan-page-\(index + 1).jpg",
                kind: .image,
                payload: payload,
                extractedText: recognized,
                thumbnail: TextRecognizer.thumbnail(from: page)
            )
            attachment.memory = item
            context.insert(attachment)
        }

        item.extractedText = pageTexts.joined(separator: "\n\n")
        await finalize(item, in: context, activity: "Indexing", fallbackTitle: "Scan")
        return item
    }

    // MARK: - Files

    /// Imports a file picked from Files/iCloud Drive. PDFs get text extraction
    /// (with OCR fallback), plain text is read directly, and anything else is
    /// stored intact so it is at least kept and titled.
    @discardableResult
    func saveFile(at url: URL, in context: ModelContext) async -> MemoryItem? {
        // Picker URLs are security-scoped; without this the read fails silently.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        activity = "Importing \(url.lastPathComponent)"
        guard let data = try? Data(contentsOf: url) else {
            activity = nil
            lastError = "Couldn't read \(url.lastPathComponent)."
            return nil
        }

        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)

        if type?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" {
            return await savePDF(data: data, filename: url.lastPathComponent, in: context)
        }

        if type?.conforms(to: .image) == true, let image = UIImage(data: data) {
            return await saveImage(image, source: url.lastPathComponent, in: context)
        }

        if type?.conforms(to: .text) == true || type?.conforms(to: .plainText) == true {
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            let item = MemoryItem(text: text, kind: .document, source: url.lastPathComponent)
            context.insert(item)
            await finalize(item, in: context, activity: "Indexing", fallbackTitle: url.lastPathComponent)
            return item
        }

        // Unknown type: keep the bytes rather than refusing the capture.
        let item = MemoryItem(kind: .document, source: url.lastPathComponent)
        let attachment = MemoryAttachment(filename: url.lastPathComponent, kind: .file, payload: data)
        attachment.memory = item
        context.insert(item)
        context.insert(attachment)
        await finalize(item, in: context, activity: "Indexing", fallbackTitle: url.lastPathComponent)
        return item
    }

    @discardableResult
    func savePDF(data: Data, filename: String, in context: ModelContext) async -> MemoryItem? {
        activity = "Reading \(filename)"
        let extracted = await PDFTextExtractor.extract(from: data)

        let item = MemoryItem(kind: .document, source: filename)
        item.extractedText = extracted.text

        let attachment = MemoryAttachment(
            filename: filename,
            kind: .pdf,
            payload: data,
            extractedText: extracted.text,
            pageCount: extracted.pageCount,
            thumbnail: extracted.thumbnail
        )
        attachment.memory = item

        context.insert(item)
        context.insert(attachment)

        if extracted.text.isEmpty {
            lastError = "\(filename) was saved, but no readable text was found in it."
        }

        await finalize(item, in: context, activity: "Indexing", fallbackTitle: filename)
        return item
    }

    // MARK: - Share extension hand-off

    /// Imports everything the share extension left in the App Group folder.
    ///
    /// A file is only deleted after its memory is saved, so a crash or a kill
    /// mid-import loses nothing — the item is simply picked up next launch. The
    /// cost of that ordering is a possible duplicate, which is far cheaper than
    /// a silently dropped capture.
    @discardableResult
    func drainSharedInbox(into context: ModelContext) async -> Int {
        let pending = SharedInbox.pendingFiles()
        guard !pending.isEmpty else { return 0 }

        var imported = 0
        for file in pending {
            activity = "Importing shared item"
            let saved: MemoryItem?

            // Text shares are written as .txt; route them through the note path
            // so a shared URL still becomes a link.
            if file.pathExtension.lowercased() == "txt",
               let text = try? String(contentsOf: file, encoding: .utf8) {
                saved = await saveNote(text: text, in: context)
            } else {
                saved = await saveFile(at: file, in: context)
            }

            if saved != nil {
                imported += 1
                SharedInbox.remove(file)
            } else {
                // Unreadable payload: drop it rather than retrying forever.
                SharedInbox.remove(file)
            }
        }

        activity = nil
        return imported
    }

    // MARK: - Capture entry points for the UI

    // The `save*` methods above hand back the item they created, because
    // `drainSharedInbox` needs it (to decide whether the inbox file may be
    // deleted) and the tests assert on it. A view never wants it.
    //
    // Handing a `MemoryItem` to a view is not merely unnecessary, it is a
    // hazard: `Task { await ingest.saveNote(…) }` is a single-expression
    // closure, so Swift infers the task's `Success` type from that expression
    // — giving `Task<MemoryItem?, Never>`, whose `Success` must be `Sendable`.
    // SwiftData models mark their `Sendable` conformance unavailable, so the
    // call site warns. `@discardableResult` does not help; the value is still
    // the closure's result.
    //
    // These wrappers return `Void`, so the model stays inside this actor and
    // the UI cannot re-create that shape by accident.

    func capture(text: String, in context: ModelContext) async {
        _ = await saveNote(text: text, in: context)
    }

    func capture(image: UIImage, source: String = "Photo", in context: ModelContext) async {
        _ = await saveImage(image, source: source, in: context)
    }

    func capture(scan pages: [UIImage], in context: ModelContext) async {
        _ = await saveScan(pages: pages, in: context)
    }

    func capture(fileAt url: URL, in context: ModelContext) async {
        _ = await saveFile(at: url, in: context)
    }

    func capture(audioURL: URL, duration: TimeInterval, in context: ModelContext) async {
        _ = await saveVoiceNote(audioURL: audioURL, duration: duration, in: context)
    }

    // MARK: - Enrichment

    /// Recomputes everything search depends on. Called after every capture and
    /// after every edit, so an edited note never keeps a stale embedding.
    func finalize(
        _ item: MemoryItem,
        in context: ModelContext,
        activity label: String? = nil,
        fallbackTitle: String = "Untitled"
    ) async {
        if let label { activity = label }
        defer { activity = nil }

        let body = [item.text, item.extractedText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.title = TextAnalysis.suggestedTitle(from: body, fallback: fallbackTitle)
        }

        item.keywordIndex = TextAnalysis.keywords(from: body).joined(separator: " ")

        for name in TextAnalysis.hashtags(in: item.text) {
            attach(tagNamed: name, to: item, in: context)
        }

        // Embedding generation is CPU-bound; keep it off the main actor so the
        // capture sheet stays responsive on long documents.
        let searchable = item.searchableText
        let vector = await Task.detached(priority: .utility) {
            EmbeddingService.shared.vector(for: searchable)
        }.value
        item.embedding = vector

        item.touch()
        save(context)
    }

    // MARK: - Editing

    func setTags(_ names: [String], on item: MemoryItem, in context: ModelContext) {
        item.tags = []
        for name in names {
            attach(tagNamed: name, to: item, in: context)
        }
        item.touch()
        save(context)
    }

    func moveToTrash(_ item: MemoryItem, in context: ModelContext) {
        item.isTrashed = true
        item.touch()
        save(context)
    }

    func restore(_ item: MemoryItem, in context: ModelContext) {
        item.isTrashed = false
        item.touch()
        save(context)
    }

    /// Permanent delete. Attachments cascade via the relationship delete rule.
    func deletePermanently(_ item: MemoryItem, in context: ModelContext) {
        context.delete(item)
        save(context)
    }

    func emptyTrash(in context: ModelContext) {
        let descriptor = FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.isTrashed })
        guard let trashed = try? context.fetch(descriptor) else { return }
        trashed.forEach { context.delete($0) }
        save(context)
    }

    // MARK: - Internals

    /// Reuses an existing tag when one matches, so the tag list does not grow a
    /// duplicate every time you type the same word.
    private func attach(tagNamed rawName: String, to item: MemoryItem, in context: ModelContext) {
        let name = MemoryTag.normalize(rawName)
        guard !name.isEmpty else { return }
        if item.tagNames.contains(name) { return }

        let descriptor = FetchDescriptor<MemoryTag>(predicate: #Predicate { $0.name == name })
        let existing = (try? context.fetch(descriptor))?.first

        let tag: MemoryTag
        if let existing {
            tag = existing
        } else {
            tag = MemoryTag(name: name)
            context.insert(tag)
        }

        var current = item.tags ?? []
        current.append(tag)
        item.tags = current
    }

    private func save(_ context: ModelContext) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            lastError = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
