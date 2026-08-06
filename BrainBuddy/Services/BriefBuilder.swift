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
    let kindTitle: String
}

/// One proposed line of a brief, before it's persisted as a `BriefEntry`.
struct BriefCandidate: Equatable {
    let kind: BriefEntryKind
    let text: String
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
    static let taskLookBackDays = 14
    static let pointLookBackDays = 7

    static let maximumScheduleItems = 8
    static let maximumTasks = 10
    static let maximumPoints = 5

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
            // A summary's follow-ups are already the distilled commitments, so
            // when one exists it's a better source than re-scanning the raw text.
            let followUps = DiscussionSummarizer.parse(source.summary)?.followUps ?? []
            let sentences = followUps.isEmpty
                ? Tokenizer.sentences(in: source.text).filter(DiscussionSummarizer.isCommitment)
                : followUps

            for sentence in sentences {
                let line = AnswerComposer.tighten(sentence, limit: 200)
                let key = BriefEntry.dedupeKey(for: line)
                guard !key.isEmpty, claimed.insert(key).inserted else { continue }
                candidates.append(BriefCandidate(
                    kind: .task,
                    text: line,
                    detail: detail(for: source, line: line, on: dayStart),
                    scheduledAt: nil,
                    sourceIdentifier: source.identifier
                ))
                if candidates.count >= maximumTasks { return candidates }
            }
        }
        return candidates
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
