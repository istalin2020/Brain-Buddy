import XCTest
@testable import BrainBuddy

final class BriefBuilderTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    /// Fixed day so nothing here depends on when the suite runs.
    private var today: Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 5))!
    }

    private func source(
        text: String,
        summary: String = "",
        daysAgo: Int = 0,
        title: String = "A note"
    ) -> BriefSource {
        BriefSource(
            identifier: UUID(),
            title: title,
            text: text,
            summary: summary,
            createdAt: calendar.date(byAdding: .day, value: -daysAgo, to: today)!,
            kindTitle: "Note"
        )
    }

    /// Writes a date the way `NSDataDetector` reliably reads it, so schedule tests
    /// assert on the builder rather than on a particular phrasing.
    private func absolutePhrase(for date: Date, hour: Int, minute: Int = 0) -> String {
        let stamp = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        return formatter.string(from: stamp)
    }

    // MARK: - Schedule

    func testDateOnTodayBecomesAScheduleLine() {
        let phrase = absolutePhrase(for: today, hour: 16)
        let candidates = BriefBuilder.build(
            for: today,
            from: [source(text: "Site review with PCH on \(phrase). Bring the drawings.")],
            calendar: calendar
        )

        let schedule = candidates.filter { $0.kind == .schedule }
        XCTAssertEqual(schedule.count, 1)
        XCTAssertTrue(schedule[0].text.contains("Site review with PCH"))
        XCTAssertNotNil(schedule[0].scheduledAt, "a time was given, so it should be carried")
    }

    /// Only the sentence around the date, not the whole note.
    func testScheduleLineIsTheSentenceNotTheWholeNote() throws {
        let phrase = absolutePhrase(for: today, hour: 9, minute: 30)
        let candidates = BriefBuilder.build(
            for: today,
            from: [source(text: "Unrelated first thought. Standup on \(phrase). Another unrelated thought.")],
            calendar: calendar
        )

        let schedule = try XCTUnwrap(candidates.first { $0.kind == .schedule })
        XCTAssertTrue(schedule.text.contains("Standup"))
        XCTAssertFalse(schedule.text.contains("Unrelated first thought"))
        XCTAssertFalse(schedule.text.contains("Another unrelated"))
    }

    func testDateOnAnotherDayIsIgnored() {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let candidates = BriefBuilder.build(
            for: today,
            from: [source(text: "Dentist on \(absolutePhrase(for: tomorrow, hour: 11)).")],
            calendar: calendar
        )
        XCTAssertTrue(candidates.filter { $0.kind == .schedule }.isEmpty)
    }

    /// A dated reminder written a month ago is exactly what a brief is for, so
    /// schedule detection must not be limited by how old the capture is.
    func testOldNoteStillSurfacesTodaysDate() {
        let phrase = absolutePhrase(for: today, hour: 15)
        let candidates = BriefBuilder.build(
            for: today,
            from: [source(text: "Quarterly review on \(phrase).", daysAgo: 60)],
            calendar: calendar
        )
        XCTAssertEqual(candidates.filter { $0.kind == .schedule }.count, 1)
    }

    func testScheduleLinesAreSortedByTime() {
        let late = absolutePhrase(for: today, hour: 17)
        let early = absolutePhrase(for: today, hour: 8)
        let candidates = BriefBuilder.build(
            for: today,
            from: [source(text: "Wrap-up call on \(late). Kickoff on \(early).")],
            calendar: calendar
        )

        let schedule = candidates.filter { $0.kind == .schedule }
        XCTAssertEqual(schedule.count, 2)
        XCTAssertTrue(schedule[0].text.contains("Kickoff"), "earliest first")
    }

    // MARK: - Bare clock times

    /// `NSDataDetector` resolves a bare time against the *actual* present moment,
    /// not against an injected date, so these have to run against the real today
    /// or the day filter would reject the match before the rule under test is
    /// ever reached.
    private var realToday: Date { calendar.startOfDay(for: Date()) }

    private func recentSource(text: String, daysAgo: Int) -> BriefSource {
        BriefSource(
            identifier: UUID(),
            title: "A note",
            text: text,
            summary: "",
            createdAt: calendar.date(byAdding: .day, value: -daysAgo, to: realToday)!,
            kindTitle: "Note"
        )
    }

    /// An old note mentioning `12:05` used to become an appointment today.
    func testABareTimeInAnOldNoteIsNotTodaysSchedule() {
        let candidates = BriefBuilder.build(
            for: realToday,
            from: [recentSource(text: "Printed at 12:05 on the report footer.", daysAgo: 8)],
            calendar: calendar
        )
        XCTAssertTrue(candidates.filter { $0.kind == .schedule }.isEmpty)
    }

    /// A numeric range reads as a clock time to the detector — this is what put
    /// "2 - 2.54 at 2:00 PM" in a brief.
    func testANumericRangeIsNotAnAppointment() {
        let candidates = BriefBuilder.build(
            for: realToday,
            from: [recentSource(text: "Reference range 2 - 2.54 for that panel.", daysAgo: 3)],
            calendar: calendar
        )
        XCTAssertTrue(candidates.filter { $0.kind == .schedule }.isEmpty)
    }

    /// But a time in something written today does mean today.
    func testABareTimeInTodaysNoteIsKept() {
        let candidates = BriefBuilder.build(
            for: realToday,
            from: [recentSource(text: "Call the site office at 4:30 PM.", daysAgo: 0)],
            calendar: calendar
        )
        XCTAssertEqual(candidates.filter { $0.kind == .schedule }.count, 1)
    }

    func testNamesADayRecognizesRealDayReferences() {
        XCTAssertTrue(BriefBuilder.namesADay("August 5, 2026 at 4:00 PM"))
        XCTAssertTrue(BriefBuilder.namesADay("tomorrow at 9"))
        XCTAssertTrue(BriefBuilder.namesADay("Tuesday morning"))
        XCTAssertTrue(BriefBuilder.namesADay("29/07/2026"))
        XCTAssertTrue(BriefBuilder.namesADay("2026-08-06 10:30"))
    }

    func testNamesADayRejectsClockTimesAndNumbers() {
        XCTAssertFalse(BriefBuilder.namesADay("12:05"))
        XCTAssertFalse(BriefBuilder.namesADay("2 - 2.54"))
        XCTAssertFalse(BriefBuilder.namesADay("4:30 PM"))
        XCTAssertFalse(BriefBuilder.namesADay("10:30:00"))
    }

    // MARK: - Where a line came from

    /// A one-sentence note is titled after its own first line, so using the title
    /// as the subtitle printed the same sentence twice.
    func testDetailDoesNotRepeatTheLine() throws {
        let sentence = "I have to complete my EOT submission for M526 Project"
        let candidates = BriefBuilder.build(
            for: today,
            from: [BriefSource(
                identifier: UUID(),
                title: sentence,
                text: sentence,
                summary: "",
                createdAt: calendar.date(byAdding: .day, value: -1, to: today)!,
                kindTitle: "Voice note"
            )],
            calendar: calendar
        )

        let task = try XCTUnwrap(candidates.first { $0.kind == .task })
        XCTAssertNotEqual(task.detail, sentence)
        XCTAssertTrue(task.detail.contains("Voice note"), "got “\(task.detail)”")
        XCTAssertTrue(task.detail.contains("yesterday"), "got “\(task.detail)”")
    }

    /// When the title genuinely says something else, it's the more useful subtitle.
    func testDetailKeepsATitleThatAddsInformation() throws {
        let candidates = BriefBuilder.build(
            for: today,
            from: [BriefSource(
                identifier: UUID(),
                title: "Site meeting with PCH",
                text: "Lots of ground covered. I have to close the approval this week.",
                summary: "",
                createdAt: today,
                kindTitle: "Voice note"
            )],
            calendar: calendar
        )

        let task = try XCTUnwrap(candidates.first { $0.kind == .task })
        XCTAssertEqual(task.detail, "Site meeting with PCH")
    }

    // MARK: - What counts as work

    /// Real captures do not phrase themselves in the first person. These are the
    /// three shapes that were being missed while the brief sat empty.
    func testWorkPhrasedWithoutACommitmentStillCounts() {
        XCTAssertTrue(
            DiscussionSummarizer.isActionable("Method statement to be reviewed by the testing agency"),
            "a passive obligation is still an obligation"
        )
        XCTAssertTrue(
            DiscussionSummarizer.isActionable("Send the revised drawings to PCH"),
            "an imperative is an instruction to yourself"
        )
        XCTAssertTrue(
            DiscussionSummarizer.isActionable("Leap meeting, study the stringing execution improvement"),
            "the instruction is after the comma"
        )
    }

    func testPlainDescriptionIsStillNotWork() {
        XCTAssertFalse(DiscussionSummarizer.isActionable("The material has been at the yard since March"))
        XCTAssertFalse(DiscussionSummarizer.isActionable("It was raining the whole afternoon"))
        XCTAssertFalse(DiscussionSummarizer.isActionable("What did the agency say about it?"))
    }

    /// A short typed note is a to-do: that is what a quick capture box is for, and
    /// "EOT submission" will never phrase itself as a commitment.
    func testAShortTypedNoteIsATask() {
        let candidates = BriefBuilder.build(
            for: today,
            from: [source(text: "EOT submission", daysAgo: 1)],
            calendar: calendar
        )
        XCTAssertEqual(candidates.filter { $0.kind == .task }.map(\.text), ["EOT submission"])
    }

    /// The reported miss: neither a bare label nor an imperative, and obviously a
    /// thing to deal with. Requiring it to parse as one or the other is what made
    /// Refresh look broken.
    func testAnOrdinaryShortNoteIsATask() {
        let candidates = BriefBuilder.build(
            for: today,
            from: [source(text: "Haffaf Muscat drawing status", daysAgo: 0)],
            calendar: calendar
        )
        XCTAssertEqual(candidates.filter { $0.kind == .task }.map(\.text), ["Haffaf Muscat drawing status"])
    }

    /// The escape hatch for the false positives that inclusiveness buys.
    func testAReferenceTagKeepsANoteOut() {
        let candidates = BriefBuilder.build(
            for: today,
            from: [BriefSource(
                identifier: UUID(),
                title: "Wifi",
                text: "The wifi password is 12345",
                createdAt: today,
                kind: .note,
                kindTitle: "Note",
                tags: ["note"]
            )],
            calendar: calendar
        )
        XCTAssertTrue(candidates.filter { $0.kind == .task }.isEmpty)
    }

    /// A long transcript is not, or every recording would become one giant task.
    func testALongTranscriptIsNotTreatedAsOneTask() {
        let rambling = String(repeating: "we talked about the yard and the weather for a while. ", count: 12)
        let candidates = BriefBuilder.build(
            for: today,
            from: [BriefSource(
                identifier: UUID(),
                title: "Voice note",
                text: rambling,
                createdAt: calendar.date(byAdding: .day, value: -1, to: today)!,
                kind: .voice,
                kindTitle: "Voice note"
            )],
            calendar: calendar
        )
        XCTAssertTrue(candidates.filter { $0.text == rambling }.isEmpty)
    }

    /// An explicit tag settles the ambiguous cases the app can't read.
    func testATaskTagAlwaysQualifies() {
        let long = String(repeating: "background and context on the yard situation. ", count: 8)
        let candidates = BriefBuilder.build(
            for: today,
            from: [BriefSource(
                identifier: UUID(),
                title: "Yard",
                text: long,
                createdAt: calendar.date(byAdding: .day, value: -1, to: today)!,
                kind: .voice,
                kindTitle: "Voice note",
                tags: ["todo"]
            )],
            calendar: calendar
        )
        XCTAssertFalse(candidates.filter { $0.kind == .task }.isEmpty)
    }

    /// Work does not stop being owed after a fortnight.
    func testTasksSurviveWellBeyondAFortnight() {
        let candidates = BriefBuilder.build(
            for: today,
            from: [source(text: "I have to renew the insurance policy.", daysAgo: 30)],
            calendar: calendar
        )
        XCTAssertEqual(candidates.filter { $0.kind == .task }.count, 1)
    }

    // MARK: - Tasks

    func testCommitmentSentencesBecomeTasks() {
        let candidates = BriefBuilder.build(
            for: today,
            from: [source(text: "The yard was quiet today. I have to close the PCH approval this week.")],
            calendar: calendar
        )

        let tasks = candidates.filter { $0.kind == .task }
        XCTAssertEqual(tasks.count, 1)
        XCTAssertTrue(tasks[0].text.contains("close the PCH approval"))
    }

    func testPlainObservationsAreNotTasks() {
        let candidates = BriefBuilder.build(
            for: today,
            from: [source(text: "The yard was quiet today. It rained the whole afternoon.")],
            calendar: calendar
        )
        XCTAssertTrue(candidates.filter { $0.kind == .task }.isEmpty)
    }

    func testTasksOlderThanTheWindowAreDropped() {
        let text = "I have to renew the insurance policy."
        let recent = BriefBuilder.build(for: today, from: [source(text: text, daysAgo: 3)], calendar: calendar)
        let stale = BriefBuilder.build(for: today, from: [source(text: text, daysAgo: 90)], calendar: calendar)

        XCTAssertEqual(recent.filter { $0.kind == .task }.count, 1)
        XCTAssertTrue(stale.filter { $0.kind == .task }.isEmpty)
    }

    /// The ceiling is a safety bound, not a display limit. It has to sit far above
    /// any realistic number of outstanding tasks, because a cap reached *before*
    /// deduplication spends its slots on lines already in the brief and drops
    /// whatever was captured most recently.
    func testTaskCountIsBoundedButNotSmall() {
        let sentences = (1...30).map { "I have to finish item number \($0) before the deadline." }
        let candidates = BriefBuilder.build(
            for: today,
            from: [source(text: sentences.joined(separator: " "))],
            calendar: calendar
        )
        let tasks = candidates.filter { $0.kind == .task }
        XCTAssertLessThanOrEqual(tasks.count, BriefBuilder.candidateCeiling)
        XCTAssertGreaterThan(tasks.count, 10, "a small pre-dedupe cap is what hid new captures")
    }

    // MARK: - Summaries feed the brief

    func testSavedSummaryFeedsPointsAndFollowUps() {
        let summary = DiscussionSummarizer.Summary(
            topics: ["tower material"],
            keyPoints: ["The material has been at the yard since March"],
            followUps: ["I have to close the PCH approval this week"]
        ).text

        let candidates = BriefBuilder.build(
            for: today,
            from: [source(text: "long transcript here", summary: summary, daysAgo: 1)],
            calendar: calendar
        )

        XCTAssertEqual(
            candidates.filter { $0.kind == .point }.map(\.text),
            ["The material has been at the yard since March"]
        )
        XCTAssertEqual(
            candidates.filter { $0.kind == .task }.map(\.text),
            ["I have to close the PCH approval this week"]
        )
    }

    /// Discussion points age out faster than tasks: a point from last month is
    /// history, a task from last month may still be owed.
    func testPointsUseTheShorterWindow() {
        let summary = DiscussionSummarizer.Summary(
            topics: [],
            keyPoints: ["The material has been at the yard since March"],
            followUps: []
        ).text

        let stale = BriefBuilder.build(
            for: today,
            from: [source(text: "transcript", summary: summary, daysAgo: 10)],
            calendar: calendar
        )
        XCTAssertTrue(stale.filter { $0.kind == .point }.isEmpty)
    }

    // MARK: - No line twice

    func testADatedCommitmentAppearsOnlyOnce() {
        let phrase = absolutePhrase(for: today, hour: 14)
        let candidates = BriefBuilder.build(
            for: today,
            from: [source(text: "I have to send the signed contract on \(phrase).")],
            calendar: calendar
        )

        XCTAssertEqual(candidates.count, 1, "one sentence should produce one line")
        XCTAssertEqual(candidates[0].kind, .schedule, "a dated line belongs in the schedule")
    }

    func testTheSameSentenceInTwoNotesProducesOneLine() {
        let text = "I have to close the PCH approval this week."
        let candidates = BriefBuilder.build(
            for: today,
            from: [source(text: text, daysAgo: 1), source(text: text, daysAgo: 2)],
            calendar: calendar
        )
        XCTAssertEqual(candidates.filter { $0.kind == .task }.count, 1)
    }

    func testEmptyLibraryProducesNothing() {
        XCTAssertTrue(BriefBuilder.build(for: today, from: [], calendar: calendar).isEmpty)
    }

    /// A scanned document reaches the builder with no authored text and no saved
    /// summary — `BriefService` puts nothing else in — and must produce no lines.
    /// Its printed timestamps are not a calendar and it contains no commitments.
    func testASourceWithNothingAuthoredProducesNothing() {
        let scanned = BriefSource(
            identifier: UUID(),
            title: "DEPARTMENT OF LABORATORY MEDICINE",
            text: "",
            summary: "",
            createdAt: today,
            kindTitle: "Document"
        )
        XCTAssertTrue(BriefBuilder.build(for: today, from: [scanned], calendar: calendar).isEmpty)
    }

    func testBlankSourcesProduceNothing() {
        XCTAssertTrue(
            BriefBuilder.build(for: today, from: [source(text: "   ", title: "")], calendar: calendar).isEmpty
        )
    }

    // MARK: - Dedupe keys

    func testDedupeKeyIgnoresPunctuationAndCase() {
        XCTAssertEqual(
            BriefEntry.dedupeKey(for: "Close the PCH approval!"),
            BriefEntry.dedupeKey(for: "close the pch approval")
        )
    }

    func testDifferentSentencesGetDifferentKeys() {
        XCTAssertNotEqual(
            BriefEntry.dedupeKey(for: "Close the PCH approval"),
            BriefEntry.dedupeKey(for: "Renew the insurance policy")
        )
    }
}

/// The stored-summary round trip the brief depends on.
final class SummaryRoundTripTests: XCTestCase {
    func testRenderedSummaryParsesBack() throws {
        let original = DiscussionSummarizer.Summary(
            topics: ["PCH", "tower material"],
            keyPoints: ["The material has been at the yard since March", "Rent accrues weekly"],
            followUps: ["I have to close the approval this week"]
        )
        let parsed = try XCTUnwrap(DiscussionSummarizer.parse(original.text))
        XCTAssertEqual(parsed, original)
    }

    func testParsingEmptyTextReturnsNil() {
        XCTAssertNil(DiscussionSummarizer.parse(""))
        XCTAssertNil(DiscussionSummarizer.parse("   \n  "))
    }

    func testParsingIgnoresUnrecognizedLines() throws {
        let text = """
        Topics: PCH

        Key points
        • The material is still at the yard
        some stray line without a bullet

        Follow-ups
        • I have to call the yard
        """
        let parsed = try XCTUnwrap(DiscussionSummarizer.parse(text))
        XCTAssertEqual(parsed.topics, ["PCH"])
        XCTAssertEqual(parsed.keyPoints, ["The material is still at the yard"])
        XCTAssertEqual(parsed.followUps, ["I have to call the yard"])
    }

    /// A hand-typed summary with no headings still yields something usable rather
    /// than being thrown away.
    func testBulletsWithoutHeadingsBecomeKeyPoints() throws {
        let parsed = try XCTUnwrap(DiscussionSummarizer.parse("• first thing\n• second thing"))
        XCTAssertEqual(parsed.keyPoints, ["first thing", "second thing"])
        XCTAssertTrue(parsed.followUps.isEmpty)
    }
}
