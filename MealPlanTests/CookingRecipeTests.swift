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

    @Test func groupsIngredientsWithTheirFirstMentionedStep() {
        let steps = CookingRecipe.steps(from: "Chop the onions\nHeat olive oil\nAdd tomatoes and simmer")
        let groups = CookingRecipe.ingredientGroups(
            ingredientNames: ["Olive oil", "Onion", "Tomato", "Salt"],
            steps: steps
        )

        #expect(groups == [
            CookingIngredientGroup(stepID: 0, ingredientIndexes: [1]),
            CookingIngredientGroup(stepID: 1, ingredientIndexes: [0]),
            CookingIngredientGroup(stepID: 2, ingredientIndexes: [2]),
            CookingIngredientGroup(stepID: nil, ingredientIndexes: [3]),
        ])
    }

    @Test func ingredientMatchingUsesWholeWords() {
        let steps = CookingRecipe.steps(from: "Boil the water")
        let groups = CookingRecipe.ingredientGroups(ingredientNames: ["Oil"], steps: steps)

        #expect(groups == [CookingIngredientGroup(stepID: nil, ingredientIndexes: [0])])
    }

    @Test func ingredientMatchingHandlesGermanPlurals() {
        let steps = CookingRecipe.steps(from: "Zwiebeln fein schneiden")
        let groups = CookingRecipe.ingredientGroups(ingredientNames: ["Zwiebel"], steps: steps)

        #expect(groups == [CookingIngredientGroup(stepID: 0, ingredientIndexes: [0])])
    }
}
