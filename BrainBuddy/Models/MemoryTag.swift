import Foundation
import SwiftData

/// A user-visible label. Tags are many-to-many with memories; the inverse is
/// declared here so `MemoryItem.tags` stays a plain optional array.
@Model
final class MemoryTag {
    var name: String = ""
    var createdAt: Date = Date()

    @Relationship(inverse: \MemoryItem.tags)
    var items: [MemoryItem]? = []

    init(name: String) {
        self.name = MemoryTag.normalize(name)
        self.createdAt = Date()
    }

    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .lowercased()
    }
}
