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
    ///
    /// "latest" and friends are here because they qualify *which* result you
    /// want, not what it's about — ranking already applies a recency boost, so
    /// leaving them in only dilutes the terms that actually discriminate.
    static let questionFillers: Set<String> = [
        "about", "again", "anything", "ask", "buddy", "brain", "can", "did",
        "do", "does", "everything", "find", "get", "hey", "how", "know", "latest",
        "look", "me", "mine", "most", "newest", "note", "notes", "please",
        "recall", "recent", "remember", "remind", "said", "save", "saved", "say",
        "search", "show", "some", "something", "tell", "thing", "things", "up",
        "wanna", "want", "was", "whats", "why"
    ]

    /// Splits on anything that is not a letter or a digit, lowercases, strips
    /// diacritics, and drops stopwords and one-character noise.
    ///
    /// One exception: a period between two digits is a decimal point, not a
    /// separator. `5.46` is a single value — a lab result, a price, a version —
    /// and splitting it yields `5` and `46`, both of which are noise the
    /// one-character and stopword filters were never going to catch.
    static func tokens(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let characters = Array(text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current))

        var results: [String] = []
        var current = ""

        for (index, character) in characters.enumerated() {
            if character.isLetter || character.isNumber {
                current.append(character)
                continue
            }
            if character == ".",
               index > 0, characters[index - 1].isNumber,
               index + 1 < characters.count, characters[index + 1].isNumber {
                current.append(character)
                continue
            }
            if let token = normalize(current) { results.append(token) }
            current = ""
        }
        if let token = normalize(current) { results.append(token) }
        return results
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

    // MARK: - Sentences

    private static let terminators: Set<Character> = [".", "!", "?"]

    /// Words that end in a period without ending a sentence.
    static let abbreviations: Set<String> = [
        "approx", "apt", "attn", "ave", "co", "corp", "dept", "dr", "eg", "est",
        "etc", "fig", "ie", "inc", "jr", "ltd", "mr", "mrs", "ms", "mt", "no",
        "nos", "prof", "ref", "sr", "st", "vs"
    ]

    /// Splits text into sentences for snippets, summaries and brief lines.
    ///
    /// The naive version of this — splitting on every `.!?\n` — is what turned a
    /// lab result of `TSH 5.46` into `TSH 5` on screen, because the decimal point
    /// looked like the end of a sentence. Getting this right matters more than it
    /// sounds: a second brain that quietly drops the digits after the point is
    /// worse than one that finds nothing, because it looks like an answer.
    static func sentences(in text: String) -> [String] {
        sentenceRanges(in: text).compactMap { range in
            let cleaned = trimTerminators(String(text[range]))
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    /// The sentence that `index` falls inside, for callers that found something
    /// by position — a detected date, a regex hit — and need its context.
    static func sentence(containing index: String.Index, in text: String) -> String? {
        guard let range = sentenceRanges(in: text).first(where: { $0.contains(index) }) else { return nil }
        let cleaned = trimTerminators(String(text[range]))
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Sentence boundaries, kept as ranges so position-based callers and text
    /// based ones can't drift apart on where a sentence ends.
    static func sentenceRanges(in text: String) -> [Range<String.Index>] {
        guard !text.isEmpty else { return [] }

        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)

            if character.isNewline || (terminators.contains(character) && endsSentence(character, at: index, in: text)) {
                if start < next { ranges.append(start..<next) }
                start = next
            }
            index = next
        }
        if start < text.endIndex { ranges.append(start..<text.endIndex) }
        return ranges
    }

    /// A terminator only ends a sentence when whitespace or the end of the text
    /// follows it. That single rule keeps `5.46`, `0.270` and `nmc.example.com`
    /// intact, because nothing but another digit or letter follows their dots.
    private static func endsSentence(_ character: Character, at index: String.Index, in text: String) -> Bool {
        let next = text.index(after: index)
        if next < text.endIndex, !text[next].isWhitespace { return false }
        guard character == "." else { return true }
        return !isAbbreviation(endingAt: index, in: text)
    }

    private static func isAbbreviation(endingAt index: String.Index, in text: String) -> Bool {
        var word = ""
        var cursor = index
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            let character = text[cursor]
            guard character.isLetter || character == "." else { break }
            word.insert(character, at: word.startIndex)
        }

        // Inner dots removed so "e.g." reduces to "eg".
        let cleaned = word.replacingOccurrences(of: ".", with: "").lowercased()
        guard !cleaned.isEmpty else { return false }
        // A lone letter before a period is an initial: "J. Stalin Kaspar".
        if cleaned.count == 1 { return true }
        return abbreviations.contains(cleaned)
    }

    /// Terminators are boundaries rather than content, so they're dropped — the
    /// long-standing contract of this function.
    private static func trimTerminators(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = value.last, terminators.contains(last) { value.removeLast() }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
