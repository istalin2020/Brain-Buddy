import XCTest
@testable import BrainBuddy

/// The reminder timetable is pure arithmetic, so it's worth pinning down away from
/// the notification centre.
final class NotificationScheduleTests: XCTestCase {
    private func minutes(_ times: [DateComponents]) -> [Int] {
        times.map { ($0.hour ?? 0) * 60 + ($0.minute ?? 0) }
    }

    func testSevenRemindersSpreadFromTheStartTimeToTheEveningCutoff() {
        let times = NotificationScheduler.reminderTimes(startHour: 8, startMinute: 0, count: 7)
        let stops = minutes(times)

        XCTAssertEqual(stops.count, 7)
        XCTAssertEqual(stops.first, 8 * 60, "the first reminder is the time you chose")
        XCTAssertEqual(stops.last, NotificationScheduler.dayEndHour * 60, "the last lands on the cutoff")
        XCTAssertEqual(stops, stops.sorted())
    }

    func testGapsAreEvenAndComfortable() {
        let stops = minutes(NotificationScheduler.reminderTimes(startHour: 8, startMinute: 0, count: 7))
        let gaps = zip(stops, stops.dropFirst()).map { $1 - $0 }
        XCTAssertEqual(Set(gaps).count, 1, "evenly spread")
        XCTAssertGreaterThanOrEqual(gaps[0], NotificationScheduler.minimumSpacingMinutes)
    }

    func testOneReminderIsJustTheChosenTime() {
        XCTAssertEqual(
            minutes(NotificationScheduler.reminderTimes(startHour: 7, startMinute: 30, count: 1)),
            [7 * 60 + 30]
        )
    }

    /// A start time past the evening cutoff leaves no window to divide. It must
    /// still produce distinct, ascending times rather than stacking them all on
    /// one minute or wrapping past midnight.
    func testALateStartFallsBackToFixedSpacing() {
        let stops = minutes(NotificationScheduler.reminderTimes(startHour: 20, startMinute: 0, count: 5))
        XCTAssertEqual(stops.count, 5)
        XCTAssertEqual(stops, stops.sorted())
        XCTAssertLessThanOrEqual(stops.last ?? 0, 23 * 60 + 30, "never after 23:30")
        XCTAssertGreaterThanOrEqual(stops.first ?? 0, 20 * 60)
    }

    func testCountIsClamped() {
        XCTAssertEqual(
            NotificationScheduler.reminderTimes(startHour: 8, startMinute: 0, count: 99).count,
            NotificationScheduler.maximumRemindersPerDay
        )
        XCTAssertEqual(
            NotificationScheduler.reminderTimes(startHour: 8, startMinute: 0, count: 0).count,
            1
        )
    }

    func testIdentifiersAreDistinctPerSlot() {
        let identifiers = (0..<NotificationScheduler.maximumRemindersPerDay)
            .map(NotificationScheduler.reminderIdentifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }
}
