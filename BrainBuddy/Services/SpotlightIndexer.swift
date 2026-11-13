import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// One memory, flattened into what the system index needs.
///
/// A plain value rather than the model itself, so donating can happen off the
/// main actor and so what gets published to the index is decided in one testable
/// place instead of at three call sites.
struct SpotlightRecord: Equatable, Sendable {
    let identifier: UUID
    let title: String
    let summary: String
    let keywords: [String]
    let createdAt: Date
    let updatedAt: Date
    let thumbnail: Data?

    /// Enough to recognize the memory in a list of system search results, not
    /// enough to matter if the index is ever read by something else.
    static let summaryLimit = 300
    static let keywordLimit = 20
}

extension SpotlightRecord {
    /// `nil` for anything that shouldn't be findable: trashed memories, and
    /// memories with no words in them at all.
    init?(_ item: MemoryItem) {
        guard !item.isTrashed else { return nil }

        let body = [item.summary, item.text, item.extractedText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let title = item.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // An untitled memory with no body is a placeholder — a recording that
        // failed to transcribe, say. Publishing it puts a blank row in the
        // system's search results.
        guard !title.isEmpty, title != "Untitled" || !body.isEmpty else { return nil }

        self.identifier = item.identifier
        self.title = title
        self.summary = Self.flatten(body, limit: Self.summaryLimit)
        // Tags first: they're the words the user chose deliberately, and the
        // system ranks earlier keywords higher.
        self.keywords = Array((item.tagNames + item.keywords).prefix(Self.keywordLimit))
        self.createdAt = item.createdAt
        self.updatedAt = item.updatedAt
        self.thumbnail = item.sortedAttachments.compactMap(\.thumbnail).first
    }

    private static func flatten(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        let head = collapsed.prefix(limit)
        let cut = head.lastIndex(of: " ").map { head[head.startIndex..<$0] } ?? head
        return String(cut) + "…"
    }
}

/// Publishes memories to the system-wide index, so your second brain answers
/// from the place you already search: pull down on the Home Screen, type
/// "cladding", and your own note is in the results next to your apps and mail.
///
/// This is the difference between an app you have to remember to open and a
/// brain that is simply *there*. Everything stays on the device — Core Spotlight
/// is a local index, and Brain Buddy publishes a title, a short summary and
/// keywords, never attachments or full transcripts.
enum SpotlightIndexer {
    static let domainIdentifier = "com.brainbuddy.memory"

    /// Adds or replaces one memory. Indexing by the memory's stable identifier
    /// means a re-donation after an edit updates the entry rather than adding a
    /// second copy of it.
    static func donate(_ records: [SpotlightRecord]) {
        guard !records.isEmpty, CSSearchableIndex.isIndexingAvailable() else { return }
        CSSearchableIndex.default().indexSearchableItems(records.map(item(for:)))
    }

    static func remove(identifiers: [UUID]) {
        guard !identifiers.isEmpty, CSSearchableIndex.isIndexingAvailable() else { return }
        CSSearchableIndex.default().deleteSearchableItems(
            withIdentifiers: identifiers.map(\.uuidString)
        )
    }

    /// Used when the user turns system search off, and before a full rebuild, so
    /// a memory deleted on another device can't linger in this one's index.
    static func removeEverything() {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainIdentifier])
    }

    /// The identifier carried by the `NSUserActivity` when a Spotlight result is
    /// tapped, or `nil` if this activity isn't one of ours.
    static func memoryIdentifier(from activity: NSUserActivity) -> UUID? {
        guard activity.activityType == CSSearchableItemActionType,
              let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else { return nil }
        return UUID(uuidString: raw)
    }

    private static func item(for record: SpotlightRecord) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.text)
        attributes.title = record.title
        attributes.contentDescription = record.summary
        attributes.keywords = record.keywords
        attributes.contentCreationDate = record.createdAt
        attributes.contentModificationDate = record.updatedAt
        attributes.thumbnailData = record.thumbnail

        let item = CSSearchableItem(
            uniqueIdentifier: record.identifier.uuidString,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
        // Without this the entry quietly expires after a month, which for a
        // second brain is exactly backwards: the older a note is, the more
        // likely you've forgotten you have it.
        item.expirationDate = .distantFuture
        return item
    }
}
