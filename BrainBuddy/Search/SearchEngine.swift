import Foundation

/// A model-agnostic view of one memory, so ranking can be tested without
/// SwiftData or a CloudKit container.
struct SearchDocument: Identifiable {
    let id: UUID
    let title: String
    let body: String
    let keywords: String
    let createdAt: Date
    let isPinned: Bool
    let embedding: [Double]?

    init(
        id: UUID,
        title: String,
        body: String,
        keywords: String = "",
        createdAt: Date = Date(),
        isPinned: Bool = false,
        embedding: [Double]? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.keywords = keywords
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.embedding = embedding
    }

    /// Title is repeated so that a term in the title outranks the same term
    /// buried in a 30-page PDF — a cheap, predictable field boost.
    var indexedText: String {
        [title, title, keywords, body].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// One ranked document, with the component scores kept for debugging and for
/// the "why did this match" line in the UI.
struct ScoredDocument: Identifiable {
    let id: UUID
    let score: Double
    let lexicalScore: Double
    let semanticScore: Double
    let snippet: String
}

/// Hybrid retrieval: BM25 keyword matching fused with on-device semantic
/// similarity.
///
/// Neither alone is enough. Keywords fail when you remember the idea but not
/// the wording ("that thing about sleeping better"); embeddings fail on exact
/// tokens like order numbers and names. Running both and fusing the normalized
/// scores handles the way people actually query their own notes.
final class SearchEngine {
    struct Weights {
        var lexical: Double = 0.62
        var semantic: Double = 0.38
        /// Small nudge so that among equally relevant notes, recent ones win.
        var recency: Double = 0.06
        var pinned: Double = 0.05
        /// Reward for covering more of the query's distinct terms.
        var coverage: Double = 0.12
    }

    var weights = Weights()
    var isSemanticEnabled = true

    private var cachedIndex: BM25Index?
    private var cacheSignature: String = ""

    // MARK: - Ranking

    func rank(query: String, documents: [SearchDocument], limit: Int = 30) -> [ScoredDocument] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !documents.isEmpty else { return [] }

        let queryTerms = Tokenizer.queryTokens(in: trimmed)
        let index = index(for: documents)

        let rawLexical = index.scores(for: queryTerms)
        let maximumLexical = rawLexical.values.max() ?? 0

        var semantic: [UUID: Double] = [:]
        if isSemanticEnabled, let queryVector = EmbeddingService.shared.vector(for: trimmed) {
            for document in documents {
                guard let vector = document.embedding else { continue }
                // Cosine lives in [-1, 1]; only positive similarity is signal.
                semantic[document.id] = max(0, VectorMath.cosineSimilarity(queryVector, vector))
            }
        }
        let maximumSemantic = semantic.values.max() ?? 0

        let now = Date()
        let byIdentifier = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var scored: [ScoredDocument] = []
        // Only consider documents that at least one retriever liked.
        let candidates = Set(rawLexical.keys).union(semantic.keys.filter { (semantic[$0] ?? 0) > 0.25 })

        for identifier in candidates {
            guard let document = byIdentifier[identifier] else { continue }

            let lexical = maximumLexical > 0 ? (rawLexical[identifier] ?? 0) / maximumLexical : 0
            let meaning = maximumSemantic > 0 ? (semantic[identifier] ?? 0) / maximumSemantic : 0
            guard lexical > 0 || meaning > 0 else { continue }

            var total = weights.lexical * lexical + weights.semantic * meaning
            total += weights.coverage * index.coverage(of: queryTerms, in: identifier)
            total += weights.recency * recencyBoost(for: document.createdAt, now: now)
            if document.isPinned { total += weights.pinned }

            scored.append(
                ScoredDocument(
                    id: identifier,
                    score: total,
                    lexicalScore: lexical,
                    semanticScore: meaning,
                    snippet: Self.snippet(for: queryTerms, in: document.body.isEmpty ? document.title : document.body)
                )
            )
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Half-life decay over roughly a year, clamped to `0...1`.
    private func recencyBoost(for date: Date, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(date) / 86_400)
        return exp(-days / 365)
    }

    // MARK: - Index cache

    /// Rebuilding the index on every keystroke is wasteful, so it is cached and
    /// invalidated by a cheap signature of the corpus.
    private func index(for documents: [SearchDocument]) -> BM25Index {
        let signature = Self.signature(for: documents)
        if let cachedIndex, signature == cacheSignature { return cachedIndex }
        let built = BM25Index(documents: documents.map { ($0.id, $0.indexedText) })
        cachedIndex = built
        cacheSignature = signature
        return built
    }

    func invalidateCache() {
        cachedIndex = nil
        cacheSignature = ""
    }

    private static func signature(for documents: [SearchDocument]) -> String {
        var hasher = Hasher()
        hasher.combine(documents.count)
        for document in documents {
            hasher.combine(document.id)
            hasher.combine(document.body.count)
            hasher.combine(document.title.count)
        }
        return String(hasher.finalize())
    }

    // MARK: - Snippets

    /// Picks the line with the most query terms, so the result row shows the part
    /// you were actually looking for instead of the first line.
    ///
    /// Two refinements matter for documents, which is where the answer to a
    /// question like "what was my TSH" usually lives:
    ///
    /// 1. **A number breaks ties.** `TSH` as a section heading and
    ///    `TSH 5.46 0.270 - 4.20 uIU/mL` both match the word; only one of them
    ///    answers the question.
    /// 2. **A bare label is joined to the line below it.** OCR splits a table row
    ///    into separate observations often enough that the label and its value
    ///    land on consecutive lines, and a snippet of just `TSH` is useless.
    static func snippet(for queryTerms: [String], in text: String, limit: Int = 220) -> String {
        let lines = Tokenizer.sentences(in: text)
        guard !lines.isEmpty else { return String(text.prefix(limit)) }

        let wanted = Set(queryTerms)
        var bestIndex = 0
        var bestScore = -1
        var bestMatches = 0

        for (index, line) in lines.enumerated() {
            let matches = Set(Tokenizer.tokens(in: line)).intersection(wanted).count
            let score = matches * 10 + (line.contains(where: \.isNumber) ? 1 : 0)
            if score > bestScore {
                bestScore = score
                bestMatches = matches
                bestIndex = index
            }
        }

        var best = lines[bestIndex]
        if bestMatches > 0,
           !best.contains(where: \.isNumber),
           bestIndex + 1 < lines.count {
            let follower = lines[bestIndex + 1]
            if follower.contains(where: \.isNumber), best.count + follower.count + 1 <= limit {
                best += " " + follower
            }
        }

        if best.count <= limit { return best }
        return String(best.prefix(limit)) + "…"
    }
}
