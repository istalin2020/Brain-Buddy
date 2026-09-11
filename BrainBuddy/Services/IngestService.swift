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

    /// Something worth saying that isn't a failure — "that was already in your
    /// brain". Kept apart from `lastError` so a duplicate doesn't raise an alert
    /// that reads like something went wrong.
    private(set) var lastNotice: String?

    func clearError() {
        lastError = nil
    }

    func clearNotice() {
        lastNotice = nil
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

        if let existing = duplicate(of: CaptureFingerprint.text(trimmed), in: context) {
            noteDuplicate(existing)
            return existing
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
            let transcript = try await SpeechTranscriber.transcribe(
                fileAt: audioURL,
                duration: duration
            ) { [weak self] done, total in
                // A forty-minute recording takes a while; "Transcribing" alone
                // for several minutes looks identical to being stuck.
                guard total > 1 else { return }
                self?.activity = "Transcribing part \(min(done + 1, total)) of \(total)"
            }
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

        // The same screenshot shared twice differs by the clock in its status
        // bar, so the words decide first and the bytes only when there are none.
        if let existing = duplicate(
            of: CaptureFingerprint.of(text: recognized, payload: payload),
            in: context
        ) {
            activity = nil
            noteDuplicate(existing)
            return existing
        }

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

        // Checked after the pages are read rather than before, because until
        // they are read there is nothing to compare. The half-built memory is
        // removed rather than kept: its attachments cascade with it.
        if let existing = duplicate(of: CaptureFingerprint.text(item.extractedText), in: context) {
            context.delete(item)
            save(context)
            noteDuplicate(existing)
            return existing
        }

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
            if let existing = duplicate(of: CaptureFingerprint.of(text: text, payload: data), in: context) {
                activity = nil
                noteDuplicate(existing)
                return existing
            }
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

        if let existing = duplicate(
            of: CaptureFingerprint.of(text: extracted.text, payload: data),
            in: context
        ) {
            activity = nil
            noteDuplicate(existing)
            return existing
        }

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

    // MARK: - Quick capture hand-off

    /// Files everything Siri, Shortcuts or a Home Screen action left behind.
    ///
    /// Same ordering rule as the shared inbox: the file is removed only after the
    /// memory exists, so a kill mid-import costs a possible duplicate rather than
    /// the capture itself.
    @discardableResult
    func drainQuickCaptures(into context: ModelContext) async -> Int {
        let pending = QuickCaptureQueue.pending()
        guard !pending.isEmpty else { return 0 }

        var imported = 0
        for file in pending {
            activity = "Filing what you said"
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                QuickCaptureQueue.remove(file)
                continue
            }
            if await saveNote(text: text, in: context) != nil { imported += 1 }
            QuickCaptureQueue.remove(file)
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
    // These wrappers return `Void`, so the model never becomes a task's result
    // type. `VoiceCaptureView` is the one view that legitimately needs the item
    // back — it shows you the transcript afterwards — and it assigns the result
    // to state inside a multi-statement task, which is not the hazardous shape.

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
        item.contentFingerprint = CaptureFingerprint.of(
            text: body,
            payload: item.sortedAttachments.first?.payload
        ) ?? ""

        for name in TextAnalysis.hashtags(in: item.text) {
            attach(tagNamed: name, to: item, in: context)
        }

        await summarizeIfNeeded(item, body: body)

        // Embedding generation is CPU-bound; keep it off the main actor so the
        // capture sheet stays responsive on long documents.
        let searchable = item.searchableText
        let vector = await Task.detached(priority: .utility) {
            EmbeddingService.shared.vector(for: searchable)
        }.value
        item.embedding = vector

        item.touch()
        save(context)

        // Publishing to the system index happens here, at the one point every
        // capture and every edit passes through, so an edited note can never
        // leave a stale entry in Spotlight.
        publishToSpotlight(item)
    }

    // MARK: - Reading what arrived

    /// Writes a summary for anything that arrived as a document rather than as a
    /// sentence you typed.
    ///
    /// A scan, a PDF, a screenshot or a recording lands as a wall of text with
    /// no shape to it. Leaving that until somebody presses *Create summary*
    /// means the library reads as a list of first lines — which is exactly what
    /// it did. So the summary is written at capture, marked as the app's own
    /// work, and can be adopted with one tap.
    ///
    /// It never overwrites a summary you saved, and never touches a typed note:
    /// you already wrote that in your own words.
    private func summarizeIfNeeded(_ item: MemoryItem, body: String) async {
        guard item.summary.isEmpty || item.summaryIsAutomatic else { return }
        guard item.kind != .note, item.kind != .link else { return }
        guard DiscussionSummarizer.wordCount(of: body) >= DiscussionSummarizer.minimumWords else {
            return
        }

        activity = "Reading it"
        // Two `NLTagger` passes over a long document; keep them off the main
        // actor so a big PDF doesn't freeze the capture screen.
        let summary = await Task.detached(priority: .userInitiated) {
            DiscussionSummarizer.summarize(body)
        }.value

        guard let summary, !summary.isEmpty else { return }
        item.summary = summary.text
        item.summaryIsAutomatic = true
    }

    /// An existing memory with the same content, if there is one.
    private func duplicate(of fingerprint: String?, in context: ModelContext) -> MemoryItem? {
        guard let fingerprint, !fingerprint.isEmpty else { return nil }
        var descriptor = FetchDescriptor<MemoryItem>(
            predicate: #Predicate { $0.contentFingerprint == fingerprint && !$0.isTrashed }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Says what happened, and brings the original forward rather than leaving
    /// you wondering where your capture went.
    private func noteDuplicate(_ existing: MemoryItem) {
        activity = nil
        let name = existing.displayTitle
        lastNotice = name.isEmpty
            ? "That was already in your brain."
            : "Already in your brain — “\(name)”."
    }

    // MARK: - System search

    /// Adds or refreshes one memory in the device's own search index.
    ///
    /// Snapshotted into a plain value first: `MemoryItem` is not `Sendable`, and
    /// the index call has no business holding a model object.
    func publishToSpotlight(_ item: MemoryItem) {
        guard UserDefaults.standard.bool(forKey: PreferenceKey.systemSearch) else { return }
        guard let record = SpotlightRecord(item) else {
            SpotlightIndexer.remove(identifiers: [item.identifier])
            return
        }
        SpotlightIndexer.donate([record])
    }

    /// Rebuilds the whole index. Offered in Settings, and used after the
    /// preference is switched back on, since nothing was donated while it was
    /// off.
    @discardableResult
    func rebuildSpotlightIndex(in context: ModelContext) -> Int {
        SpotlightIndexer.removeEverything()
        guard UserDefaults.standard.bool(forKey: PreferenceKey.systemSearch) else { return 0 }

        let descriptor = FetchDescriptor<MemoryItem>(predicate: #Predicate { !$0.isTrashed })
        guard let items = try? context.fetch(descriptor) else { return 0 }
        let records = items.compactMap { SpotlightRecord($0) }
        SpotlightIndexer.donate(records)
        return records.count
    }

    // MARK: - Editing

    /// Re-derives the subject of anything the user hasn't titled themselves.
    ///
    /// Titles are only computed once, at capture, so improving how they're derived
    /// does nothing for what's already saved. This is what the maintenance action
    /// runs over the library. A title someone typed is never touched.
    @discardableResult
    func refreshSubject(of item: MemoryItem) -> Bool {
        guard !item.hasCustomTitle else { return false }
        let body = [item.text, item.extractedText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !body.isEmpty else { return false }

        let derived = TextAnalysis.suggestedTitle(from: body, fallback: item.kind.sourceLabel)
        guard !derived.isEmpty, derived != item.title else { return false }
        item.title = derived
        item.touch()
        return true
    }

    /// Stores a summary the user reviewed and pressed Save on.
    ///
    /// Re-indexes afterwards, because the summary is searchable text: the point
    /// of summarizing a two-hour meeting is being able to find it by the three
    /// things that mattered in it.
    func setSummary(_ summary: String, on item: MemoryItem, in context: ModelContext) async {
        item.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reviewed by a person, so it stops being the app's guess and starts
        // being something you said — which is what lets it reach your brief.
        item.summaryIsAutomatic = false
        await finalize(item, in: context, activity: "Saving summary")
    }

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
        // Out of the app means out of Spotlight: finding a trashed note in
        // system search and tapping into an empty screen is worse than not
        // finding it.
        SpotlightIndexer.remove(identifiers: [item.identifier])
    }

    func restore(_ item: MemoryItem, in context: ModelContext) {
        item.isTrashed = false
        item.touch()
        save(context)
        publishToSpotlight(item)
    }

    /// Permanent delete. Attachments cascade via the relationship delete rule.
    func deletePermanently(_ item: MemoryItem, in context: ModelContext) {
        let identifier = item.identifier
        context.delete(item)
        save(context)
        SpotlightIndexer.remove(identifiers: [identifier])
    }

    func emptyTrash(in context: ModelContext) {
        let descriptor = FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.isTrashed })
        guard let trashed = try? context.fetch(descriptor) else { return }
        let identifiers = trashed.map(\.identifier)
        trashed.forEach { context.delete($0) }
        save(context)
        SpotlightIndexer.remove(identifiers: identifiers)
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
