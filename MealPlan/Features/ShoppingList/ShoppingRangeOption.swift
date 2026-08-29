import Foundation

enum ShoppingRangeOption: String, CaseIterable, Identifiable, Sendable {
    case next3Days
    case thisWeek
    case next2Weeks
    case thisMonth
    case custom

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .next3Days: String(localized: "Next 3 days")
        case .thisWeek: String(localized: "This week")
        case .next2Weeks: String(localized: "Next 2 weeks")
        case .thisMonth: String(localized: "This month")
        case .custom: String(localized: "Custom range")
        }
    }

    /// Half-open day range for this option.
    func dayRange(reference: Date = .now, customStart: Date, customEnd: Date) -> DayRange {
        let today = reference.startOfDay
        switch self {
        case .next3Days:
            return DayRange(start: today, end: today.adding(days: 3))
        case .thisWeek:
            let start = reference.startOfWeek()
            return DayRange(start: start, end: start.adding(weeks: 1))
        case .next2Weeks:
            return DayRange(start: today, end: today.adding(days: 14))
        case .thisMonth:
            let cal = Calendar.current
            let comps = cal.dateComponents([.year, .month], from: today)
            let start = cal.date(from: comps) ?? today
            let end = cal.date(byAdding: DateComponents(month: 1), to: start) ?? today.adding(days: 30)
            return DayRange(start: start, end: end)
        case .custom:
            let start = min(customStart, customEnd).startOfDay
            let end = max(customStart, customEnd).startOfDay.adding(days: 1)
            return DayRange(start: start, end: end)
        }
    }
}
