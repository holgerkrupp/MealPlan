import Testing
import Foundation
@testable import MealPlan

/// The rules behind dragging a meal around the plan. `MealPlanner.dropPlan`
/// decides them without touching the store, so they can be checked here — see
/// the SwiftData note in `MealTypeDeduplicationTests`.
@MainActor
struct MealPlanDropTests {

    private let monday = DeepLink.parseDate("2026-09-14")!
    private var friday: Date { monday.adding(days: 4) }

    private func origin(_ date: Date, _ mealKey: String) -> MealPlanner.DropOrigin {
        MealPlanner.DropOrigin(date: date, mealKey: mealKey)
    }

    // MARK: - Dropping a planned meal on a meal card

    @Test func droppingOnAnotherMealMovesIt() {
        let plan = MealPlanner.dropPlan(
            from: origin(monday, "lunch"), onto: monday, mealKey: "dinner"
        )

        #expect(plan == .move(date: monday, mealKey: "dinner"))
    }

    @Test func droppingOnAnotherDayKeepsTheMealItWasDroppedOn() {
        let plan = MealPlanner.dropPlan(
            from: origin(monday, "lunch"), onto: friday, mealKey: "breakfast"
        )

        #expect(plan == .move(date: friday, mealKey: "breakfast"))
    }

    @Test func droppingBackWhereItStartedChangesNothing() {
        let plan = MealPlanner.dropPlan(
            from: origin(monday, "dinner"), onto: monday, mealKey: "dinner"
        )

        // Not `.move`: re-planning would push the meal to the end of the
        // card's order for a drag that went nowhere.
        #expect(plan == .unchanged)
    }

    @Test func dropTargetIsNormalisedToTheStartOfTheDay() {
        let lateOnFriday = friday.addingTimeInterval(21 * 3600)

        let plan = MealPlanner.dropPlan(
            from: origin(monday, "lunch"), onto: lateOnFriday, mealKey: "lunch"
        )

        #expect(plan == .move(date: friday, mealKey: "lunch"))
    }

    // MARK: - Dropping on a day as a whole (week strip, day header)

    @Test func droppingOnADayKeepsTheMealItWasPlannedIn() {
        let plan = MealPlanner.dropPlan(
            from: origin(monday, "breakfast"), onto: friday, mealKey: nil,
            defaultMealKey: "dinner"
        )

        #expect(plan == .move(date: friday, mealKey: "breakfast"))
    }

    @Test func droppingOnTheSameDayItAlreadySitsOnChangesNothing() {
        let plan = MealPlanner.dropPlan(
            from: origin(monday, "breakfast"), onto: monday, mealKey: nil
        )

        #expect(plan == .unchanged)
    }

    // MARK: - Dropping a dish from the library

    @Test func aDishDroppedOnAMealIsPlannedThere() {
        let plan = MealPlanner.dropPlan(from: nil, onto: friday, mealKey: "lunch")

        #expect(plan == .add(date: friday, mealKey: "lunch"))
    }

    @Test func aDishDroppedOnADayLandsInTheFirstMeal() {
        let plan = MealPlanner.dropPlan(
            from: nil, onto: friday, mealKey: nil, defaultMealKey: "breakfast"
        )

        #expect(plan == .add(date: friday, mealKey: "breakfast"))
    }

    @Test func aDishDroppedOnADayWithNoMealsAtAllIsRefused() {
        let plan = MealPlanner.dropPlan(from: nil, onto: friday, mealKey: nil)

        #expect(plan == .rejected)
    }
}
