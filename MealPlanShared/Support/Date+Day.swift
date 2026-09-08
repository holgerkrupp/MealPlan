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
    ///
    /// This is the plan's scroll and visibility identity, so it is asked for
    /// many times per frame while the calendar moves. `String(format:)` bridges
    /// through `NSString` and is far too slow for that; the digits are laid out
    /// by hand instead.
    var dayID: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: self)
        return Self.dayID(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    static func dayID(year: Int, month: Int, day: Int) -> String {
        func pad(_ value: Int, _ width: Int) -> String {
            let digits = String(value)
            guard digits.count < width else { return digits }
            return String(repeating: "0", count: width - digits.count) + digits
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
    }

    /// Built once: the calendar is fixed (Gregorian, Monday-first) and does not
    /// follow the user's locale, and rebuilding one per call showed up in the
    /// plan's scrolling — every week grouping asked for it once per entry.
    static let mondayCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday
        cal.minimumDaysInFirstWeek = 4
        return cal
    }()
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
