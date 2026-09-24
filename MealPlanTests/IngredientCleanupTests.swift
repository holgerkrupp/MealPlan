import Foundation
import SwiftData
import Testing
@testable import MealPlan

@MainActor
struct IngredientCleanupTests {
    @Test func findsExistingDuplicateWithEvidenceAndRecipeExamples() throws {
        let container = SharedStore.make(cloudKit: false, inMemory: true)
        let context = container.mainContext
        let household = Household(name: "Home")
        let canonical = Ingredient(name: "Joghurt", category: .dairy)
        let duplicate = Ingredient(name: "Jogurt", category: .other)
        let dish = Dish(name: "Breakfast bowl")
        let line = DishIngredient(rawText: "200 g Jogurt")
        line.dish = dish
        line.ingredient = duplicate
        dish.ingredients = [line]
        household.ingredients = [canonical, duplicate]
        household.dishes = [dish]
        canonical.household = household
        duplicate.household = household
        dish.household = household
        context.insert(household)
        context.insert(canonical)
        context.insert(duplicate)
        context.insert(dish)
        context.insert(line)
        try context.save()

        let suggestion = try #require(IngredientCleanupService.suggestions(in: household).first)
        #expect(suggestion.canonical === canonical)
        #expect(suggestion.duplicate === duplicate)
        #expect(suggestion.duplicateDishes.map(\.name) == ["Breakfast bowl"])
        #expect(suggestion.categoryDiffers)
        #expect(suggestion.reasons.contains(.spellingDistance))
    }

    @Test func keepSeparatePersistsAndRemovesPairFromReview() throws {
        let container = SharedStore.make(cloudKit: false, inMemory: true)
        let context = container.mainContext
        let household = Household(name: "Home")
        let canonical = Ingredient(name: "Joghurt")
        let duplicate = Ingredient(name: "Jogurt")
        canonical.household = household
        duplicate.household = household
        household.ingredients = [canonical, duplicate]
        context.insert(household)
        context.insert(canonical)
        context.insert(duplicate)
        try context.save()

        let suggestion = try #require(IngredientCleanupService.suggestions(in: household).first)
        IngredientCleanupService.keepSeparate(suggestion)
        try context.save()

        #expect(IngredientCleanupService.suggestions(in: household).isEmpty)
        #expect(canonical.rejectsMatch(for: duplicate.name))
    }

    @Test func mergeCanRenameCanonicalAndKeepsRelationshipsUndoable() throws {
        let container = SharedStore.make(cloudKit: false, inMemory: true)
        let context = container.mainContext
        let household = Household(name: "Home")
        let canonical = Ingredient(name: "Joghurt")
        let duplicate = Ingredient(name: "Jogurt")
        let dish = Dish(name: "Breakfast")
        let line = DishIngredient(rawText: "Jogurt")
        line.dish = dish
        line.ingredient = duplicate
        dish.ingredients = [line]
        household.ingredients = [canonical, duplicate]
        household.dishes = [dish]
        canonical.household = household
        duplicate.household = household
        dish.household = household
        context.insert(household)
        context.insert(canonical)
        context.insert(duplicate)
        context.insert(dish)
        context.insert(line)
        try context.save()

        let suggestion = try #require(IngredientCleanupService.suggestions(in: household).first)
        try IngredientCleanupService.merge(suggestion, canonicalName: "Naturjoghurt", context: context)

        #expect(canonical.name == "Naturjoghurt")
        #expect(line.ingredient === canonical)
        #expect((canonical.aliases ?? []).contains { $0.normalizedName == "joghurt" })
        #expect(try context.fetch(FetchDescriptor<Ingredient>()).count == 1)
    }
}
