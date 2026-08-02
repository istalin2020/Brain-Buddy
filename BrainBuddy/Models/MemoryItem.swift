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

    /// The primary body: what you typed, or the transcript of what you said.
    var text: String = ""

    /// Text machine-extracted from attachments (OCR, PDF text layer).
    var extractedText: String = ""

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

    /// Everything a search should look at, in one string.
    var searchableText: String {
        var parts = [title, text]
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

    var embedding: [Double]? {
        get { embeddingData.flatMap(VectorMath.decode) }
        set { embeddingData = newValue.map(VectorMath.encode) }
    }

    func touch(date: Date = Date()) {
        updatedAt = date
    }
}
