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
            let body = source.text.isEmpty ? source.title : source.text
            guard !body.isEmpty else { continue }

            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            for match in detector.matches(in: body, options: [], range: range) {
                guard let date = match.date, calendar.isDate(date, inSameDayAs: dayStart) else { continue }
                guard let matchRange = Range(match.range, in: body) else { continue }

                let sentence = sentenceContaining(matchRange, in: body)
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
                    detail: source.title,
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

    /// The sentence a detected date sits inside, so the brief line reads as
    /// something you wrote rather than as a bare timestamp.
    private static func sentenceContaining(_ range: Range<String.Index>, in text: String) -> String {
        let breaks = CharacterSet(charactersIn: ".!?\n")

        var start = text.startIndex
        if let before = text.rangeOfCharacter(from: breaks, options: .backwards, range: text.startIndex..<range.lowerBound) {
            start = before.upperBound
        }
        var end = text.endIndex
        if let after = text.rangeOfCharacter(from: breaks, range: range.upperBound..<text.endIndex) {
            end = after.lowerBound
        }
        return AnswerComposer.tighten(String(text[start..<end]), limit: 200)
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
                    detail: source.title,
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
                    detail: source.title,
                    scheduledAt: nil,
                    sourceIdentifier: source.identifier
                ))
                if candidates.count >= maximumPoints { return candidates }
            }
        }
        return candidates
    }
}
