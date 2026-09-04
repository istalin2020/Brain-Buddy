import Foundation

/// One memory reduced to what linking needs.
struct ConnectionCandidate: Identifiable, Sendable {
    let id: UUID
    let title: String
    let tags: [String]
    /// Normalized keywords, as stored in `MemoryItem.keywordIndex`.
    let keywords: [String]
    let embedding: [Double]?
    let createdAt: Date
}

/// A link the app found on its own, with the reason it thinks so.
struct Connection: Identifiable, Equatable, Sendable {
    let id: UUID
    let strength: Double
    /// Shown to the user. A link you can't explain is a link you can't trust.
    let reason: String
}

/// Finds the memories that belong with the one you're looking at.
///
/// This is the part a folder can't do. You save a note in March and a recording
/// in July and never connect them, because remembering to connect things is the
/// work you downloaded a second brain to avoid. So the app does it: open
/// anything and the memories that share its subject are already there, each with
/// the reason it was linked.
///
/// Three signals, in order of how much they mean:
///
/// 1. **Shared tags.** You chose those words yourself. Nothing else is that
///    deliberate.
/// 2. **Shared rare words**, weighted by how rare they are *in your own
///    library*. This is the signal that separates a real link from a coincidence:
///    two notes both containing "cladding" are about the same thing, two notes
///    both containing "project" are not. Frequency is measured across your
///    library rather than against a general word list, because the words that
///    are meaningless in *your* notes are the ones you write constantly.
/// 3. **Meaning**, from the sentence embeddings already stored for search, with
///    a floor under it — unrelated English prose sits around 0.5 cosine, so
///    anything less than clearly-similar has to count for nothing.
///
/// Weak links are dropped rather than padded out to fill the section. A wrong
/// connection costs more than an empty space: it teaches you not to trust the
/// ones that are right.
enum ConnectionFinder {
    /// Below this, a link is a coincidence.
    static let minimumStrength = 0.3
    static let defaultLimit = 4
    /// A word in this share of the library or more says nothing about what a
    /// memory is about.
    static let ubiquitousTermShare = 0.5
    /// Cosine similarity below this counts as unrelated.
    static let semanticFloor = 0.62

    static func related(
        to subject: ConnectionCandidate,
        among library: [ConnectionCandidate],
        limit: Int = defaultLimit
    ) -> [Connection] {
        let others = library.filter { $0.id != subject.id }
        guard !others.isEmpty else { return [] }

        let subjectTerms = Set(subject.keywords)
        let subjectTags = Set(subject.tags)

        // Document frequency across the whole library, including the subject, so
        // "how rare is this word for me" is answered by the library itself.
        var frequency: [String: Int] = [:]
        for candidate in library {
            for term in Set(candidate.keywords) { frequency[term, default: 0] += 1 }
        }
        let total = max(1, library.count)
        // Never below two: a *shared* word is in at least two memories by
        // definition, so a smaller ceiling would discard every link in a young
        // library.
        let ceiling = max(2, Int(Double(total) * ubiquitousTermShare))

        var found: [Connection] = []
        for other in others {
            let sharedTags = subjectTags.intersection(other.tags)

            let sharedTerms = subjectTerms
                .intersection(other.keywords)
                // A word in half your library is furniture, not a subject.
                .filter { (frequency[$0] ?? 0) <= ceiling }
                .sorted { lhs, rhs in
                    let left = frequency[lhs] ?? 0
                    let right = frequency[rhs] ?? 0
                    return left == right ? lhs < rhs : left < right
                }

            let termScore = sharedTerms.reduce(into: 0.0) { score, term in
                let documents = Double(frequency[term] ?? 1)
                // Rarity, normalized so a word appearing once elsewhere counts
                // fully and a common one barely registers.
                score += min(1, log(Double(total) / documents) / log(Double(max(2, total))))
            }

            let semantic: Double
            if let lhs = subject.embedding, let rhs = other.embedding {
                let cosine = VectorMath.cosineSimilarity(lhs, rhs)
                semantic = max(0, (cosine - semanticFloor) / (1 - semanticFloor))
            } else {
                semantic = 0
            }

            let strength = min(
                1,
                0.55 * min(1, Double(sharedTags.count) * 0.7)
                    + 0.55 * min(1, termScore)
                    + 0.45 * semantic
            )
            guard strength >= minimumStrength else { continue }

            found.append(
                Connection(
                    id: other.id,
                    strength: strength,
                    reason: reason(tags: sharedTags.sorted(), terms: sharedTerms, semantic: semantic)
                )
            )
        }

        return found
            .sorted { lhs, rhs in
                lhs.strength == rhs.strength ? lhs.id.uuidString < rhs.id.uuidString : lhs.strength > rhs.strength
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Plain English, and specific: naming the shared word is what lets you tell
    /// at a glance whether the link is the one you were hoping for.
    static func reason(tags: [String], terms: [String], semantic: Double) -> String {
        if !tags.isEmpty {
            let named = tags.prefix(2).map { "#\($0)" }.joined(separator: " and ")
            return "Both tagged \(named)"
        }
        if !terms.isEmpty {
            let named = terms.prefix(2).joined(separator: " and ")
            return "Both mention \(named)"
        }
        return semantic > 0.5 ? "Reads like the same subject" : "Related wording"
    }
}

extension ConnectionCandidate {
    init(_ item: MemoryItem) {
        self.id = item.identifier
        self.title = item.displayTitle
        self.tags = item.tagNames
        self.keywords = item.keywords
        self.embedding = item.embedding
        self.createdAt = item.createdAt
    }
}
