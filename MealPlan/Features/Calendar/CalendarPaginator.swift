import Foundation
import Observation

/// Keeps the endlessly-scrolling calendar's window of loaded weeks. Grows in
/// either direction as the user scrolls. All week-start dates are produced
/// through `normalizedWeek(of:)` so they compare equal as `ForEach` / scroll
/// identities.
@Observable
@MainActor
final class CalendarPaginator {
    private(set) var weekStarts: [Date]

    private let calendar = Date.mondayCalendar
    private let step = 4
    private let maxWeeks = 200

    init(reference: Date = .now, past: Int = 8, future: Int = 8) {
        let base = Self.normalizedWeek(of: reference)
        weekStarts = ((-past)...future).map { offset in
            Self.normalizedWeek(of: base.adding(weeks: offset, calendar: Date.mondayCalendar))
        }
    }

    nonisolated static func normalizedWeek(of date: Date) -> Date {
        date.startOfWeek(calendar: Date.mondayCalendar)
    }

    var firstWeek: Date { weekStarts.first ?? Self.normalizedWeek(of: .now) }
    var lastWeek: Date { weekStarts.last ?? Self.normalizedWeek(of: .now) }

    func extendPast() {
        guard let first = weekStarts.first else { return }
        let newWeeks = (1...step).reversed().map {
            Self.normalizedWeek(of: first.adding(weeks: -$0, calendar: calendar))
        }
        weekStarts.insert(contentsOf: newWeeks, at: 0)
        if weekStarts.count > maxWeeks {
            weekStarts.removeLast(weekStarts.count - maxWeeks)
        }
    }

    func extendFuture() {
        guard let last = weekStarts.last else { return }
        let newWeeks = (1...step).map {
            Self.normalizedWeek(of: last.adding(weeks: $0, calendar: calendar))
        }
        weekStarts.append(contentsOf: newWeeks)
        if weekStarts.count > maxWeeks {
            weekStarts.removeFirst(weekStarts.count - maxWeeks)
        }
    }

    /// Ensure `date`'s week is loaded, extending as needed. Returns the
    /// week-start `Date` that identifies its section.
    @discardableResult
    func ensureLoaded(_ date: Date) -> Date {
        let target = Self.normalizedWeek(of: date)
        var guardCount = 0
        while target < firstWeek, guardCount < 60 { extendPast(); guardCount += 1 }
        while target > lastWeek, guardCount < 120 { extendFuture(); guardCount += 1 }
        return weekStarts.first(where: { $0 == target }) ?? target
    }
}
