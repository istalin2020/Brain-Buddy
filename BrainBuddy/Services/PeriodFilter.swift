import Foundation

/// How wide a slice of time the brain is showing.
enum PeriodScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case day
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .day: return "Day"
        case .month: return "Month"
        case .year: return "Year"
        }
    }
}

/// One selectable slice — a day, a month, a year.
struct BrainPeriod: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let start: Date
    /// Exclusive, as `Calendar.dateInterval` reports it.
    let end: Date

    func contains(_ date: Date) -> Bool { date >= start && date < end }
}

/// Turns the dates you actually captured on into the filter chips.
///
/// Built from the library rather than from a calendar picker: a month with
/// nothing in it is not worth a tap, and scrolling a row of real months is
/// faster than opening a date picker to guess at one.
enum PeriodFilter {
    /// A year of days, two years of months — enough to reach anything without
    /// the row becoming its own scrolling problem.
    static let limit = 36

    static func periods(
        for scope: PeriodScope,
        in dates: [Date],
        calendar: Calendar = .current,
        limit: Int = limit
    ) -> [BrainPeriod] {
        guard scope != .all, !dates.isEmpty else { return [] }

        var seen = Set<Date>()
        var periods: [BrainPeriod] = []

        for date in dates.sorted(by: >) {
            guard let interval = calendar.dateInterval(of: component(for: scope), for: date) else {
                continue
            }
            guard seen.insert(interval.start).inserted else { continue }
            periods.append(
                BrainPeriod(
                    id: "\(scope.rawValue)-\(Int(interval.start.timeIntervalSince1970))",
                    label: label(for: interval.start, scope: scope, calendar: calendar),
                    start: interval.start,
                    end: interval.end
                )
            )
            if periods.count >= limit { break }
        }
        return periods
    }

    static func component(for scope: PeriodScope) -> Calendar.Component {
        switch scope {
        case .day: return .day
        case .month: return .month
        case .year: return .year
        case .all: return .era
        }
    }

    static func label(for date: Date, scope: PeriodScope, calendar: Calendar) -> String {
        switch scope {
        case .day:
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            return date.formatted(.dateTime.day().month(.abbreviated))
        case .month:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
            return sameYear
                ? date.formatted(.dateTime.month(.wide))
                : date.formatted(.dateTime.month(.abbreviated).year())
        case .year:
            return date.formatted(.dateTime.year())
        case .all:
            return "All"
        }
    }
}
