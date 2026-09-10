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
}

/// Groups a library by the subjects that recur in it.
///
/// The subjects come out of your own text — "PCH", "Tower", "Yard" — rather than
/// from a taxonomy someone invented, which is what makes them match how you
/// think about the work. Tags and kinds follow, because they're always correct.
///
/// This used to draw the Brain tab, which is now a 3D cortex map
/// (`BrainClassifier`). What it still does is answer *"what did you keep coming
/// back to"* for the weekly review — the one place where recurring subjects, and
/// not fixed regions, are the question.
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
