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
                    snippet: Self.snippet(
                        for: queryTerms,
                        in: document.body.isEmpty ? document.title : document.body,
                        // The index already knows which of the query's words are
                        // rare across everything saved; the line picker needs it
                        // for exactly the same reason ranking does.
                        corpusWeight: { index.inverseDocumentFrequency(for: $0) }
                    )
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

    /// Picks the line that answers the question, rather than the first line that
    /// happens to contain one of its words.
    ///
    /// Counting matched terms is not enough, and the way it fails is instructive.
    /// "What is my TSH value from the latest report" matches `report` on three
    /// header lines of a lab report — *Report No*, *Reported Date*, *Report
    /// Status* — and `tsh` on exactly one result row. One match each, so the
    /// header wins on document order, and the app confidently answers with a
    /// date. Four signals fix that, in order of weight:
    ///
    /// 1. **Rare words count for more.** A term on many lines of a document
    ///    explains nothing about which line to show; `report` is everywhere in a
    ///    report, `tsh` is the thing being asked about.
    /// 2. **Rare across your whole brain counts for more**, when the caller can
    ///    supply corpus IDF — which `rank` can, from the index it already built.
    /// 3. **A label next to a number is an answer.** `TSH 5.46` puts a matched
    ///    term immediately before a value; `Reported Date : 29/07/2026` doesn't.
    ///    That shape is exactly what "what is my X" is asking for.
    /// 4. **Any number at all** settles what's left.
    ///
    /// One repair on top: a bare label is joined to the line beneath it, because
    /// OCR splits table rows into separate observations often enough that the
    /// label and its value end up on consecutive lines.
    static func snippet(
        for queryTerms: [String],
        in text: String,
        limit: Int = 220,
        corpusWeight: ((String) -> Double)? = nil
    ) -> String {
        let lines = Tokenizer.sentences(in: text)
        guard !lines.isEmpty else { return String(text.prefix(limit)) }

        let wanted = Set(queryTerms)
        guard !wanted.isEmpty else { return clipped(lines[0], to: limit) }

        let lineTokens = lines.map { Tokenizer.tokens(in: $0) }
        let weights = termWeights(for: wanted, across: lineTokens, corpusWeight: corpusWeight)

        var bestIndex = 0
        var bestScore = 0.0
        var didMatch = false

        for (index, tokens) in lineTokens.enumerated() {
            let present = Set(tokens).intersection(wanted)
            guard !present.isEmpty else { continue }

            // Floor, so a line that matched still beats one that didn't even when
            // every one of its terms turned out to be worthless.
            var score = max(0.001, present.reduce(0.0) { $0 + (weights[$1] ?? 0) })
            if labelPrecedesValue(tokens, wanted: wanted) {
                score *= 2.5
            } else if tokens.contains(where: { $0.first?.isNumber == true }) {
                score *= 1.05
            }

            if score > bestScore {
                bestScore = score
                bestIndex = index
                didMatch = true
            }
        }

        var best = lines[bestIndex]
        if didMatch,
           !best.contains(where: \.isNumber),
           bestIndex + 1 < lines.count {
            let follower = lines[bestIndex + 1]
            if follower.contains(where: \.isNumber), best.count + follower.count + 1 <= limit {
                best += " " + follower
            }
        }
        return clipped(best, to: limit)
    }

    /// How much each query term should count, given how common it is here and —
    /// when the caller knows — across everything else you've saved.
    private static func termWeights(
        for terms: Set<String>,
        across lineTokens: [[String]],
        corpusWeight: ((String) -> Double)?
    ) -> [String: Double] {
        let lineCount = Double(lineTokens.count)
        guard lineCount > 0 else { return [:] }

        var weights: [String: Double] = [:]
        for term in terms {
            let containing = Double(lineTokens.reduce(into: 0) { $0 += $1.contains(term) ? 1 : 0 })
            guard containing > 0 else { continue }
            let local = log(1 + lineCount / containing)
            // Clamped, so a term common across the corpus is discounted rather
            // than annihilated — it may still be the only thing that matched.
            let global = corpusWeight.map { max(0.1, $0(term)) } ?? 1
            weights[term] = local * global
        }
        return weights
    }

    /// The label-then-value shape: a matched term immediately followed by a
    /// number. A lab row, an invoice line, a receipt total.
    private static func labelPrecedesValue(_ tokens: [String], wanted: Set<String>) -> Bool {
        for (index, token) in tokens.enumerated() where wanted.contains(token) {
            guard index + 1 < tokens.count else { continue }
            if tokens[index + 1].first?.isNumber == true { return true }
        }
        return false
    }

    private static func clipped(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
