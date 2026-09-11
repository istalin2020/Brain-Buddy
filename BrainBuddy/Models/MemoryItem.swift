import Foundation
import SwiftData

/// The kind of capture a memory came from. Stored as a raw string so that new
/// cases can be added without a CloudKit schema migration.
enum MemoryKind: String, CaseIterable, Identifiable, Codable {
    case note
    case voice
    case image
    case document
    case link

    var id: String { rawValue }

    var title: String {
        switch self {
        case .note: return "Note"
        case .voice: return "Voice"
        case .image: return "Image"
        case .document: return "Document"
        case .link: return "Link"
        }
    }

    /// Longer form for places that name where a line came from, where "Voice"
    /// on its own reads like a fragment.
    var sourceLabel: String {
        switch self {
        case .voice: return "Voice note"
        default: return title
        }
    }

    var systemImage: String {
        switch self {
        case .note: return "text.alignleft"
        case .voice: return "waveform"
        case .image: return "photo"
        case .document: return "doc.richtext"
        case .link: return "link"
        }
    }
}

/// A single thing you put into your second brain.
///
/// Every capture — typed text, a voice note, a photo, a PDF — becomes one
/// `MemoryItem`. Whatever text we can pull out of the capture (transcript, OCR,
/// extracted PDF text) lands in `text` / `extractedText` so a single search path
/// covers every input type.
///
/// CloudKit mirroring requires every stored attribute to be optional or to carry
/// a default value, forbids unique constraints, and requires to-many
/// relationships to be optional. The model below follows those rules.
@Model
final class MemoryItem {
    /// Stable identifier that survives sync. (`persistentModelID` is local-only.)
    var identifier: UUID = UUID()

    var title: String = ""

    /// Set once the user edits this memory themselves, so that re-deriving
    /// subjects in bulk can never overwrite a title somebody chose.
    var hasCustomTitle: Bool = false

    /// The primary body: what you typed, or the transcript of what you said.
    var text: String = ""

    /// Text machine-extracted from attachments (OCR, PDF text layer).
    var extractedText: String = ""

    /// A summary the user asked for and saved — key points and follow-ups pulled
    /// out of a long transcript. Empty until they press Save on one, because an
    /// unsaved summary is a suggestion, not a fact about the memory.
    ///
    /// Added after the first release. CloudKit mirroring accepts new attributes
    /// that carry a default value, so existing records simply read back "".
    var summary: String = ""

    /// True when nobody has reviewed `summary` — the app wrote it at capture so
    /// a scan or a recording has something readable under its name.
    ///
    /// The distinction matters beyond labelling: a summary you pressed Save on
    /// is treated as something you *said*, and can put lines in your morning
    /// brief. One the app wrote from a document cannot, for the same reason OCR
    /// text can't — see `BriefService`.
    ///
    /// Added after the first release; CloudKit mirroring accepts new attributes
    /// that carry a default, so existing records read back `false`.
    var summaryIsAutomatic: Bool = false

    /// Hash of this capture's own content, used to recognise the same thing
    /// arriving twice. Empty for anything captured before this existed.
    var contentFingerprint: String = ""

    var kindRaw: String = MemoryKind.note.rawValue

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var isPinned: Bool = false
    var isTrashed: Bool = false

    /// Where this came from, e.g. an original filename.
    var source: String = ""

    /// Space-separated keywords, kept as a plain string so it mirrors to
    /// CloudKit as a simple indexable field.
    var keywordIndex: String = ""

    /// Cached sentence embedding, encoded as little-endian `Float32` values.
    var embeddingData: Data? = nil

    @Relationship(deleteRule: .cascade, inverse: \MemoryAttachment.memory)
    var attachments: [MemoryAttachment]? = []

    var tags: [MemoryTag]? = []

    init(
        title: String = "",
        text: String = "",
        extractedText: String = "",
        kind: MemoryKind = .note,
        source: String = "",
        createdAt: Date = Date()
    ) {
        self.identifier = UUID()
        self.title = title
        self.text = text
        self.extractedText = extractedText
        self.kindRaw = kind.rawValue
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

extension MemoryItem {
    var kind: MemoryKind {
        get { MemoryKind(rawValue: kindRaw) ?? .note }
        set { kindRaw = newValue.rawValue }
    }

    var sortedAttachments: [MemoryAttachment] {
        (attachments ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    var tagNames: [String] {
        (tags ?? []).map(\.name).sorted()
    }

    var keywords: [String] {
        keywordIndex.split(separator: " ").map(String.init)
    }

    var hasSummary: Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Everything a search should look at, in one string.
    var searchableText: String {
        var parts = [title, text]
        if !summary.isEmpty { parts.append(summary) }
        if !extractedText.isEmpty { parts.append(extractedText) }
        if !source.isEmpty { parts.append(source) }
        let names = tagNames
        if !names.isEmpty { parts.append(names.joined(separator: " ")) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The text shown under the title in lists.
    var preview: String {
        let body = text.isEmpty ? extractedText : text
        let collapsed = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(240))
    }

    var displayTitle: String {
        title.isEmpty ? (preview.isEmpty ? "Untitled" : String(preview.prefix(60))) : title
    }

    /// The one line worth reading under the heading in a list — or nothing.
    ///
    /// Rows used to show `displayTitle` with `preview` beneath it, which for a
    /// typed note is the same sentence twice: the title *is* the first sixty
    /// characters of the body. So this prefers a saved summary's first key
    /// point, falls back to the body, and returns "" when whatever it picked
    /// only restates the heading. A row that says one thing once is shorter and
    /// tells you more.
    var listSummary: String {
        let heading = displayTitle

        let lead = summaryLead
        if !lead.isEmpty, !Self.restates(lead, heading) {
            return Self.clip(lead, to: Self.listSummaryLimit)
        }

        let rest = Self.remainder(of: preview, beyond: heading)
        guard rest.count >= Self.minimumSummaryLength else { return "" }
        return Self.clip(rest, to: Self.listSummaryLimit)
    }

    /// Roughly two lines at footnote size on a phone.
    private static let listSummaryLimit = 150

    /// Below this, what's left of the body after the heading is a fragment
    /// rather than a summary, and the row reads better without it.
    private static let minimumSummaryLength = 24

    /// The saved summary reduced to its most useful single line: what was
    /// decided, else what it was about.
    private var summaryLead: String {
        guard hasSummary, let parsed = DiscussionSummarizer.parse(summary) else { return "" }
        if let point = parsed.keyPoints.first { return point }
        if let followUp = parsed.followUps.first { return followUp }
        guard !parsed.topics.isEmpty else { return "" }
        return parsed.topics.joined(separator: ", ")
    }

    /// True when `candidate` opens with the same words as the heading, which is
    /// what happens whenever the title was derived from the body. Compared on
    /// normalized tokens so punctuation and an ellipsis don't hide it.
    private static func restates(_ candidate: String, _ heading: String) -> Bool {
        let headingTokens = Tokenizer.tokens(in: heading)
        guard !headingTokens.isEmpty else { return false }
        let candidateTokens = Tokenizer.tokens(in: candidate)
        guard candidateTokens.count >= headingTokens.count else {
            return candidateTokens == Array(headingTokens.prefix(candidateTokens.count))
        }
        return Array(candidateTokens.prefix(headingTokens.count)) == headingTokens
    }

    /// What the body still has to say once the heading has been read.
    ///
    /// Titles are derived from the text (see `TextAnalysis.suggestedTitle`), so
    /// the body normally opens with the heading word for word. Showing it again
    /// is the duplication this whole property exists to remove — but the *rest*
    /// of the body usually is the summary, so it is kept.
    private static func remainder(of text: String, beyond heading: String) -> String {
        guard restates(text, heading) else { return text }

        // Dropped by word count rather than by matching the heading string,
        // because a derived heading is sometimes a condensed version of the
        // opening rather than a literal prefix of it. Over-keeping a word reads
        // fine; failing to match at all would throw the summary away.
        let spoken = heading.trimmingCharacters(in: headingNoise)
            .split(separator: " ", omittingEmptySubsequences: true)
            .count
        guard spoken > 0 else { return text }

        let rest = text
            .split(separator: " ", omittingEmptySubsequences: true)
            .dropFirst(spoken)
            .joined(separator: " ")
        return rest.trimmingCharacters(in: headingNoise)
    }

    /// Punctuation a heading can end on, and that a continuation shouldn't start
    /// with.
    private static let headingNoise = CharacterSet(charactersIn: " .,;:-–—…")
        .union(.whitespacesAndNewlines)

    /// Cuts at a word boundary rather than mid-word, and only adds an ellipsis
    /// when something was actually removed.
    private static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        let cut = head.lastIndex(of: " ").map { head[head.startIndex..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    var embedding: [Double]? {
        get { embeddingData.flatMap(VectorMath.decode) }
        set { embeddingData = newValue.map(VectorMath.encode) }
    }

    func touch(date: Date = Date()) {
        updatedAt = date
    }
}
