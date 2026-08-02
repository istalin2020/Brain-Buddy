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
