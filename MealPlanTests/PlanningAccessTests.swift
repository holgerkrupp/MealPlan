import Foundation
import Testing
@testable import MealPlan

struct PlanningAccessTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 9,
            day: 4,
            hour: 15
        ).date!
    }

    @Test("The free window includes today and seven days ahead")
    func freeWindow() {
        let seventhDay = calendar.date(byAdding: .day, value: 7, to: now)!
        #expect(PlanningAccess.canPlan(
            on: seventhDay,
            isUnlocked: false,
            now: now,
            calendar: calendar
        ))
    }

    @Test("The eighth future day is locked")
    func eighthDayIsLocked() {
        let eighthDay = calendar.date(byAdding: .day, value: 8, to: now)!
        #expect(!PlanningAccess.canPlan(
            on: eighthDay,
            isUnlocked: false,
            now: now,
            calendar: calendar
        ))
    }

    @Test("The unlock removes the planning horizon")
    func unlockRemovesHorizon() {
        let distantDate = calendar.date(byAdding: .year, value: 10, to: now)!
        #expect(PlanningAccess.canPlan(
            on: distantDate,
            isUnlocked: true,
            now: now,
            calendar: calendar
        ))
    }
}
