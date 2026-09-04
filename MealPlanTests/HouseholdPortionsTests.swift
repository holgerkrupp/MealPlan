import Testing
import Foundation
@testable import MealPlan

/// The household's standard portion count, which scales every planned dish
/// without anyone touching the recipe's own yield.
@MainActor
struct HouseholdPortionsTests {

    private func dish(_ name: String, servings: Int) -> Dish {
        let dish = Dish(name: name)
        dish.servings = servings
        return dish
    }

    @Test func newHouseholdsStandardiseOnTwoPortions() {
        #expect(Household(name: "Krupp").standardServings == 2)
        #expect(Household(name: "Krupp").scalingServings == 2)
    }

    @Test func plannedMealsFollowTheHouseholdStandard() {
        let household = Household(name: "Krupp")
        household.standardServings = 6
        let entry = MealPlanEntry(date: .now, slot: .dinner, dish: dish("Bolognese", servings: 4))
        entry.household = household

        #expect(entry.effectiveServings == 6)
    }

    @Test func anOverrideBeatsTheStandardForThatOneMeal() {
        let household = Household(name: "Krupp")
        household.standardServings = 6
        let entry = MealPlanEntry(date: .now, slot: .dinner, dish: dish("Bolognese", servings: 4))
        entry.household = household
        entry.servingsOverride = 3

        #expect(entry.effectiveServings == 3)
    }

    @Test func aStandardOfZeroFallsBackToOnePortion() {
        let household = Household(name: "Krupp")
        household.standardServings = 0
        let entry = MealPlanEntry(date: .now, slot: .dinner, dish: dish("Suppe", servings: 4))
        entry.household = household

        #expect(entry.effectiveServings == 1)
    }

    @Test func withoutAHouseholdTheRecipeYieldStandsIn() {
        let entry = MealPlanEntry(date: .now, slot: .dinner, dish: dish("Suppe", servings: 4))
        #expect(entry.effectiveServings == 4)
    }
}
