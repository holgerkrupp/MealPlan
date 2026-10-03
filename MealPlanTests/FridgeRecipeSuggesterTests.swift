import Testing
@testable import MealPlan

@MainActor
struct FridgeRecipeSuggesterTests {
    private func dish(_ name: String, ingredients: [String]) -> Dish {
        let dish = Dish(name: name)
        dish.ingredients = ingredients.enumerated().map { index, name in
            let ingredient = Ingredient(name: name)
            let line = DishIngredient(sortIndex: index)
            line.ingredient = ingredient
            line.dish = dish
            return line
        }
        return dish
    }

    @Test func availableIngredientsRankAboveRecipesWithMoreMissingItems() {
        let pasta = dish("Pasta", ingredients: ["Tomatoes", "Pasta"])
        let soup = dish("Soup", ingredients: ["Tomatoes", "Carrots", "Stock"])
        let available = [Ingredient(name: "Tomatoes"), Ingredient(name: "Pasta")]

        let suggestions = FridgeRecipeSuggester.suggestions(
            dishes: [soup, pasta], available: available, useSoon: []
        )

        #expect(suggestions.first?.dish === pasta)
        #expect(suggestions.first?.missingIngredients.isEmpty == true)
    }

    @Test func useSoonIngredientsInfluenceRankingAndReasons() {
        let ordinary = dish("Tomato toast", ingredients: ["Tomatoes"])
        let soon = dish("Tomato pasta", ingredients: ["Tomatoes", "Pasta"])
        let tomatoes = Ingredient(name: "Tomatoes")
        let pasta = Ingredient(name: "Pasta")

        let suggestions = FridgeRecipeSuggester.suggestions(
            dishes: [ordinary, soon],
            available: [tomatoes, pasta],
            useSoon: [tomatoes]
        )

        #expect(suggestions.first?.dish === soon)
        #expect(suggestions.first?.useSoonIngredients == ["Tomatoes"])
    }

    @Test func noAvailableIngredientsProducesNoSuggestions() {
        let dish = dish("Pasta", ingredients: ["Tomatoes"])
        #expect(FridgeRecipeSuggester.suggestions(dishes: [dish], available: [], useSoon: []).isEmpty)
    }
}
