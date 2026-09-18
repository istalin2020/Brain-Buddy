import Foundation

/// An in-memory BM25 inverted index.
///
/// BM25 rather than plain substring matching because a second brain accumulates
/// thousands of notes: term rarity (IDF) and document length normalization are
/// what stop one long PDF from dominating every result list.
struct BM25Index {
    /// Term-frequency saturation. 1.2 is the standard Robertson/Walker value.
    private let k1: Double = 1.2
    /// Length-normalization strength.
    private let b: Double = 0.75

    /// term -> (document key -> term frequency)
    private var postings: [String: [UUID: Int]] = [:]
    private var documentLengths: [UUID: Int] = [:]
    private var averageLength: Double = 0

    var documentCount: Int { documentLengths.count }

    init(documents: [(key: UUID, text: String)]) {
        var totalLength = 0
        for document in documents {
            let terms = Tokenizer.tokens(in: document.text)
            documentLengths[document.key] = terms.count
            totalLength += terms.count
            for term in terms {
                postings[term, default: [:]][document.key, default: 0] += 1
            }
        }
        averageLength = documents.isEmpty ? 0 : Double(totalLength) / Double(documents.count)
    }

    /// Inverse document frequency, using the BM25+ non-negative variant so a
    /// term present in most documents can never push a score below zero.
    ///
    /// Also read by the snippet picker: which line of a document answers a
    /// question depends on which of the query's words are rare.
    func inverseDocumentFrequency(for term: String) -> Double {
        let documentFrequency = Double(postings[term]?.count ?? 0)
        guard documentFrequency > 0 else { return 0 }
        let total = Double(documentCount)
        return log(1 + (total - documentFrequency + 0.5) / (documentFrequency + 0.5))
    }

    /// Scores every document that contains at least one query term.
    func scores(for queryTerms: [String]) -> [UUID: Double] {
        guard documentCount > 0, averageLength > 0 else { return [:] }
        var results: [UUID: Double] = [:]

        for term in Set(queryTerms) {
            guard let matches = postings[term] else { continue }
            let idf = inverseDocumentFrequency(for: term)
            guard idf > 0 else { continue }

            for (key, frequency) in matches {
                let length = Double(documentLengths[key] ?? 0)
                let tf = Double(frequency)
                let denominator = tf + k1 * (1 - b + b * length / averageLength)
                guard denominator > 0 else { continue }
                results[key, default: 0] += idf * (tf * (k1 + 1)) / denominator
            }
        }

        return results
    }

    /// How many distinct query terms a document actually contains. Used to
    /// reward documents that cover the whole question rather than one rare word.
    func coverage(of queryTerms: [String], in key: UUID) -> Double {
        let unique = Set(queryTerms)
        guard !unique.isEmpty else { return 0 }
        let present = unique.filter { postings[$0]?[key] != nil }.count
        return Double(present) / Double(unique.count)
    }
}
