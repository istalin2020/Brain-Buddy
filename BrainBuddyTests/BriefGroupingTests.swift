import XCTest
@testable import BrainBuddy

/// Which card a line lands on. The rule that matters most is that it lands on
/// exactly one — the complaint that started this redesign was the same thing
/// showing up in several places at once.
final class BriefGroupingTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private let today: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 12)) ?? Date()
    }()

    private func daysAgo(_ days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: today) ?? today
    }

    private func group(
        _ text: String = "Something to do",
        kind: BriefEntryKind = .task,
        daysAgo days: Int = 0,
        isClosed: Bool = false,
        closedAt: Date? = nil
    ) -> BriefGroupKind? {
        BriefGrouping.group(
            kind: kind,
            day: daysAgo(days),
            isClosed: isClosed,
            closedAt: closedAt,
            text: text,
            today: today,
            calendar: calendar
        )
    }

    // MARK: - Where things land

    func testTodaysWorkIsATodo() {
        XCTAssertEqual(group("Prepare the PPT for the hackathon"), .todo)
    }

    func testSomethingHappeningTodayIsATopPriority() {
        XCTAssertEqual(group("Jury round at 11:30", kind: .schedule), .priorities)
    }

    /// Three days is the point where "I'll get to it" has been said twice.
    func testSomethingWaitingThreeDaysBecomesATopPriority() {
        XCTAssertEqual(group("Prepare the EOT submission", daysAgo: 3), .priorities)
        XCTAssertEqual(group("Prepare the EOT submission", daysAgo: 2), .todo)
    }

    func testGettingInTouchIsItsOwnCard() {
        XCTAssertEqual(group("Send email to Parthiban about the insulator damage"), .contact)
        XCTAssertEqual(group("Call the surveyor back"), .contact)
        XCTAssertEqual(group("Reply to Wajco and Delta engineering"), .contact)
    }

    /// A job with a hand-off at the end is still a job.
    func testPlainSendIsNotACall() {
        XCTAssertEqual(group("Galvanisation previous reading, send it to Pandi"), .todo)
    }

    /// Age outranks the medium: something you should have emailed four days ago
    /// belongs at the top, not filed politely under calls.
    func testAnAgedCallIsATopPriority() {
        XCTAssertEqual(group("Send email to Parthiban", daysAgo: 4), .priorities)
    }

    func testKeyPointsStayKeyPointsHoweverOldTheyAre() {
        XCTAssertEqual(group("Jury panel confirmed", kind: .point, daysAgo: 9), .points)
    }

    // MARK: - Closed lines

    func testClosedTodayGoesToDone() {
        XCTAssertEqual(group(isClosed: true, closedAt: today), .done)
    }

    func testClosedOnAnEarlierDayIsNotOnTodaysScreen() {
        XCTAssertNil(group(isClosed: true, closedAt: daysAgo(2)))
    }

    func testClosedWithNoTimestampIsNotShown() {
        XCTAssertNil(group(isClosed: true, closedAt: nil))
    }

    // MARK: - The badge

    func testAScheduledLineShowsItsTime() throws {
        let time = calendar.date(byAdding: .hour, value: 11, to: today) ?? today
        let badge = try XCTUnwrap(
            BriefGrouping.badge(scheduledAt: time, day: today, today: today, calendar: calendar)
        )
        XCTAssertFalse(badge.isEmpty)
        XCTAssertFalse(badge.hasSuffix("d"), "A time, not an age")
    }

    func testAnOlderLineShowsHowLongItHasWaited() {
        XCTAssertEqual(
            BriefGrouping.badge(scheduledAt: nil, day: daysAgo(6), today: today, calendar: calendar),
            "6d"
        )
    }

    func testTodaysLineNeedsNoBadge() {
        XCTAssertNil(
            BriefGrouping.badge(scheduledAt: nil, day: today, today: today, calendar: calendar)
        )
    }
}
