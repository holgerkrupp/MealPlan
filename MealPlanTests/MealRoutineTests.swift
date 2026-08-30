import Testing
import Foundation
import SwiftData
@testable import MealPlan

@MainActor
@Suite(.serialized)
struct MealRoutineTests {

    /// Transient routines are enough — the occurrence logic is pure.
    private func routine(weekday: Int, every weeks: Int, from start: Date) -> MealRoutine {
        MealRoutine(mealKey: "dinner", weekday: weekday, intervalWeeks: weeks, startDate: start)
    }

    /// Monday-based calendar, so the tests don't change meaning with the
    /// runner's locale.
    private var calendar: Calendar { Date.mondayCalendar }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)!.startOfDay
    }

    @Test func weeklyRoutineHitsEveryMatchingWeekday() {
        // 2026-09-01 is a Tuesday.
        let taco = routine(weekday: 3, every: 1, from: date("2026-09-01"))
        #expect(taco.occurs(on: date("2026-09-01"), calendar: calendar))
        #expect(taco.occurs(on: date("2026-09-08"), calendar: calendar))
        #expect(taco.occurs(on: date("2026-09-15"), calendar: calendar))
        #expect(!taco.occurs(on: date("2026-09-02"), calendar: calendar))
    }

    @Test func fortnightlyRoutineSkipsTheWeekBetween() {
        let pizza = routine(weekday: 1, every: 2, from: date("2026-09-06")) // Sunday
        #expect(pizza.occurs(on: date("2026-09-06"), calendar: calendar))
        #expect(!pizza.occurs(on: date("2026-09-13"), calendar: calendar))
        #expect(pizza.occurs(on: date("2026-09-20"), calendar: calendar))
        #expect(!pizza.occurs(on: date("2026-09-27"), calendar: calendar))
    }

    @Test func nothingIsPlannedBeforeTheStartDate() {
        let taco = routine(weekday: 3, every: 1, from: date("2026-09-08"))
        #expect(!taco.occurs(on: date("2026-09-01"), calendar: calendar))
        #expect(taco.occurs(on: date("2026-09-08"), calendar: calendar))
    }

    @Test func pausedRoutineNeverOccurs() {
        let taco = routine(weekday: 3, every: 1, from: date("2026-09-01"))
        taco.isActive = false
        #expect(!taco.occurs(on: date("2026-09-01"), calendar: calendar))
    }

    @Test func occurrencesListsEveryMatchingDayInRange() {
        let pizza = routine(weekday: 1, every: 2, from: date("2026-09-06"))
        let days = pizza.occurrences(from: date("2026-09-01"), through: date("2026-10-04"), calendar: calendar)
        #expect(days == [date("2026-09-06"), date("2026-09-20"), date("2026-10-04")])
    }

    @Test func eatingOutEntriesDescribeThemselves() {
        let entry = MealPlanEntry(date: date("2026-09-06"), mealKey: "dinner")
        entry.isEatingOut = true
        #expect(entry.displayTitle == String(localized: "Eating out"))
        entry.placeName = "Pizzeria Roma"
        #expect(entry.displayTitle == "Pizzeria Roma")
        #expect(entry.placeCoordinate == nil)
        entry.placeLatitude = 52.5
        entry.placeLongitude = 13.4
        #expect(entry.placeCoordinate?.latitude == 52.5)
    }
}
