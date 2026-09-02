import Foundation

/// One memory reduced to what grouping needs. Keeps the builder off SwiftData so
/// "what lands in which box" is testable without a device.
struct BrainBoxItem: Identifiable {
    let id: UUID
    let kind: MemoryKind
    let tags: [String]
    /// The text topics are read out of.
    let text: String
}

/// One compartment of the brain.
struct BrainBox: Identifiable, Equatable {
    enum Filter: Equatable {
        case everything
        case kind(MemoryKind)
        case tag(String)
        /// A recurring subject, matched by the topic keys stored in the index.
        case topic(String)
    }

    let id: String
    let title: String
    let systemImage: String
    let filter: Filter
    let count: Int
}

/// Boxes, plus which memories belong in the topic ones.
///
/// Topic membership is worked out once and kept, because extracting subjects
/// means two `NLTagger` passes per memory — fine for a whole library on a
/// background pass, far too much to repeat every time a list redraws.
struct BrainBoxIndex {
    var boxes: [BrainBox] = []
    /// Memory id → the topic keys it was filed under.
    var topics: [UUID: Set<String>] = [:]

    func contains(_ item: MemoryItem, in box: BrainBox) -> Bool {
        switch box.filter {
        case .everything:
            return true
        case .kind(let kind):
            return item.kind == kind
        case .tag(let name):
            return item.tagNames.contains(name)
        case .topic(let key):
            return topics[item.identifier]?.contains(key) ?? false
        }
    }
}

/// Sorts a library into boxes.
///
/// The obvious grouping — one box per kind — is useless for how people actually
/// use a capture app: nearly everything is a typed note, so you get one box with
/// everything in it and four empty ones. So the boxes that lead are the
/// **subjects that recur in your own words**: "PCH", "Tower", "Yard". They come
/// out of the text rather than a taxonomy someone invented, which is what makes
/// them match how you think about it.
///
/// Kinds and tags follow, because they're always correct and sometimes exactly
/// what you want ("show me the photos").
enum BrainBoxBuilder {
    /// A subject needs to appear in at least this many memories to earn a box.
    /// One mention is a detail, not a compartment.
    static let minimumTopicItems = 2
    static let maximumTopicBoxes = 6
    /// Subjects considered per memory. Past the first few they stop being what
    /// the memory is about.
    static let topicsPerItem = 4

    static func build(from items: [BrainBoxItem]) -> BrainBoxIndex {
        guard !items.isEmpty else { return BrainBoxIndex() }

        var index = BrainBoxIndex()
        var topicCounts: [String: Int] = [:]
        var topicLabels: [String: String] = [:]

        for item in items {
            var keys = Set<String>()
            for subject in DiscussionSummarizer.topics(in: item.text, limit: topicsPerItem) {
                let key = subject.lowercased()
                guard key.count > 2 else { continue }
                keys.insert(key)
                // Prefer a capitalized spelling when the writer used one: "PCH",
                // not "pch".
                if let existing = topicLabels[key] {
                    if subject.first?.isUppercase == true, existing.first?.isUppercase != true {
                        topicLabels[key] = subject
                    }
                } else {
                    topicLabels[key] = subject
                }
            }
            index.topics[item.id] = keys
            for key in keys { topicCounts[key, default: 0] += 1 }
        }

        let tagCounts = items.reduce(into: [String: Int]()) { counts, item in
            for tag in Set(item.tags) { counts[tag, default: 0] += 1 }
        }

        // A subject that is already a tag would be the same box twice.
        let topicBoxes = topicCounts
            .filter { $0.value >= minimumTopicItems && tagCounts[$0.key] == nil }
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .prefix(maximumTopicBoxes)
            .map { key, count in
                BrainBox(
                    id: "topic.\(key)",
                    title: topicLabels[key] ?? key,
                    systemImage: "circle.hexagongrid.fill",
                    filter: .topic(key),
                    count: count
                )
            }

        let tagBoxes = tagCounts
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .map { name, count in
                BrainBox(
                    id: "tag.\(name)",
                    title: "#\(name)",
                    systemImage: "number",
                    filter: .tag(name),
                    count: count
                )
            }

        let kindCounts = items.reduce(into: [MemoryKind: Int]()) { counts, item in
            counts[item.kind, default: 0] += 1
        }
        let kindBoxes = MemoryKind.allCases.compactMap { kind -> BrainBox? in
            guard let count = kindCounts[kind], count > 0 else { return nil }
            return BrainBox(
                id: "kind.\(kind.rawValue)",
                title: kind.boxTitle,
                systemImage: kind.systemImage,
                filter: .kind(kind),
                count: count
            )
        }

        index.boxes = [
            BrainBox(
                id: "everything",
                title: "Everything",
                systemImage: "square.stack.3d.up.fill",
                filter: .everything,
                count: items.count
            )
        ] + topicBoxes + tagBoxes + kindBoxes

        return index
    }
}

extension MemoryKind {
    /// Plural, because a box holds several.
    var boxTitle: String {
        switch self {
        case .note: return "Notes"
        case .voice: return "Voice notes"
        case .image: return "Photos"
        case .document: return "Documents"
        case .link: return "Links"
        }
    }
}
