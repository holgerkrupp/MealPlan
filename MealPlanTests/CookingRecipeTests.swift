import Testing
@testable import MealPlan

struct CookingRecipeTests {
    @Test func splitsStepsAndRemovesNumbers() {
        let steps = CookingRecipe.steps(from: "1. Chop onions\n\n2) Simmer for 20 min")
        #expect(steps.map(\.text) == ["Chop onions", "Simmer for 20 min"])
        #expect(steps[1].timers.first?.duration == 1_200)
    }

    @Test func findsGermanAndMixedTimers() {
        let timers = CookingRecipe.timers(in: "1 Stunde backen, dann 30 Sekunden ruhen")
        #expect(timers.map(\.duration) == [3_600, 30])
    }
}
