import Foundation

extension Date {
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    func adding(days: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: self) ?? self
    }

    func adding(weeks: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .weekOfYear, value: weeks, to: self) ?? self
    }

    /// Monday-based start of the week containing this date.
    func startOfWeek(calendar: Calendar = mondayCalendar) -> Date {
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: self)
        return calendar.date(from: comps) ?? startOfDay
    }

    func isSameDay(as other: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(self, inSameDayAs: other)
    }

    /// A stable identifier for a calendar day, e.g. "2026-08-28".
    var dayID: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: self)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static var mondayCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday
        cal.minimumDaysInFirstWeek = 4
        return cal
    }
}

/// A half-open range of days [start, end).
struct DayRange: Equatable, Sendable {
    var start: Date
    var end: Date

    var lowerBound: Date { start }
    var upperBound: Date { end }

    func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    var days: [Date] {
        var result: [Date] = []
        var cursor = start.startOfDay
        let limit = end.startOfDay
        while cursor < limit {
            result.append(cursor)
            cursor = cursor.adding(days: 1)
        }
        return result
    }
}
