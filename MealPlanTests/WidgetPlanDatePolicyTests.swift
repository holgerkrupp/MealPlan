import Foundation
import Testing
@testable import MealPlan

struct WidgetPlanDatePolicyTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    @Test func todayWidgetChangesLeadingDayAtEveningRollover() {
        let base = date(23, hour: 10)
        #expect(WidgetPlanDatePolicy.todayIndex(
            at: date(23, hour: 17), relativeTo: base, rolloverHour: 18, calendar: calendar
        ) == 0)
        #expect(WidgetPlanDatePolicy.todayIndex(
            at: date(23, hour: 18), relativeTo: base, rolloverHour: 18, calendar: calendar
        ) == 1)
        #expect(WidgetPlanDatePolicy.todayIndex(
            at: date(24, hour: 0), relativeTo: base, rolloverHour: 18, calendar: calendar
        ) == 1)
    }

    @Test func unavailablePlanIsNotReportedAsEmpty() {
        #expect(WidgetPlanContentState.resolve(availability: .unavailable, hasMeals: false) == .unavailable)
        #expect(WidgetPlanContentState.resolve(availability: .available, hasMeals: false) == .empty)
        #expect(WidgetPlanContentState.resolve(availability: .available, hasMeals: true) == .planned)
    }
}
