import XCTest
@testable import BrainBuddy

/// Pinned to a fixed calendar and a fixed "now", so what lands in a review is a
/// property of the code rather than of the day the suite runs.
final class ReviewBuilderTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 10)) ?? Date()
    }()

    private func daysAgo(_ days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: now) ?? now
    }

    private func memory(
        _ text: String,
        title: String = "Note",
        kind: MemoryKind = .note,
        tags: [String] = [],
        daysAgo days: Int = 0
    ) -> ReviewMemory {
        ReviewMemory(
            id: UUID(),
            title: title,
            text: text,
            kind: kind,
            tags: tags,
            createdAt: daysAgo(days)
        )
    }

    private func task(
        _ subject: String,
        openedDaysAgo: Int = 0,
        closedDaysAgo: Int? = nil
    ) -> ReviewTask {
        ReviewTask(
            subject: subject,
            day: calendar.startOfDay(for: daysAgo(openedDaysAgo)),
            isClosed: closedDaysAgo != nil,
            closedAt: closedDaysAgo.map { daysAgo($0) }
        )
    }

    private func build(
        _ memories: [ReviewMemory] = [],
        _ tasks: [ReviewTask] = [],
        days: Int = 7
    ) -> Review {
        ReviewBuilder.build(memories: memories, tasks: tasks, now: now, days: days, calendar: calendar)
    }

    // MARK: - Period

    func testAnEmptyPeriodSaysSoWithoutPretendingOtherwise() {
        let review = build()
        XCTAssertTrue(review.isEmpty)
        XCTAssertTrue(review.groups.isEmpty)
        XCTAssertEqual(ReviewBuilder.headline(for: review), "Nothing captured, nothing closed. A quiet week.")
    }

    func testOnlyCapturesInsideThePeriodAreCounted() {
        let review = build([
            memory("Inside", daysAgo: 0),
            memory("Also inside", daysAgo: 6),
            memory("Outside", daysAgo: 8)
        ])
        XCTAssertEqual(review.capturedCount, 2)
    }

    func testALongerPeriodReachesFurtherBack() {
        let review = build([memory("Three weeks ago", daysAgo: 20)], days: 30)
        XCTAssertEqual(review.capturedCount, 1)
    }

    // MARK: - Groups

    func testClosedWorkIsReportedAndOldClosuresAreNot() throws {
        let review = build([], [
            task("Send the handover pack", closedDaysAgo: 1),
            task("Chase the invoice", closedDaysAgo: 30)
        ])

        let done = try XCTUnwrap(review.groups.first { $0.id == "closed" })
        XCTAssertEqual(review.closedCount, 1)
        XCTAssertEqual(done.items.map(\.text), ["Send the handover pack"])
    }

    func testOpenWorkLeadsWithItsAge() throws {
        let review = build([], [
            task("Book the survey", openedDaysAgo: 3),
            task("Reply to Sam", openedDaysAgo: 0)
        ])

        let open = try XCTUnwrap(review.groups.first { $0.id == "open" })
        // Oldest first: the age is the point.
        XCTAssertEqual(open.items.first?.text, "Book the survey")
        XCTAssertEqual(open.items.first?.note, "open 3 days")
        XCTAssertEqual(open.items.last?.note, "today")
    }

    func testOpenWorkFromBeforeThePeriodStillCounts() throws {
        // A task doesn't stop mattering because it's old — that's the opposite
        // of true.
        let review = build([], [task("Renew the licence", openedDaysAgo: 40)])
        let open = try XCTUnwrap(review.groups.first { $0.id == "open" })
        XCTAssertEqual(open.items.first?.note, "open 40 days")
    }

    func testQuestionsYouWroteDownComeBack() throws {
        let review = build([
            memory("Should we move the handover to the following Friday? Ask Sam."),
            memory("Why?"),
            memory("Should we move the handover to the following Friday?")
        ])

        let questions = try XCTUnwrap(review.groups.first { $0.id == "questions" })
        XCTAssertEqual(questions.items.count, 1, "Too short to be a question, and a repeat, should both be dropped")
        XCTAssertEqual(questions.items.first?.text, "Should we move the handover to the following Friday?")
    }

    func testRecurringSubjectsAreNamedAndOneOffsAreNot() {
        let subjects = ReviewBuilder.recurringSubjects(in: [
            memory("Tower handover slipped again", tags: ["site"]),
            memory("Tower snagging list needs signing off", tags: ["site"]),
            memory("Bought sourdough starter from the market")
        ])

        XCTAssertTrue(
            subjects.contains { $0.name.lowercased().contains("tower") || $0.name == "#site" },
            "Expected a recurring subject: \(subjects.map(\.name))"
        )
        XCTAssertFalse(subjects.contains { $0.name.lowercased().contains("sourdough") })
        XCTAssertTrue(subjects.allSatisfy { $0.count >= ReviewBuilder.minimumSubjectCount })
    }

    // MARK: - Phrasing

    func testTheMixLineCountsEachKindInPlainEnglish() {
        let line = ReviewBuilder.mixLine(for: [
            memory("One"),
            memory("Two", kind: .voice),
            memory("Three", kind: .voice)
        ])
        XCTAssertEqual(line, "1 note · 2 voice notes")
    }

    func testTheHeadlineReadsAsASentenceOfCounts() {
        let review = build(
            [memory("Something")],
            [task("Open thing", openedDaysAgo: 2), task("Closed thing", closedDaysAgo: 1)]
        )
        XCTAssertEqual(ReviewBuilder.headline(for: review), "1 capture · 1 closed · 1 still open")
    }

    func testShareTextCarriesEveryGroup() {
        let review = build(
            [memory("Something")],
            [task("Book the survey", openedDaysAgo: 3), task("Send the pack", closedDaysAgo: 1)]
        )
        let text = ReviewBuilder.shareText(for: review)

        XCTAssertTrue(text.hasPrefix("Brain Buddy · "))
        XCTAssertTrue(text.contains("DONE"))
        XCTAssertTrue(text.contains("STILL OPEN"))
        XCTAssertTrue(text.contains("• Book the survey — open 3 days"))
    }
}
