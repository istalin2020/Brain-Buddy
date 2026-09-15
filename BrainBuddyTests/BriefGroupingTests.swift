import XCTest
@testable import BrainBuddy

/// Which card a line lands on. The rule that matters most is that it lands on
/// exactly one — the complaint that started this redesign was the same thing
/// showing up in several places at once.
///
/// The cards are the four questions a morning has: what has a time on it, what
/// the office needs, what my own life needs, and what I just need to remember.
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
        closedAt: Date? = nil,
        from region: BrainRegion? = nil
    ) -> BriefGroupKind? {
        BriefGrouping.group(
            kind: kind,
            day: daysAgo(days),
            isClosed: isClosed,
            closedAt: closedAt,
            text: text,
            sourceRegion: region,
            today: today,
            calendar: calendar
        )
    }

    // MARK: - Reminders

    func testSomethingHappeningTodayIsAReminder() {
        XCTAssertEqual(group("Jury round at 11:30", kind: .schedule), .reminders)
    }

    func testALineThatNamesADayIsAReminder() {
        XCTAssertEqual(group("Submit the shutdown plan by Friday"), .reminders)
        XCTAssertEqual(group("Dentist appointment on 29/07/2026"), .reminders)
        XCTAssertEqual(group("Site visit tomorrow morning"), .reminders)
    }

    func testALineThatNamesATimeIsAReminder() {
        XCTAssertEqual(group("Call the site office at 4:30 PM"), .reminders)
    }

    /// The reported case, verbatim.
    func testAskingToBeRemindedIsAReminder() {
        XCTAssertEqual(
            group("Remind me on 20th September to get the invoice from the bank"),
            .reminders
        )
    }

    func testADeadlineOrARenewalIsAReminder() {
        XCTAssertEqual(group("The insurance renewal is due"), .reminders)
        XCTAssertEqual(group("EOT submission deadline"), .reminders)
    }

    /// A month in a sentence about the past is history, not a reminder.
    func testAFactAboutADateIsNotAReminder() {
        XCTAssertEqual(
            group("The material has been at the yard since March", kind: .point),
            .info
        )
    }

    // MARK: - To do, or to know

    func testAnInstructionToYourselfIsAToDo() {
        XCTAssertEqual(group("Prepare the PPT for the hackathon"), .office)
        XCTAssertEqual(group("Buy milk on the way home"), .personal)
    }

    func testACommitmentIsAToDo() {
        XCTAssertEqual(group("I have to close the PCH approval"), .office)
    }

    /// Contains a verb you could read as an order, and is plainly a fact.
    func testAReportOfWhatHappenedIsInformation() {
        XCTAssertEqual(
            group("Al Qersh confirmed to do the sparing work with 60,000 Omani rial"),
            .info
        )
        XCTAssertEqual(group("Transaction with reference id 732379459 processed successfully"), .info)
    }

    func testAStatementOfHowThingsAreIsInformation() {
        XCTAssertEqual(group("The wifi password is 12345"), .info)
        XCTAssertEqual(group("Insulator quality is poor on the north stretch"), .info)
    }

    /// A key point out of a summary is worth knowing, not doing.
    func testAKeyPointIsInformation() {
        XCTAssertEqual(group("Jury panel confirmed", kind: .point, daysAgo: 9), .info)
    }

    /// The quick-capture shape: a label, no verb, obviously something to deal
    /// with.
    func testABareLabelIsAToDo() {
        XCTAssertEqual(group("EOT submission"), .office)
        XCTAssertEqual(group("Haffaf Muscat drawing status"), .office)
    }

    func testAQuestionIsInformation() {
        XCTAssertEqual(group("What did the agency say about it?"), .info)
    }

    // MARK: - Whose work

    func testWorkVocabularyMakesItTheOffices() {
        XCTAssertEqual(group("Send email to Parthiban about the insulator damage"), .office)
        XCTAssertEqual(group("Galvanisation previous reading, send it to Pandi"), .office)
        XCTAssertEqual(group("Call the surveyor back"), .office)
    }

    func testFamilyVocabularyMakesItPersonal() {
        XCTAssertEqual(group("Pick up my daughter from school"), .personal)
        XCTAssertEqual(group("Buy flowers for the wedding dinner"), .personal)
    }

    /// A neutral line takes its side from the document it was quoted out of.
    func testANeutralLineFollowsItsSource() {
        XCTAssertEqual(group("Send it to Pandi", from: .work), .office)
        XCTAssertEqual(group("Send it to Pandi", from: .family), .personal)
        XCTAssertEqual(group("Send it to Pandi"), .personal)
    }

    /// The line beats the document: a personal errand in a work note is still
    /// an errand.
    func testTheLineOutranksItsSource() {
        XCTAssertEqual(group("Pick up my daughter from school", from: .work), .personal)
    }

    // MARK: - Exactly one card

    /// Age no longer moves things around: a to-do from a week ago is still a
    /// to-do, just with a bigger chip.
    func testAgeDoesNotChangeTheCard() {
        XCTAssertEqual(group("Prepare the EOT submission", daysAgo: 6), .office)
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

    // MARK: - When a reminder falls due

    func testTheDueDateIsReadOffTheLine() throws {
        let due = try XCTUnwrap(
            BriefGrouping.dueDate(in: "Dentist appointment on 29 July 2026", today: today, calendar: calendar)
        )
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: due)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 7)
        XCTAssertEqual(parts.day, 29)
    }

    /// The detector reads a numeric range as a clock time; a chip saying
    /// "2:00 PM" under a lab result is worse than no chip.
    func testANumericRangeIsNotADueDate() {
        XCTAssertNil(BriefGrouping.dueDate(in: "Reference range 2 - 2.54 for that panel", today: today, calendar: calendar))
    }

    func testTheChipSaysTheShortestThingThatStillTellsYouWhen() {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        XCTAssertEqual(BriefGrouping.due(for: tomorrow, today: today, calendar: calendar).label, "Tomorrow")
        XCTAssertEqual(BriefGrouping.due(for: today, today: today, calendar: calendar).label, "Today")

        let nextMonth = calendar.date(byAdding: .day, value: 30, to: today) ?? today
        let chip = BriefGrouping.due(for: nextMonth, today: today, calendar: calendar)
        XCTAssertFalse(chip.label.isEmpty)
        XCTAssertFalse(chip.isPast)
    }

    func testAPastDateIsMarkedAsGoneBy() {
        XCTAssertTrue(BriefGrouping.due(for: daysAgo(3), today: today, calendar: calendar).isPast)
    }

    // MARK: - The age badge

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
