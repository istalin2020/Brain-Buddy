import Foundation

/// A ranked memory, ready to render.
struct SearchHit: Identifiable {
    let item: MemoryItem
    let score: Double
    let lexicalScore: Double
    let semanticScore: Double
    let snippet: String

    var id: UUID { item.identifier }

    /// Human-readable reason the row is here, shown under the snippet.
    var matchExplanation: String {
        switch (lexicalScore > 0.15, semanticScore > 0.15) {
        case (true, true): return "keyword + meaning match"
        case (true, false): return "keyword match"
        case (false, true): return "meaning match"
        case (false, false): return "weak match"
        }
    }
}

extension SearchEngine {
    /// Drops matches far weaker than the best one.
    ///
    /// Ranking always returns *something*: ask what's on your purchase list
    /// and a meeting invitation still scores, because a word or two overlaps
    /// somewhere in it. That is fine for a results page, where a weak match at
    /// position nine costs a glance, and wrong under an answer, where every
    /// row reads as "this is part of what you asked for".
    ///
    /// Relative to the best match rather than an absolute number, because
    /// scores are fused and normalized per query — there is no fixed value
    /// that means "good" across different questions. The best match always
    /// survives.
    static func confident(_ hits: [SearchHit], floor: Double = AnswerComposer.relevanceFloor) -> [SearchHit] {
        guard let best = hits.map(\.score).max(), best > 0 else { return hits }
        return hits.filter { $0.score >= best * floor }
    }

    /// Bridges stored memories into the pure ranking layer and back.
    func search(query: String, in items: [MemoryItem], limit: Int = 30) -> [SearchHit] {
        let live = items.filter { !$0.isTrashed }
        guard !live.isEmpty else { return [] }

        let documents = live.map { item in
            SearchDocument(
                id: item.identifier,
                title: item.title,
                body: [item.text, item.extractedText]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n"),
                keywords: ([item.keywordIndex] + item.tagNames).joined(separator: " "),
                createdAt: item.createdAt,
                isPinned: item.isPinned,
                embedding: item.embedding
            )
        }

        let ranked = rank(query: query, documents: documents, limit: limit)
        let byIdentifier = Dictionary(live.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })

        return ranked.compactMap { scored in
            guard let item = byIdentifier[scored.id] else { return nil }
            return SearchHit(
                item: item,
                score: scored.score,
                lexicalScore: scored.lexicalScore,
                semanticScore: scored.semanticScore,
                snippet: scored.snippet.isEmpty ? item.preview : scored.snippet
            )
        }
    }
}
