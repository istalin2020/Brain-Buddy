import Foundation

/// Turns free text into comparable search terms.
///
/// Deliberately dependency-free and deterministic so the ranking layer can be
/// unit tested without a device, a model container, or a network.
enum Tokenizer {
    /// Very small English stop list. Kept short on purpose: dropping too much
    /// hurts recall on short notes, which is most of what a second brain holds.
    static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from",
        "had", "has", "have", "he", "her", "him", "his", "i", "in", "is", "it",
        "its", "me", "my", "of", "on", "or", "our", "she", "so", "than", "that",
        "the", "their", "them", "then", "there", "these", "they", "this", "to",
        "was", "we", "were", "what", "when", "where", "which", "who", "will",
        "with", "you", "your"
    ]

    /// Words that carry no meaning in a spoken query but wreck lexical scoring:
    /// "what did I say about the dentist" should search for "dentist".
    static let questionFillers: Set<String> = [
        "about", "again", "anything", "ask", "buddy", "brain", "can", "did",
        "do", "does", "everything", "find", "get", "hey", "how", "know", "look",
        "me", "mine", "note", "notes", "please", "recall", "remember", "remind",
        "said", "save", "saved", "say", "search", "show", "some", "something",
        "tell", "thing", "things", "up", "wanna", "want", "was", "whats", "why"
    ]

    /// Splits on anything that is not a letter or a digit, lowercases, strips
    /// diacritics, and drops stopwords and one-character noise.
    static func tokens(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let separators = CharacterSet.alphanumerics.inverted
        return text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: separators)
            .compactMap { normalize($0) }
    }

    /// Query tokens additionally drop conversational filler so that voice
    /// questions score like the keywords a person would have typed.
    static func queryTokens(in text: String) -> [String] {
        let all = tokens(in: text)
        let meaningful = all.filter { !questionFillers.contains($0) }
        // If the filler list ate the whole question, fall back to the raw tokens
        // rather than searching for nothing.
        return meaningful.isEmpty ? all : meaningful
    }

    /// Normalizes one raw word, returning `nil` when it should not be indexed.
    static func normalize(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        guard lowered.count > 1 else { return nil }
        guard !stopwords.contains(lowered) else { return nil }
        return stem(lowered)
    }

    /// A deliberately conservative suffix trim. Full stemming (Porter et al.)
    /// costs recall precision on proper nouns, which notes are full of.
    static func stem(_ word: String) -> String {
        if word.count > 4, word.hasSuffix("ies") {
            return String(word.dropLast(3)) + "y"
        }
        if word.count > 4, word.hasSuffix("es"), !word.hasSuffix("ses") {
            return String(word.dropLast(2))
        }
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us") {
            return String(word.dropLast())
        }
        if word.count > 5, word.hasSuffix("ing") {
            return String(word.dropLast(3))
        }
        if word.count > 4, word.hasSuffix("ed"), !word.hasSuffix("eed") {
            return String(word.dropLast(2))
        }
        return word
    }

    /// Splits text into sentences for snippet extraction and embedding chunks.
    static func sentences(in text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
