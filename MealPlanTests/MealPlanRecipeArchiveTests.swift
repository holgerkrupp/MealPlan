import Testing
import Foundation
@testable import MealPlan

@MainActor
struct MealPlanRecipeArchiveTests {
    @Test func roundTripsRecipeMetadataAndStructuredIngredients() throws {
        let dish = Dish(name: "Soup")
        dish.servings = 4
        dish.recipeText = "Simmer for 20 min"
        dish.isFavorite = true
        dish.rating = 5
        dish.collectionNames = ["Winter"]
        dish.dietaryTags = [.vegan]
        dish.season = .winter

        let ingredient = Ingredient(name: "Salt", category: .spices)
        ingredient.customAisleName = "Baking shelf"
        ingredient.isPantryStaple = true
        let line = DishIngredient(canonicalValue: 2, dimension: .mass, displayUnit: "g", rawText: "2 g salt")
        line.dish = dish
        line.ingredient = ingredient
        dish.ingredients = [line]
        let photo = DishImage(data: Data([1, 2, 3]), isPrimary: true)
        photo.dish = dish
        dish.images = [photo]

        let data = try MealPlanRecipeArchive.data(from: [dish])
        let imported = try #require(MealPlanRecipeArchive.importedRecipes(from: data).first)
        #expect(imported.name == "Soup")
        #expect(imported.isFavorite)
        #expect(imported.rating == 5)
        #expect(imported.collectionNames == ["Winter"])
        #expect(imported.dietaryTags == [.vegan])
        #expect(imported.season == .winter)
        #expect(imported.imageData == Data([1, 2, 3]))
        #expect(imported.structuredIngredients?.first?.category == .spices)
        #expect(imported.structuredIngredients?.first?.customAisleName == "Baking shelf")
        #expect(imported.structuredIngredients?.first?.isPantryStaple == true)
    }
}
