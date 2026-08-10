import Foundation

/// A short subject line for something that arrived without one.
///
/// Transcribed speech has no title in it. Taking the first seventy characters
/// yields *"I would like to know when I we are going to leave from home and we…"*
/// — the throat-clearing at the start of a recording, which is reliably the least
/// informative part of it. A subject is supposed to say what the thing is about.
///
/// Extractive, like everything else here: a headline is words that were actually
/// said, with the conversational scaffolding taken off the front. Nothing is
/// generated, so a headline can't describe a recording as being about something
/// nobody mentioned.
enum Headline {
    static let maximumLength = 64
    /// Below this a headline is too vague to be worth preferring over the
    /// alternatives further down the ladder.
    static let minimumLength = 18

    /// Derives a subject line, in order of preference:
    ///
    /// 1. **A commitment**, cleaned up — "Close the excess tower material
    ///    approval from PCH". When somebody agreed to do something, that is what
    ///    the recording is about, and it's also what a pending task needs to say.
    /// 2. **The recurring subjects** — "Home, gold, place". Reads as a subject
    ///    rather than a sentence, which is exactly right for a rambling
    ///    conversation that never states its own point.
    /// 3. **The most informative sentence**, cleaned up.
    /// 4. `fallback`.
    static func from(_ text: String, fallback: String = "") -> String {
        let sentences = usableSentences(in: text)
        let commitment = sentences.first(where: DiscussionSummarizer.isActionable)
        let best = mostInformative(of: sentences, in: text)

        // A whole thought, kept whole, beats a list of nouns. Topics are the
        // answer for a conversation that never states its own point — not for a
        // sentence that states it perfectly well.
        for candidate in [commitment, best].compactMap({ $0 }) {
            if let line = condense(candidate), survivesCondensing(candidate, as: line) {
                return line
            }
        }

        let topics = DiscussionSummarizer.topics(in: text, limit: 3)
        if topics.count >= 2 {
            return topics.joined(separator: ", ").capitalizedFirst
        }

        // Nothing fits and there are no topics: a truncated sentence still beats
        // no subject at all.
        for candidate in [commitment, best].compactMap({ $0 }) {
            if let line = condense(candidate) { return line }
        }
        return fallback
    }

    /// Whether enough of the sentence survived to still make the point.
    ///
    /// A 76-character line clipped to 62 has lost a tail; a 400-character ramble
    /// clipped to 62 has lost the point, and for that a list of subjects is the
    /// more honest heading.
    private static let minimumRetainedFraction = 0.6

    private static func survivesCondensing(_ sentence: String, as headline: String) -> Bool {
        guard sentence.count > 0 else { return false }
        guard headline.hasSuffix("…") else { return true }
        return Double(headline.count) / Double(sentence.count) >= minimumRetainedFraction
    }

    // MARK: - Choosing a sentence

    private static func usableSentences(in text: String) -> [String] {
        Tokenizer.sentences(in: text).filter { $0.split(separator: " ").count >= 4 }
    }

    /// The sentence carrying the most of the text's own recurring vocabulary,
    /// normalized by length so a long ramble doesn't win on volume alone.
    private static func mostInformative(of sentences: [String], in text: String) -> String? {
        guard !sentences.isEmpty else { return nil }
        guard sentences.count > 1 else { return sentences[0] }

        var frequency: [String: Int] = [:]
        for sentence in sentences {
            for term in Set(Tokenizer.tokens(in: sentence)) {
                frequency[term, default: 0] += 1
            }
        }
        guard let peak = frequency.values.max(), peak > 0 else { return sentences[0] }

        return sentences.max { lhs, rhs in
            score(lhs, frequency: frequency, scale: Double(peak))
                < score(rhs, frequency: frequency, scale: Double(peak))
        }
    }

    private static func score(_ sentence: String, frequency: [String: Int], scale: Double) -> Double {
        let terms = Set(Tokenizer.tokens(in: sentence))
        guard !terms.isEmpty else { return 0 }
        let weight = terms.reduce(0.0) { $0 + Double(frequency[$1] ?? 0) / scale }
        return weight / Double(terms.count).squareRoot()
    }

    // MARK: - Cleaning one up

    /// Words that open a spoken sentence without contributing to it.
    ///
    /// Stripped from the front only, and only until the first word that carries
    /// meaning: "okay" in the middle of a sentence may well be the point, and
    /// "have to" is filler at the start of a commitment but not elsewhere.
    private static let openers: Set<String> = [
        "a", "actually", "also", "am", "an", "and", "are", "as", "basically",
        "but", "even", "for", "had", "has", "have", "i", "is", "just", "know",
        "let", "lets", "like", "mean", "need", "needed", "no", "now", "ok",
        "okay", "please", "really", "right", "said", "say", "should", "so",
        "tell", "the", "then", "think", "thought", "to", "told", "us", "want",
        "wanted", "was", "we", "well", "were", "will", "would", "yeah", "yes",
        "you"
    ]

    /// At most this many leading words are dropped. Past that, stripping stops
    /// being tidying and starts changing the meaning.
    private static let maximumStrippedWords = 5

    static func condense(_ sentence: String) -> String? {
        var words = sentence
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        var stripped = 0
        while stripped < maximumStrippedWords, words.count > 3 {
            let bare = words[0]
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                .lowercased()
            guard openers.contains(bare) else { break }
            words.removeFirst()
            stripped += 1
        }

        let joined = words.joined(separator: " ")
        let clipped = clip(joined)
        guard clipped.count >= minimumLength else { return nil }
        return clipped.capitalizedFirst
    }

    /// Prefers to end at a comma, which in speech usually marks the end of the
    /// first complete thought — "Close the excess tower material approval from
    /// PCH" rather than that plus half of whatever came next.
    private static func clip(_ text: String) -> String {
        if let comma = text.firstIndex(of: ","),
           text.distance(from: text.startIndex, to: comma) >= minimumLength,
           text.distance(from: text.startIndex, to: comma) <= maximumLength {
            return String(text[text.startIndex..<comma])
        }
        guard text.count > maximumLength else { return trimmedTail(text) }

        let cut = text.prefix(maximumLength)
        if let lastSpace = cut.lastIndex(of: " ") {
            return trimmedTail(String(cut[cut.startIndex..<lastSpace])) + "…"
        }
        return trimmedTail(String(cut)) + "…"
    }

    /// Drops trailing punctuation so a headline doesn't end in a stray comma.
    private static func trimmedTail(_ text: String) -> String {
        var value = text
        while let last = value.last, last.isPunctuation || last.isWhitespace {
            value.removeLast()
        }
        return value
    }
}
