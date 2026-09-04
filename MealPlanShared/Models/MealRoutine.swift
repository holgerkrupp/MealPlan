import Foundation
import SwiftData

/// A standing arrangement like "Taco Tuesday" or "pizza every second Sunday":
/// one dish, on one weekday, repeating every *n* weeks. The scheduler turns
/// these into real `MealPlanEntry`s a few weeks ahead, so a routine behaves
/// like something the family planned themselves — it can be moved, swapped or
/// deleted for a single week without touching the routine.
@Model
final class MealRoutine {
    var uuid: UUID = UUID()
    var modifiedAt: Date = Date.now
    var dish: Dish?
    /// Which meal of the day this lands in. See `MealType.key`.
    var mealKey: String = MealSlot.dinner.rawValue
    /// `Calendar` weekday: 1 = Sunday … 7 = Saturday.
    var weekday: Int = 3
    /// 1 = every week, 2 = every second week, and so on.
    var intervalWeeks: Int = 1
    /// The first day the routine may plan a meal on. Also fixes the phase of
    /// an every-*n*-weeks routine: weeks are counted from this date.
    var startDate: Date = Date.now.startOfDay
    var isActive: Bool = true
    /// Last day the scheduler has already filled in, so a meal the family
    /// deleted for one week doesn't come back on the next launch.
    var plannedThrough: Date?
    var dateCreated: Date = Date.now

    var household: Household?

    init(
        dish: Dish? = nil,
        mealKey: String = MealSlot.dinner.rawValue,
        weekday: Int = 3,
        intervalWeeks: Int = 1,
        startDate: Date = Date.now.startOfDay
    ) {
        self.uuid = UUID()
        self.dish = dish
        self.mealKey = mealKey
        self.weekday = weekday
        self.intervalWeeks = intervalWeeks
        self.startDate = startDate.startOfDay
        self.dateCreated = .now
    }
}

extension MealRoutine {

    /// True when this routine plans a meal on `date`: the weekday matches and
    /// the week is on-cycle, counting whole weeks from `startDate`.
    func occurs(on date: Date, calendar: Calendar = .current) -> Bool {
        let day = date.startOfDay
        guard isActive, day >= startDate.startOfDay else { return false }
        guard calendar.component(.weekday, from: day) == weekday else { return false }
        let interval = max(1, intervalWeeks)
        guard interval > 1 else { return true }

        // Count from the start of the routine's own week so the phase doesn't
        // shift when `startDate` falls mid-week.
        let anchor = startDate.startOfWeek(calendar: calendar)
        let weeks = calendar.dateComponents([.weekOfYear], from: anchor, to: day.startOfWeek(calendar: calendar)).weekOfYear ?? 0
        return weeks >= 0 && weeks % interval == 0
    }

    /// The days this routine covers in `[from, through]`.
    func occurrences(from: Date, through: Date, calendar: Calendar = .current) -> [Date] {
        var result: [Date] = []
        var cursor = from.startOfDay
        let limit = through.startOfDay
        while cursor <= limit {
            if occurs(on: cursor, calendar: calendar) { result.append(cursor) }
            cursor = cursor.adding(days: 1, calendar: calendar)
        }
        return result
    }

    /// "Every Tuesday" / "Every second Sunday", in the user's language.
    var scheduleDescription: String {
        let symbols = Calendar.current.standaloneWeekdaySymbols
        let index = min(max(weekday - 1, 0), symbols.count - 1)
        let name = symbols[index]
        switch max(1, intervalWeeks) {
        case 1: return String(localized: "Every \(name)")
        case 2: return String(localized: "Every second \(name)")
        case 3: return String(localized: "Every third \(name)")
        case 4: return String(localized: "Every fourth \(name)")
        default: return String(localized: "Every \(intervalWeeks) weeks on \(name)")
        }
    }

    /// Weekdays in the order the user's locale shows them.
    static var localeWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { ((first - 1 + $0) % 7) + 1 }
    }

    static func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.standaloneWeekdaySymbols
        return symbols[min(max(weekday - 1, 0), symbols.count - 1)]
    }
}
