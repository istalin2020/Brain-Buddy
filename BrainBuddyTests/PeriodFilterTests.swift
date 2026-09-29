import XCTest
@testable import BrainBuddy

/// The filter that replaced the search box: day, month, year, built from the
/// dates you actually captured on.
final class PeriodFilterTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? Date()
    }

    private var sample: [Date] {
        [
            date(2026, 9, 10, hour: 8),
            date(2026, 9, 10, hour: 20),
            date(2026, 9, 4),
            date(2026, 8, 30),
            date(2025, 12, 1)
        ]
    }

    func testAllHasNoChipsToPick() {
        XCTAssertTrue(PeriodFilter.periods(for: .all, in: sample, calendar: calendar).isEmpty)
    }

    func testDaysAreDeduplicatedAndNewestFirst() {
        let days = PeriodFilter.periods(for: .day, in: sample, calendar: calendar)
        // Two captures on the 10th are one day.
        XCTAssertEqual(days.count, 4)
        XCTAssertEqual(days.first?.start, calendar.startOfDay(for: date(2026, 9, 10)))
    }

    func testMonthsCollapseTheDaysInThem() {
        let months = PeriodFilter.periods(for: .month, in: sample, calendar: calendar)
        XCTAssertEqual(months.count, 3, "September and August 2026, December 2025")
    }

    func testYearsCollapseFurtherStill() {
        let years = PeriodFilter.periods(for: .year, in: sample, calendar: calendar)
        XCTAssertEqual(years.count, 2)
    }

    func testAPeriodContainsOnlyItsOwnDates() throws {
        let months = PeriodFilter.periods(for: .month, in: sample, calendar: calendar)
        let september = try XCTUnwrap(months.first)

        XCTAssertTrue(september.contains(date(2026, 9, 4)))
        XCTAssertTrue(september.contains(date(2026, 9, 30, hour: 23)))
        XCTAssertFalse(september.contains(date(2026, 8, 30)))
        // The end is exclusive: the first moment of October is October's.
        XCTAssertFalse(september.contains(date(2026, 10, 1, hour: 0)))
    }

    func testTheRowIsBounded() {
        let manyDays = (0..<200).compactMap {
            calendar.date(byAdding: .day, value: -$0, to: date(2026, 9, 10))
        }
        let days = PeriodFilter.periods(for: .day, in: manyDays, calendar: calendar, limit: 36)
        XCTAssertEqual(days.count, 36)
    }

    func testNoDatesMeansNoChips() {
        XCTAssertTrue(PeriodFilter.periods(for: .month, in: [], calendar: calendar).isEmpty)
    }
}
