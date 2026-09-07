import Testing
import Foundation
import SwiftData
@testable import MealPlan

@MainActor
struct DishFilterAndDuplicateTests {
    @Test func searchesIngredientsMethodAndTags() {
        let dish = Dish(name: "Family dinner")
        dish.recipeText = "Slowly caramelize everything"
        dish.tagNames = ["Weeknight"]
        let ingredient = Ingredient(name: "Red onion")
        let line = DishIngredient(rawText: "1 red onion")
        line.ingredient = ingredient
        line.dish = dish
        dish.ingredients = [line]

        var filter = DishFilter()
        filter.searchText = "onion"
        #expect(filter.apply(to: [dish]) == [dish])
        filter.searchText = "caramelize"
        #expect(filter.apply(to: [dish]) == [dish])
        filter.searchText = "weeknight"
        #expect(filter.apply(to: [dish]) == [dish])
    }

    @Test func favoriteRatingAndTagFiltersCombine() {
        let dish = Dish(name: "Soup")
        dish.isFavorite = true
        dish.rating = 4
        dish.tagNames = ["Winter"]
        var filter = DishFilter()
        filter.favoritesOnly = true
        filter.minimumRating = 4
        filter.tags = ["winter"]
        #expect(filter.apply(to: [dish]) == [dish])
        filter.minimumRating = 5
        #expect(filter.apply(to: [dish]).isEmpty)
    }

    @Test func duplicateDetectionUsesNameOrSource() {
        let existing = Dish(name: "Crème brûlée")
        existing.sourceURL = URL(string: "https://example.com/recipe")
        #expect(RecipeDuplicateDetector.match(
            name: "creme brulee", sourceURL: nil, in: [existing]
        ) === existing)
        #expect(RecipeDuplicateDetector.match(
            name: "Different", sourceURL: URL(string: "https://example.com/recipe"), in: [existing]
        ) === existing)
    }

    @Test func linkedRecipePhotoReplacesPrimaryAndKeepsAdditionalImages() {
        let container = SharedStore.make(cloudKit: false, inMemory: true)
        let context = container.mainContext
        let dish = Dish(name: "Soup")
        let oldPrimary = DishImage(data: Data([1]), sortIndex: 0, isPrimary: true)
        let additional = DishImage(data: Data([2]), sortIndex: 1, isPrimary: false)
        oldPrimary.dish = dish
        additional.dish = dish
        context.insert(dish)
        context.insert(oldPrimary)
        context.insert(additional)

        let assigned = DishBuilder.assignPrimaryImage(Data([9]), to: dish, context: context)

        #expect(assigned === oldPrimary)
        #expect(oldPrimary.data == Data([9]))
        #expect(oldPrimary.isPrimary)
        #expect(additional.data == Data([2]))
        #expect(dish.images?.count == 2)
    }
}
