import Foundation

/// A memory reduced to what a brief needs from it.
///
/// Same trick as `SearchDocument`: keeping the builder off SwiftData is what
/// makes "what ends up in tomorrow's brief" testable without a device.
struct BriefSource {
    let identifier: UUID
    let title: String
    let text: String
    let summary: String
    let createdAt: Date
    let kind: MemoryKind
    let kindTitle: String
    let tags: [String]

    init(
        identifier: UUID,
        title: String,
        text: String,
        summary: String = "",
        createdAt: Date,
        kind: MemoryKind = .note,
        kindTitle: String = "Note",
        tags: [String] = []
    ) {
        self.identifier = identifier
        self.title = title
        self.text = text
        self.summary = summary
        self.createdAt = createdAt
        self.kind = kind
        self.kindTitle = kindTitle
        self.tags = tags
    }
}

/// One proposed line of a brief, before it's persisted as a `BriefEntry`.
struct BriefCandidate: Equatable {
    let kind: BriefEntryKind
    let text: String
    /// Short subject for a long line; empty when the line is its own heading.
    let headline: String
    let detail: String
    let scheduledAt: Date?
    let sourceIdentifier: UUID?
}

/// Builds the morning brief out of what you already captured.
///
/// Three questions, answered from three different places in your own words:
///
/// - **What's on today?** Dates detected anywhere in your notes that land on this
///   day. A note written a month ago saying "review with the bank on the 14th" is
///   exactly what a brief is for, so schedule detection deliberately ignores how
///   long ago something was captured.
/// - **What do I need to do?** Sentences carrying a commitment, from recent
///   captures — the same cue detection the discussion summarizer uses.
/// - **What should I have in mind?** Key points out of discussions you
///   summarized recently.
///
/// Everything is quoted verbatim, for the same reason answers and summaries are:
/// a brief that paraphrases can put words in your mouth and then ask you to tick
/// them off.
enum BriefBuilder {
    /// How far back to look for tasks and discussion points. Schedule items are
    /// exempt — they're pinned to a date, not to when you wrote them down.
    ///
    /// Two months for tasks, because work does not stop being owed after a
    /// fortnight. Anything already in a brief persists independently of this: it
    /// carries forward day to day until it is closed. This window only governs
    /// what gets noticed for the first time.
    static let taskLookBackDays = 60
    static let pointLookBackDays = 7

    /// Tags that make something a task outright, whatever it says.
    static let taskTags: Set<String> = ["todo", "task", "action", "followup", "duty"]

    /// Tags that keep something out of the brief — the escape hatch for a note
    /// you wrote down to remember, not to do.
    static let referenceTags: Set<String> = ["note", "fyi", "reference", "info", "idea"]

    /// A typed note at or under this length is treated as a to-do.
    ///
    /// This is what a quick capture box is *for*. "EOT submission" is not a
    /// sentence with a verb in it and never will be; neither is "Leap meeting,
    /// stringing execution". Requiring them to phrase themselves as commitments
    /// means the brief stays empty while the work sits in the library — and a
    /// wrong guess here costs one swipe to Remove, while a miss costs the thing
    /// you were trying not to forget.
    static let shortNoteLimit = 240

    static let maximumScheduleItems = 8
    static let maximumPoints = 5

    /// Safety bound on how many candidates one build will produce, to keep an
    /// enormous library from turning a rebuild into a long pause.
    ///
    /// Deliberately not a display limit. Capping what is *considered* means the
    /// cap gets spent on lines already in the brief, and whatever you captured
    /// most recently never reaches deduplication — which looks exactly like a
    /// Refresh button that does nothing.
    static let candidateCeiling = 200

    static func build(
        for day: Date,
        from sources: [BriefSource],
        calendar: Calendar = .current
    ) -> [BriefCandidate] {
        let dayStart = calendar.startOfDay(for: day)
        let newestFirst = sources.sorted { $0.createdAt > $1.createdAt }

        let schedule = scheduleItems(on: dayStart, from: newestFirst, calendar: calendar)
        // A dated line is a schedule item, not also a task — one row, in the
        // section where it's actionable.
        var claimed = Set(schedule.map { BriefEntry.dedupeKey(for: $0.text) })

        let tasks = taskItems(
            on: dayStart,
            from: newestFirst,
            calendar: calendar,
            claimed: &claimed
        )
        let points = pointItems(
            on: dayStart,
            from: newestFirst,
            calendar: calendar,
            claimed: &claimed
        )

        return schedule + tasks + points
    }

    // MARK: - Schedule

    /// Sentences whose detected date falls on `dayStart`, earliest first.
    private static func scheduleItems(
        on dayStart: Date,
        from sources: [BriefSource],
        calendar: Calendar
    ) -> [BriefCandidate] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return []
        }

        // Keyed by sentence, because one sentence is one line of the brief even
        // when the detector reports the day and the time as separate matches.
        var bySentence: [String: (date: Date, candidate: BriefCandidate)] = [:]

        for source in sources {
            let body = source.text
            guard !body.isEmpty else { continue }
            let writtenToday = calendar.isDate(source.createdAt, inSameDayAs: dayStart)

            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            let matches = detector.matches(in: body, options: [], range: range)
            guard !matches.isEmpty else { continue }
            // Computed once per note rather than once per match: a long document
            // can hold dozens of dates, and each lookup otherwise rescans it.
            let sentenceRanges = Tokenizer.sentenceRanges(in: body)

            for match in matches {
                guard let date = match.date, calendar.isDate(date, inSameDayAs: dayStart) else { continue }
                guard let matchRange = Range(match.range, in: body) else { continue }

                // A bare clock time is resolved against *now*, so "12:05" written
                // at any point in the past becomes an appointment for today. That
                // only makes sense for something written today — "call at 4" in
                // this morning's note means this afternoon. In anything older, a
                // time with no day attached to it is just a number.
                guard Self.namesADay(String(body[matchRange])) || writtenToday else { continue }

                let sentence = sentenceContaining(matchRange, in: body, ranges: sentenceRanges)
                guard !sentence.isEmpty else { continue }
                let key = BriefEntry.dedupeKey(for: sentence)
                guard !key.isEmpty else { continue }

                // An all-day match resolves to midnight; showing "12:00 AM" beside
                // it would be a worse answer than showing no time at all.
                let isTimed = calendar.component(.hour, from: date) != 0
                    || calendar.component(.minute, from: date) != 0

                let candidate = BriefCandidate(
                    kind: .schedule,
                    text: sentence,
                    headline: headline(for: sentence),
                    detail: detail(for: source, line: sentence, on: dayStart),
                    scheduledAt: isTimed ? date : nil,
                    sourceIdentifier: source.identifier
                )

                guard let existing = bySentence[key] else {
                    bySentence[key] = (date, candidate)
                    continue
                }
                // Prefer whichever match actually pinned down a time; between two
                // equally specific ones, the earlier.
                let existingIsTimed = existing.candidate.scheduledAt != nil
                if (isTimed && !existingIsTimed) || (isTimed == existingIsTimed && date < existing.date) {
                    bySentence[key] = (date, candidate)
                }
            }
        }

        return bySentence.values
            .sorted { lhs, rhs in
                lhs.date == rhs.date ? lhs.candidate.text < rhs.candidate.text : lhs.date < rhs.date
            }
            .prefix(maximumScheduleItems)
            .map(\.candidate)
    }

    // MARK: - Subject lines

    /// A short subject for a line that is too long to scan.
    ///
    /// A brief is read standing up, in a few seconds. A quoted sentence of
    /// eighty-plus words is accurate and useless at that length, so long lines
    /// get a heading and keep the quote underneath. Short lines get nothing —
    /// two near-identical strings stacked on each other is worse than one.
    private static func headline(for line: String) -> String {
        guard line.count > Headline.maximumLength + 8 else { return "" }
        let derived = Headline.from(line, fallback: "")
        guard !derived.isEmpty, derived != line else { return "" }
        return derived
    }

    // MARK: - Where a line came from

    /// The subtitle under a brief line: what it came from, not the line again.
    ///
    /// A note's title is derived from its own first line, so for a one-sentence
    /// capture — which most voice memos and quick notes are — using the title
    /// printed the same sentence twice, once in grey. When the title adds nothing,
    /// name the source and when it was captured instead: *Voice note · yesterday*
    /// tells you something the line doesn't.
    private static func detail(for source: BriefSource, line: String, on day: Date) -> String {
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let when = AnswerComposer.relativeDescription(for: source.createdAt, now: day)

        guard !title.isEmpty, !restates(title, line) else {
            return "\(source.kindTitle) · \(when)"
        }
        return title
    }

    /// Whether a title says the same thing as the line, allowing for the
    /// truncation `suggestedTitle` applies at 70 characters.
    private static func restates(_ title: String, _ line: String) -> Bool {
        let titleKey = BriefEntry.dedupeKey(for: title)
        let lineKey = BriefEntry.dedupeKey(for: line)
        guard !titleKey.isEmpty, !lineKey.isEmpty else { return true }
        return lineKey.hasPrefix(titleKey) || titleKey.hasPrefix(lineKey)
    }

    /// Words that name a day rather than a time of day.
    private static let dayWords: Set<String> = [
        "today", "tonight", "tomorrow", "tmrw", "yesterday",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "mon", "tue", "tues", "wed", "weds", "thu", "thur", "thurs", "fri", "sat", "sun",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"
    ]

    /// Whether a detected match actually names a day, rather than only a clock
    /// time — a weekday, a month, a `29/07/2026`, or a word like "tomorrow".
    ///
    /// Worth being strict about: `NSDataDetector` resolves a bare time against
    /// the present moment, so it will happily report `12:05` in a document
    /// printed last month as an event today. It reads a numeric range like
    /// `2 - 2.54` as two o'clock for the same reason.
    static func namesADay(_ matched: String) -> Bool {
        let lowered = matched.lowercased()
        let words = Set(
            lowered
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
        if !words.isDisjoint(with: dayWords) { return true }
        // 29/07/2026, 2026-08-06, 6.8.26 — two separators, so not a clock time.
        return lowered.range(
            of: #"\d{1,4}[./-]\d{1,2}[./-]\d{2,4}"#,
            options: .regularExpression
        ) != nil
    }

    /// The sentence a detected date sits inside, so the brief line reads as
    /// something you wrote rather than as a bare timestamp.
    ///
    /// Uses `Tokenizer`'s sentence boundaries rather than splitting on
    /// punctuation here, so that "the 5.30 train" survives intact — and so there
    /// is one definition of where a sentence ends.
    private static func sentenceContaining(
        _ range: Range<String.Index>,
        in text: String,
        ranges: [Range<String.Index>]
    ) -> String {
        let sentence = ranges.first { $0.contains(range.lowerBound) }.map { String(text[$0]) } ?? text
        return AnswerComposer.tighten(
            sentence.trimmingCharacters(in: CharacterSet(charactersIn: ".!?").union(.whitespacesAndNewlines)),
            limit: 200
        )
    }

    // MARK: - Tasks

    private static func taskItems(
        on dayStart: Date,
        from sources: [BriefSource],
        calendar: Calendar,
        claimed: inout Set<String>
    ) -> [BriefCandidate] {
        guard let cutoff = calendar.date(byAdding: .day, value: -taskLookBackDays, to: dayStart) else { return [] }
        var candidates: [BriefCandidate] = []

        for source in sources where source.createdAt >= cutoff {
            for sentence in taskSentences(in: source) {
                let line = AnswerComposer.tighten(sentence, limit: 200)
                let key = BriefEntry.dedupeKey(for: line)
                guard !key.isEmpty, claimed.insert(key).inserted else { continue }
                candidates.append(BriefCandidate(
                    kind: .task,
                    text: line,
                    headline: headline(for: line),
                    detail: detail(for: source, line: line, on: dayStart),
                    scheduledAt: nil,
                    sourceIdentifier: source.identifier
                ))
                // Bounded only to stop pathological work on an enormous library.
                // The real limit on how many tasks appear is how many you wrote —
                // and the cap must not be reached before deduplication runs, or
                // slots get spent on lines that are already in the brief and the
                // new one silently never arrives.
                if candidates.count >= candidateCeiling { return candidates }
            }
        }
        return candidates
    }

    /// What in one capture counts as something still to do.
    static func taskSentences(in source: BriefSource) -> [String] {
        // A summary's follow-ups are the distilled commitments; when one exists
        // it beats re-scanning the raw transcript.
        if let followUps = DiscussionSummarizer.parse(source.summary)?.followUps, !followUps.isEmpty {
            return followUps
        }

        let body = source.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return [] }

        // Explicit tags settle it in either direction, whatever the text says.
        if source.tags.contains(where: { taskTags.contains($0) }) { return [body] }
        if source.tags.contains(where: { referenceTags.contains($0) }) { return [] }

        // A short typed note is a to-do. Not "a short note that parses as an
        // instruction" — that reading kept dropping perfectly ordinary captures
        // like "Haffaf Muscat drawing status", which is neither a bare label nor
        // an imperative and is obviously a thing to deal with.
        //
        // The asymmetry is the point: a false positive costs one swipe to Remove,
        // a false negative costs the thing you were trying not to forget. Tag
        // something #note to keep it out.
        if source.kind == .note, body.count <= shortNoteLimit {
            return [body]
        }

        return Tokenizer.sentences(in: body).filter(DiscussionSummarizer.isActionable)
    }

    // MARK: - Discussion points

    private static func pointItems(
        on dayStart: Date,
        from sources: [BriefSource],
        calendar: Calendar,
        claimed: inout Set<String>
    ) -> [BriefCandidate] {
        guard let cutoff = calendar.date(byAdding: .day, value: -pointLookBackDays, to: dayStart) else { return [] }
        var candidates: [BriefCandidate] = []

        for source in sources where source.createdAt >= cutoff {
            guard let summary = DiscussionSummarizer.parse(source.summary) else { continue }
            for point in summary.keyPoints {
                let line = AnswerComposer.tighten(point, limit: 200)
                let key = BriefEntry.dedupeKey(for: line)
                guard !key.isEmpty, claimed.insert(key).inserted else { continue }
                candidates.append(BriefCandidate(
                    kind: .point,
                    text: line,
                    headline: headline(for: line),
                    detail: detail(for: source, line: line, on: dayStart),
                    scheduledAt: nil,
                    sourceIdentifier: source.identifier
                ))
                if candidates.count >= maximumPoints { return candidates }
            }
        }
        return candidates
    }
}
