import Foundation

/// The minimum a composed answer needs to know about a result. Kept separate
/// from `SearchHit` so answer phrasing is testable without SwiftData.
struct AnswerSource {
    let identifier: UUID
    let title: String
    /// The one line that answers the question.
    let snippet: String
    /// The lines that bear on it, in reading order — see
    /// `SearchEngine.relevantLines`. Empty means no line in this document
    /// carries a word from the question.
    let lines: [String]
    let createdAt: Date
    let kindTitle: String
    let score: Double

    init(
        identifier: UUID = UUID(),
        title: String,
        snippet: String,
        lines: [String] = [],
        createdAt: Date,
        kindTitle: String,
        score: Double
    ) {
        self.identifier = identifier
        self.title = title
        self.snippet = snippet
        self.lines = lines
        self.createdAt = createdAt
        self.kindTitle = kindTitle
        self.score = score
    }
}

/// Turns ranked results into a reply a person can read — or hear.
///
/// It reads like something talking to you, and every sentence of substance in
/// it is **quoted**. That is not a limitation dressed up as a feature: an
/// assistant that paraphrases your notes can tell you the invoice was 54,000
/// when the note says 60,000, and you would have no way of knowing. So the
/// voice is generated — the "here's what I have", the "worth noting" — and the
/// facts are your own words, lifted whole, with the source named under each so
/// you can open it and check.
///
/// **What it refuses to say is as important as what it says.** Three rules,
/// each one written against a row that actually appeared on screen:
///
/// - **Nothing that doesn't bear on the question.** Ranking always returns
///   something, so asking for a purchase list surfaced a meeting invitation
///   and a voice memo about a phone balance. A result has to score within
///   reach of the best one *and* have something to contribute before it is
///   presented as part of an answer.
/// - **Never a line picked at random.** When no line of a document carries a
///   word from the question, the answer used to fall back to that document's
///   snippet — which is how a question about shopping was answered with
///   "Because I have only six hours balance". A document with nothing to say
///   about the question now says nothing.
/// - **Never the same sentence twice.** A note called "Purchase a black belt"
///   whose only line is "Purchase a black belt" is one fact, printed once.
///
/// Entirely offline, as the rest of the app is.
enum AnswerComposer {
    /// Something the reply was built from, for the row under it that opens the
    /// original.
    struct Reference: Identifiable, Equatable {
        let id: UUID
        let title: String
        let kindTitle: String
        let when: String
    }

    struct Answer: Equatable {
        let spoken: String
        /// Inline Markdown: bold source names, bullet lines.
        let written: String
        let references: [Reference]
        let hasResults: Bool
    }

    /// How many lines of one source the reply walks through. Past this it is
    /// reading the document to you, and the row under the reply does that
    /// better.
    static let linesPerSource = 4

    /// How many details are called out at the end.
    static let maximumDetails = 6

    /// One source and what it has to say about the question.
    private struct Passage {
        let source: AnswerSource
        /// Already cleaned, de-duplicated, and free of anything that merely
        /// restates the source's own name. May be empty, when the name itself
        /// is the whole answer.
        let lines: [String]
    }

    static func compose(
        query: String,
        sources: [AnswerSource],
        totalMatches: Int? = nil,
        now: Date = Date()
    ) -> Answer {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let topic = subject(of: cleanQuery)
        let terms = Set(Tokenizer.queryTokens(in: cleanQuery))
        let passages = self.passages(in: sources, terms: terms)

        guard !passages.isEmpty else {
            let miss = cleanQuery.isEmpty
                ? "Ask me anything you have saved."
                : "I couldn't find anything about \(topic) in your brain yet. Try other words for it, or capture it first and ask again."
            return Answer(spoken: miss, written: miss, references: [], hasResults: false)
        }

        var written: [String] = []
        var spoken: [String] = []

        // The opening: what was found, and how much of it.
        let count = passages.count
        if count == 1, let only = passages.first {
            let lead = "Here's what I have on \(topic). It's in one \(only.source.kindTitle.lowercased()), saved \(relativeDescription(for: only.source.createdAt, now: now))."
            written.append(lead)
            spoken.append(lead)
        } else {
            let lead = "Here's what I have on \(topic). \(count) things in your brain mention it:"
            written.append(lead)
            spoken.append("Here's what I have on \(topic). \(count) things in your brain mention it.")
        }

        // One passage per source, every relevant line quoted, nothing else.
        for passage in passages {
            let source = passage.source
            let when = relativeDescription(for: source.createdAt, now: now)
            let heading = "**\(source.title.trimmingCharacters(in: .whitespacesAndNewlines))** · \(source.kindTitle), \(when)"
            written.append(([heading] + passage.lines.map { "• \($0)" }).joined(separator: "\n"))

            // Spoken: the name already carries the point when there is nothing
            // under it, so saying "from your note X: " and then stopping would
            // trail off mid-sentence.
            if passage.lines.isEmpty {
                spoken.append("From your \(source.kindTitle.lowercased()) \(when): \(source.title).")
            } else {
                let quoted = passage.lines.prefix(2).joined(separator: ". ")
                spoken.append("From your \(source.kindTitle.lowercased()) \(source.title), saved \(when): \(quoted).")
            }
        }

        // The details somebody would otherwise have to fish out themselves,
        // taken only from what was actually quoted above.
        let quotedLines = passages.flatMap { [$0.source.title] + $0.lines }
        let details = self.details(in: quotedLines, query: cleanQuery)
        if !details.isEmpty {
            written.append("**Worth noting:** " + details.joined(separator: " · "))
            spoken.append("Worth noting: " + details.joined(separator: ", ") + ".")
        }

        // The close: where to go next. `totalMatches` is how many are listed
        // under the reply, so "more" means more rows down there — not a count
        // of everything the ranker touched, most of which was dropped for
        // being beside the point.
        let extra = max(0, (totalMatches ?? count) - count)
        var closing = "Tap a source below to open the whole thing."
        if extra > 0 {
            closing = (extra == 1 ? "1 more match is listed below" : "\(extra) more matches are listed below")
                + ". Tap any source to open the whole thing."
            spoken.append(extra == 1 ? "One more match is listed below." : "\(extra) more matches are listed below.")
        }
        written.append(closing)

        let references = passages.map {
            Reference(
                id: $0.source.identifier,
                title: $0.source.title,
                kindTitle: $0.source.kindTitle,
                when: relativeDescription(for: $0.source.createdAt, now: now)
            )
        }

        return Answer(
            spoken: spoken.joined(separator: " "),
            written: written.joined(separator: "\n\n"),
            references: references,
            hasResults: true
        )
    }

    // MARK: - What earns a place in the answer

    /// How far below the best match a result can score and still be worth
    /// presenting as part of an answer.
    static let relevanceFloor = 0.45

    /// The sources that actually bear on the question, each with what it has
    /// to say.
    ///
    /// A source earns its place one of two ways: a line of it carries a word
    /// from the question, or its **own name** does. The second matters more
    /// than it sounds. A note called "Dentist appointment" whose body reads
    /// "Tuesday at four with Dr Alvarez" answers *"what did I save about the
    /// dentist"* perfectly, and not one word of that body is "dentist".
    private static func passages(in sources: [AnswerSource], terms: Set<String>) -> [Passage] {
        guard let best = sources.map(\.score).max() else { return [] }
        // A floor of zero would divide every result by nothing; when no score
        // was supplied, keep them all and let the word tests decide.
        let floor = best > 0 ? best * relevanceFloor : -.infinity

        var kept: [Passage] = []
        for source in sources where source.score >= floor {
            let titleTerms = Set(Tokenizer.tokens(in: source.title))
            let namesTheSubject = !titleTerms.isDisjoint(with: terms)

            let lines = usableLines(of: source, terms: terms, titleTerms: titleTerms, namesTheSubject: namesTheSubject)
            guard !lines.isEmpty || namesTheSubject else { continue }
            kept.append(Passage(source: source, lines: lines))
        }
        return kept
    }

    /// What one source contributes, after everything not worth reading is
    /// dropped.
    private static func usableLines(
        of source: AnswerSource,
        terms: Set<String>,
        titleTerms: Set<String>,
        namesTheSubject: Bool
    ) -> [String] {
        // `SearchEngine.relevantLines` has already required a word from the
        // question in every line it returns. The snippet has not, so it is
        // only trusted for a document whose name is already on the subject.
        let candidates = source.lines.isEmpty
            ? (namesTheSubject ? [source.snippet] : [])
            : source.lines

        var kept: [String] = []
        // The name counts as already said, so a line repeating it is a
        // repetition like any other.
        var spoken: [Set<String>] = [titleTerms]

        for candidate in candidates {
            let line = tighten(candidate)
            guard !line.isEmpty else { continue }
            let lineTerms = Set(Tokenizer.tokens(in: line))
            guard !lineTerms.isEmpty else { continue }
            guard !spoken.contains(where: { DiscussionSummarizer.restates(lineTerms, $0) }) else { continue }

            kept.append(line)
            spoken.append(lineTerms)
            if kept.count >= linesPerSource { break }
        }
        return kept
    }

    // MARK: - Details

    /// The concrete things in the quoted lines: amounts, dates, times, phone
    /// numbers, and a number sitting next to a word you asked about.
    ///
    /// These are *found*, never computed — an amount is the amount as written,
    /// so it can't be wrong in a way the source isn't.
    static func details(in lines: [String], query: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()

        func note(_ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = value.lowercased()
            guard !value.isEmpty, seen.insert(key).inserted, found.count < maximumDetails else { return }
            found.append(value)
        }

        let queryTerms = Set(Tokenizer.queryTokens(in: query))

        for line in lines {
            for pattern in amountPatterns {
                for match in matches(of: pattern, in: line) { note(match) }
            }

            if let detector {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                for result in detector.matches(in: line, options: [], range: range) {
                    guard let matched = Range(result.range, in: line) else { continue }
                    let phrase = String(line[matched])
                    switch result.resultType {
                    case .date:
                        // A bare clock time or a number that only looks like a
                        // time is not a detail; a named day is.
                        if BriefBuilder.namesADay(phrase) || BriefGrouping.namesAWhen(phrase) { note(phrase) }
                    case .phoneNumber:
                        note(phrase)
                    default:
                        break
                    }
                }
            }

            // "TSH 5.46", "Tower 42": a word you asked about, then its number.
            for match in matches(of: labelledNumberPattern, in: line) {
                let label = match
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .first { !$0.isEmpty }
                    .flatMap(Tokenizer.normalize) ?? ""
                if queryTerms.contains(label) { note(match) }
            }
        }
        return found
    }

    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.date.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
    )

    private static let amountPatterns: [String] = [
        // 60,000 Omani rial · 1,250 OMR · 45 dollars · 12%
        #"\d[\d,]*(?:\.\d+)?\s?(?:omani\s+)?(?:rials?|riyals?|omr|ro|usd|aed|inr|eur|gbp|dollars?|rupees?|dirhams?|pounds?|euros?|%)\b"#,
        // OMR 1,250 · USD 300 · Rs. 4,000
        #"\b(?:omr|ro|usd|aed|inr|eur|gbp|rs\.?)\s?\d[\d,]*(?:\.\d+)?"#,
        // $300 · €45 · ₹4,000 · £12.50
        #"[$€£₹]\s?\d[\d,]*(?:\.\d+)?"#
    ]

    private static let labelledNumberPattern = #"\b[A-Za-z][A-Za-z]{1,15}\s?[:=\-]?\s?\d[\d,]*(?:\.\d+)?\b"#

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, options: [], range: range).compactMap { result in
            Range(result.range, in: text).map { String(text[$0]) }
        }
    }

    // MARK: - What the question was about

    /// At most this many words name the subject. Past that it stops being a
    /// subject and starts being the question again.
    static let subjectWordLimit = 4

    /// Names what the question was about, in the asker's own spelling.
    ///
    /// Two things make this harder than taking the search terms. Search terms
    /// are **stemmed and repeated** — *"water all all purchase list"* was a
    /// real heading — so this keeps the original words and drops a word it has
    /// already used. And dictation **restarts**: *"Water, all the things are
    /// What all the things are there on my purchase list?"* is one false start
    /// followed by the actual question. People restart forwards, never
    /// backwards, so everything before the last question word is discarded.
    static func subject(of query: String) -> String {
        var words: [String] = []
        var seen = Set<String>()

        for raw in lastQuestion(in: query).components(separatedBy: CharacterSet.alphanumerics.inverted) {
            guard !raw.isEmpty else { continue }
            // `normalize` drops stopwords and one-character noise for us.
            guard let key = Tokenizer.normalize(raw) else { continue }
            guard !Tokenizer.questionFillers.contains(key) else { continue }
            guard !quantifiers.contains(key) else { continue }
            guard seen.insert(key).inserted else { continue }

            words.append(raw.lowercased())
            if words.count >= subjectWordLimit { break }
        }
        return words.isEmpty ? "that" : words.joined(separator: " ")
    }

    /// Words that say *how much* you want rather than what about, which is the
    /// same reason "latest" and "recent" are filtered out of a search.
    private static let quantifiers: Set<String> = [
        "all", "any", "both", "each", "every", "everything", "few", "many",
        "more", "most", "much", "several", "some", "total"
    ]

    private static let questionWords: Set<String> = [
        "what", "whats", "which", "who", "whom", "whose", "when", "where", "how", "why"
    ]

    /// The question as finally asked, with any false start before it dropped.
    private static func lastQuestion(in query: String) -> String {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        // Too short to contain a restart worth finding.
        guard words.count > 3 else { return query }

        let bare = words.map { $0.trimmingCharacters(in: CharacterSet.letters.inverted).lowercased() }
        guard let start = bare.lastIndex(where: { questionWords.contains($0) }), start > 0 else {
            return query
        }
        // Only when something is actually left to ask about.
        let remainder = words[start...]
        return remainder.count >= 2 ? remainder.joined(separator: " ") : query
    }

    // MARK: - Helpers

    /// Collapses whitespace and caps length so a spoken answer stays listenable.
    static func tighten(_ text: String, limit: Int = 320) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let cut = collapsed.prefix(limit)
        if let lastSpace = cut.lastIndex(of: " ") {
            return String(cut[cut.startIndex..<lastSpace]) + "…"
        }
        return String(cut) + "…"
    }

    /// Phrased relative to the supplied `now` rather than the wall clock, so the
    /// wording is deterministic and testable.
    static func relativeDescription(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }

        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<0:
            return "recently"
        case 0...6:
            return "on \(date.formatted(.dateTime.weekday(.wide)))"
        case 7...30:
            let weeks = max(1, days / 7)
            return weeks == 1 ? "last week" : "\(weeks) weeks ago"
        case 31...364:
            let months = max(1, days / 30)
            return months == 1 ? "last month" : "\(months) months ago"
        default:
            return "in \(date.formatted(.dateTime.year()))"
        }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
