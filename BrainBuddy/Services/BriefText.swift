import Foundation

/// Makes a line of the brief read like something written down rather than
/// something scraped out of a text field.
///
/// The brief quotes you verbatim, which is the right call — a brief that
/// paraphrases can put words in your mouth and then ask you to tick them off.
/// But *verbatim* and *unpresented* are different things. A typed capture
/// carries the debris of being typed on a phone: doubled full stops, a space
/// before a comma, a sentence that trails off on "with". None of that is
/// meaning, and all of it makes a brief look unfinished.
///
/// So this tidies presentation and only presentation: no words are added, none
/// are reordered, and nothing is dropped except punctuation noise and a
/// dangling connective at the very end.
enum BriefText {
    /// Function words a line should never end on. Left mid-sentence they're
    /// load-bearing; left dangling at the end of a heading they're just a
    /// sentence that stopped.
    static let danglingWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "because", "been", "but",
        "by", "can", "for", "from", "in", "into", "is", "of", "on", "or", "so",
        "that", "the", "their", "them", "then", "this", "to", "was", "were",
        "will", "with", "would"
    ]

    /// Words that fill a sentence without saying anything, for the substance
    /// test. Not stripped from text — only ignored when deciding whether a line
    /// says anything at all.
    static let fillerWords: Set<String> = [
        "actually", "also", "anyway", "basically", "just", "kind", "like",
        "mostly", "really", "sort", "stuff", "thing", "things", "well", "yeah"
    ]

    /// Words that name a point in time. A line made only of these and digits is
    /// a timestamp, not a thought.
    static let timeWords: Set<String> = [
        "am", "pm", "clock", "hour", "hours", "minute", "minutes", "morning",
        "afternoon", "evening", "night", "today", "tonight", "tomorrow",
        "yesterday", "monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday", "january", "february", "march", "april", "may",
        "june", "july", "august", "september", "october", "november",
        "december", "week", "weeks", "month", "months", "year"
    ]

    /// A line must carry at least this many words that are none of the above to
    /// be worth a row of somebody's morning.
    static let minimumSubstantiveWords = 2

    // MARK: - Cleaning

    static func clean(_ raw: String) -> String {
        var text = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // "record ..they" — a typed pause. One ellipsis, spaced properly, says
        // the same thing and looks deliberate.
        text = text.replacingOccurrences(
            of: #"\s*\.{2,}\s*"#,
            with: "… ",
            options: .regularExpression
        )
        // Repeated terminators: "what?!?!" → "what?"
        text = text.replacingOccurrences(
            of: #"([!?])[!?]+"#,
            with: "$1",
            options: .regularExpression
        )
        // A space before punctuation is always a typo.
        text = text.replacingOccurrences(
            of: #"\s+([,;:.!?])"#,
            with: "$1",
            options: .regularExpression
        )
        // Collapse any whitespace the substitutions doubled up.
        text = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        text = trimEdges(text)
        return capitalizedFirstWord(text)
    }

    /// Drops punctuation noise from both ends, and a dangling connective from
    /// the end — but never so much that nothing is left.
    static func trimEdges(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        while let first = value.first, first.isPunctuation || first.isWhitespace {
            value.removeFirst()
        }
        while let last = value.last, last == "," || last == ";" || last == ":" || last == "-" || last.isWhitespace {
            value.removeLast()
        }

        var words = value.split(separator: " ").map(String.init)
        while words.count > minimumSubstantiveWords + 1,
              let last = words.last,
              !endsSentence(last),
              danglingWords.contains(bare(last)) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    /// Capitalizes the first letter and leaves every other one alone — an
    /// acronym the writer typed stays an acronym.
    static func capitalizedFirstWord(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    // MARK: - Substance

    /// Whether a line says anything.
    ///
    /// Written for the row that made this necessary: *"29th September mostly
    /// 11:50 AM"* appeared under **Key points**, which is a date, a filler word
    /// and a clock reading — true, verbatim, and of no use to anybody reading
    /// their morning brief. A line has to carry words that aren't digits, dates
    /// or filler before it earns a row.
    static func carriesSubstance(_ line: String) -> Bool {
        let words = line
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        var substantive = 0
        for word in words {
            let lowered = word.lowercased()
            if lowered.rangeOfCharacter(from: .decimalDigits) != nil { continue }
            if timeWords.contains(lowered) || fillerWords.contains(lowered) { continue }
            guard Tokenizer.normalize(lowered) != nil else { continue }
            substantive += 1
            if substantive >= minimumSubstantiveWords { return true }
        }
        return false
    }

    /// A word carrying a terminator ends the sentence deliberately — *"are we
    /// still on?"* is a whole question, and trimming "on" off it would leave a
    /// line that reads as broken.
    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return last == "." || last == "!" || last == "?" || last == "…"
    }

    private static func bare(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased()
    }
}
