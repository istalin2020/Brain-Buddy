import Foundation
import SwiftData

/// What kind of line this is in a morning brief.
enum BriefEntryKind: String, CaseIterable, Identifiable, Codable {
    /// Something happening at a time today — a meeting, an appointment.
    case schedule
    /// Something to get done, pulled from a commitment you recorded.
    case task
    /// A key point worth having in mind, from a discussion you summarized.
    case point

    var id: String { rawValue }

    var title: String {
        switch self {
        case .schedule: return "Today's schedule"
        case .task: return "Tasks"
        case .point: return "Key points"
        }
    }

    var systemImage: String {
        switch self {
        case .schedule: return "calendar"
        case .task: return "checklist"
        case .point: return "lightbulb"
        }
    }
}

/// One line of one day's brief, with whether you've closed it.
///
/// Persisted rather than recomputed on the fly, because the open/closed state is
/// the whole point: a brief you can't tick off is just a search result. Closing
/// something has to survive relaunching, and has to sync to your other devices.
///
/// Follows the same CloudKit rules as the rest of the schema — every attribute
/// defaulted, no unique constraints, no relationships. `sourceIdentifier` is a
/// loose reference to `MemoryItem.identifier` on purpose: a real relationship
/// would need an inverse on `MemoryItem`, which means changing a shipped model
/// for a link that only the detail navigation ever follows.
@Model
final class BriefEntry {
    var identifier: UUID = UUID()

    /// Midnight of the day this line belongs to.
    var day: Date = Date()

    var kindRaw: String = BriefEntryKind.task.rawValue

    /// The line itself — a sentence quoted from what you captured.
    var text: String = ""

    /// A short subject for a long line, so the brief can be read at a glance
    /// rather than at paragraph length. Empty when `text` is already short enough
    /// to be its own heading.
    var headline: String = ""

    /// Where it came from, e.g. the title of the note it was quoted out of.
    var detail: String = ""

    /// When a schedule item happens, if a time was detected.
    var scheduledAt: Date? = nil

    var isClosed: Bool = false
    var closedAt: Date? = nil

    /// `MemoryItem.identifier` of the capture this came from.
    var sourceIdentifier: UUID? = nil

    var sortIndex: Int = 0
    var createdAt: Date = Date()

    init(
        day: Date,
        kind: BriefEntryKind,
        text: String,
        headline: String = "",
        detail: String = "",
        scheduledAt: Date? = nil,
        sourceIdentifier: UUID? = nil,
        sortIndex: Int = 0
    ) {
        self.identifier = UUID()
        self.day = day
        self.kindRaw = kind.rawValue
        self.text = text
        self.headline = headline
        self.detail = detail
        self.scheduledAt = scheduledAt
        self.sourceIdentifier = sourceIdentifier
        self.sortIndex = sortIndex
        self.createdAt = Date()
    }
}

extension BriefEntry {
    var kind: BriefEntryKind {
        get { BriefEntryKind(rawValue: kindRaw) ?? .task }
        set { kindRaw = newValue.rawValue }
    }

    /// Used to recognize the same line across days so a task you left open
    /// doesn't get re-added as a brand new row every morning.
    var dedupeKey: String { BriefEntry.dedupeKey(for: text) }

    static func dedupeKey(for text: String) -> String {
        Tokenizer.tokens(in: text).joined(separator: " ")
    }

    /// What the row leads with.
    var subject: String { headline.isEmpty ? text : headline }

    /// The full quote, shown under the subject only when it says more than the
    /// subject already does.
    var supportingText: String? { headline.isEmpty ? nil : text }

    var scheduledTimeLabel: String? {
        guard let scheduledAt else { return nil }
        return scheduledAt.formatted(date: .omitted, time: .shortened)
    }
}
