import Foundation

/// The names and terms in your own notes, for the recognizer to expect.
///
/// A recognizer guesses an unfamiliar name from its sound — "Al Qersh" turns
/// into something English-looking, "PCH" into "PC age". Handing it the names
/// you actually write about (`SFSpeechRecognitionRequest.contextualStrings`)
/// makes it far more likely to spell them the way you do. Only names and
/// acronyms are taken — words capitalised mid-sentence, and short all-capital
/// words — ranked by how often you use them.
enum SpeechVocabulary {
    /// Apple suggests keeping the list short; past about a hundred it stops helping.
    static let limit = 100

    private static let ordinary: Set<String> = [
        "the", "this", "that", "these", "those", "there", "then", "they", "their", "what", "when",
        "where", "which", "who", "why", "how", "and", "but", "for", "with", "from", "please",
        "okay", "yes", "yeah", "also", "just", "can", "could", "will", "would", "should",
        "have", "has", "had", "are", "was", "were", "you", "your", "our", "we", "she", "his",
        "her", "its", "not", "all", "any", "some", "one", "two", "today", "tomorrow", "yesterday",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "remind", "note", "voice", "scan", "photo", "send", "call", "meeting", "need", "after", "before"
    ]

    static func terms(in texts: [String], limit: Int = limit) -> [String] {
        // Every word starting a sentence is capitalised, so one there counts
        // only if it is also capitalised mid-sentence somewhere — a name.
        var midSentence: Set<String> = []
        var occurrences: [(term: String, atStart: Bool)] = []
        for text in texts {
            for (term, atStart) in words(in: text) {
                guard isNameLike(term), !ordinary.contains(term.lowercased()) else { continue }
                occurrences.append((term: term, atStart: atStart))
                if !atStart { midSentence.insert(term) }
            }
        }

        var counts: [String: Int] = [:]
        for occurrence in occurrences where !occurrence.atStart || midSentence.contains(occurrence.term) {
            counts[occurrence.term, default: 0] += 1
        }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    /// The words of a text, each with whether it opens a sentence.
    private static func words(in text: String) -> [(String, Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        var atStart = true
        var wordStartsSentence = true
        for character in text {
            if character.isLetter || character.isNumber || character == "-" {
                if current.isEmpty { wordStartsSentence = atStart }
                current.append(character)
                continue
            }
            if !current.isEmpty {
                result.append((current, wordStartsSentence))
                current = ""
                atStart = false
            }
            if ".!?\n".contains(character) { atStart = true }
        }
        if !current.isEmpty { result.append((current, wordStartsSentence)) }
        return result
    }

    /// "Suresh", "Haffaf", "ITC", "PCH" — not "the", not "A", not "2026".
    static func isNameLike(_ word: String) -> Bool {
        guard word.count >= 2, word.count <= 24, let first = word.first, first.isUppercase else { return false }
        let letters = word.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        // An acronym: short and all capitals.
        if letters.allSatisfy(\.isUppercase) { return word.count <= 6 }
        // A name: capital then lowercase.
        return word.count >= 3 && word.dropFirst().contains(where: \.isLowercase)
    }
}
