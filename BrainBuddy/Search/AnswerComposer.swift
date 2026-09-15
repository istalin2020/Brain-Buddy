import Foundation

/// The minimum a composed answer needs to know about a result. Kept separate
/// from `SearchHit` so answer phrasing is testable without SwiftData.
struct AnswerSource {
    let identifier: UUID
    let title: String
    /// The one line that answers the question.
    let snippet: String
    /// The lines that bear on it, in reading order — see
    /// `SearchEngine.relevantLines`. Empty means "just the snippet".
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
/// voice is generated — the "here's what I have", the "going through them",
/// the "worth noting" — and the facts are your own words, lifted whole, with
/// the source named under each so you can open it and check.
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

    static func compose(
        query: String,
        sources: [AnswerSource],
        totalMatches: Int? = nil,
        now: Date = Date()
    ) -> Answer {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let topic = subject(of: cleanQuery)

        guard !sources.isEmpty else {
            let miss = cleanQuery.isEmpty
                ? "Ask me anything you have saved."
                : "I couldn't find anything about \(topic) in your brain yet. Try other words for it, or capture it first and ask again."
            return Answer(spoken: miss, written: miss, references: [], hasResults: false)
        }

        var written: [String] = []
        var spoken: [String] = []

        // The opening: what was found, and how much of it.
        let count = sources.count
        let extra = max(0, (totalMatches ?? count) - count)
        if count == 1, let only = sources.first {
            let lead = "Here's what I have on \(topic). It comes from one \(only.kindTitle.lowercased()), saved \(relativeDescription(for: only.createdAt, now: now))."
            written.append(lead)
            spoken.append(lead)
        } else {
            let lead = "Here's what I have on \(topic) — \(count) things in your brain mention it. Going through them:"
            written.append(lead)
            spoken.append("Here's what I have on \(topic). \(count) things in your brain mention it.")
        }

        // One passage per source, every relevant line quoted.
        for source in sources {
            let when = relativeDescription(for: source.createdAt, now: now)
            let lines = passageLines(for: source)
            let heading = "**\(source.title.trimmingCharacters(in: .whitespacesAndNewlines))** · \(source.kindTitle), \(when)"
            written.append(([heading] + lines.map { "• \($0)" }).joined(separator: "\n"))

            let quoted = lines.prefix(2).joined(separator: ". ")
            spoken.append("From your \(source.kindTitle.lowercased()) \(source.title), saved \(when): \(quoted).")
        }

        // The details somebody would otherwise have to fish out themselves.
        let details = self.details(in: sources.flatMap(passageLines(for:)), query: cleanQuery)
        if !details.isEmpty {
            written.append("**Worth noting:** " + details.joined(separator: " · "))
            spoken.append("Worth noting: " + details.joined(separator: ", ") + ".")
        }

        // The close: where to go next.
        var closing = "Tap a source below to open the whole thing."
        if extra > 0 {
            closing = (extra == 1 ? "1 more note mentions it too" : "\(extra) more notes mention it too")
                + " — everything is listed below. Tap any source to open the whole thing."
            spoken.append(extra == 1 ? "One more note mentions it as well." : "\(extra) more notes mention it as well.")
        }
        written.append(closing)

        let references = sources.map {
            Reference(
                id: $0.identifier,
                title: $0.title,
                kindTitle: $0.kindTitle,
                when: relativeDescription(for: $0.createdAt, now: now)
            )
        }

        return Answer(
            spoken: spoken.joined(separator: " "),
            written: written.joined(separator: "\n\n"),
            references: references,
            hasResults: true
        )
    }

    /// What a passage quotes: the relevant lines when there are any, the
    /// snippet otherwise, and the title when there's nothing else — a photo
    /// with no words on it still has a name.
    private static func passageLines(for source: AnswerSource) -> [String] {
        let lines = source.lines
            .map { tighten($0) }
            .filter { !$0.isEmpty }
        if !lines.isEmpty { return Array(lines.prefix(linesPerSource)) }
        let fallback = tighten(source.snippet.isEmpty ? source.title : source.snippet)
        return fallback.isEmpty ? [] : [fallback]
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

    // MARK: - Helpers

    /// Strips filler from a question so the reply can name what it was about.
    static func subject(of query: String) -> String {
        let terms = Tokenizer.queryTokens(in: query)
        guard !terms.isEmpty else { return "that" }
        return terms.prefix(6).joined(separator: " ")
    }

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
