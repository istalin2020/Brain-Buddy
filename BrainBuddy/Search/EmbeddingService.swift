import Foundation
import NaturalLanguage

/// Produces on-device sentence embeddings so search can match meaning, not just
/// words — "how do I get to the office" should find a note that says
/// "directions to work".
///
/// Everything here is Apple's built-in `NLEmbedding`: no network, no API key,
/// and it keeps working in airplane mode. If the OS has no sentence model for
/// the detected language we fall back to averaging word vectors, and if that is
/// missing too the caller simply gets `nil` and search stays purely lexical.
final class EmbeddingService {
    static let shared = EmbeddingService()

    /// Sentence embeddings are trained on short inputs; longer text is chunked.
    private let maximumCharactersPerChunk = 220
    private let maximumChunks = 48

    private var sentenceEmbeddings: [NLLanguage: NLEmbedding] = [:]
    private var wordEmbeddings: [NLLanguage: NLEmbedding] = [:]
    private let lock = NSLock()

    private init() {}

    var isAvailable: Bool {
        sentenceEmbedding(for: .english) != nil || wordEmbedding(for: .english) != nil
    }

    /// A single normalized vector for an arbitrary amount of text.
    func vector(for text: String) -> [Double]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let language = dominantLanguage(of: trimmed)
        let chunks = chunk(trimmed)

        if let model = sentenceEmbedding(for: language) {
            let vectors = chunks.compactMap { model.vector(for: $0) }
            if let mean = VectorMath.mean(of: vectors) {
                return VectorMath.normalized(mean)
            }
        }

        if let model = wordEmbedding(for: language) {
            let words = Tokenizer.tokens(in: trimmed).prefix(400)
            let vectors = words.compactMap { model.vector(for: $0) }
            if let mean = VectorMath.mean(of: vectors) {
                return VectorMath.normalized(mean)
            }
        }

        return nil
    }

    // MARK: - Internals

    private func dominantLanguage(of text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage ?? .english
    }

    private func sentenceEmbedding(for language: NLLanguage) -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = sentenceEmbeddings[language] { return cached }
        guard let model = NLEmbedding.sentenceEmbedding(for: language)
            ?? NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        sentenceEmbeddings[language] = model
        return model
    }

    private func wordEmbedding(for language: NLLanguage) -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = wordEmbeddings[language] { return cached }
        guard let model = NLEmbedding.wordEmbedding(for: language)
            ?? NLEmbedding.wordEmbedding(for: .english) else { return nil }
        wordEmbeddings[language] = model
        return model
    }

    /// Groups sentences into chunks no longer than `maximumCharactersPerChunk`.
    private func chunk(_ text: String) -> [String] {
        let sentences = Tokenizer.sentences(in: text)
        guard !sentences.isEmpty else { return [String(text.prefix(maximumCharactersPerChunk))] }

        var chunks: [String] = []
        var current = ""
        for sentence in sentences {
            let candidate = current.isEmpty ? sentence : current + " " + sentence
            if candidate.count > maximumCharactersPerChunk {
                if !current.isEmpty { chunks.append(current) }
                current = String(sentence.prefix(maximumCharactersPerChunk))
            } else {
                current = candidate
            }
            if chunks.count >= maximumChunks { break }
        }
        if !current.isEmpty, chunks.count < maximumChunks { chunks.append(current) }
        return chunks
    }
}
