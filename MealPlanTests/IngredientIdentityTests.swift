import Foundation
import SwiftData
import Testing
@testable import MealPlan

@MainActor
struct IngredientIdentityTests {
    @Test func aKnownAliasResolvesToItsCanonicalIngredient() {
        let canonical = Ingredient(name: "Joghurt")
        let alias = IngredientAlias(name: "Jogurt", source: .userConfirmed, confidence: 1)
        alias.ingredient = canonical
        canonical.aliases = [alias]

        #expect(IngredientIdentity.resolve(named: "Jogurt", in: [canonical]) === canonical)
        #expect(IngredientMatching.match("Jogurt", in: [canonical]) === canonical)
    }

    @Test func fuzzyMatchingDoesNotChooseBetweenTwoCandidates() {
        let first = Ingredient(name: "Mehl")
        let second = Ingredient(name: "Mahl")

        #expect(IngredientMatching.match("Mihl", in: [first, second]) == nil)
    }

    @Test func manualChoiceCanRejectAnUncertainCandidate() throws {
        let container = SharedStore.make(cloudKit: false, inMemory: true)
        let context = container.mainContext
        let household = Household(name: "Home")
        let canonical = Ingredient(name: "Joghurt")
        household.ingredients = [canonical]
        canonical.household = household
        context.insert(household)
        context.insert(canonical)

        let separate = IngredientIdentity.upsert(
            named: "Jogurt",
            household: household,
            context: context,
            source: .userConfirmed,
            confidence: 1
        )
        #expect(separate !== canonical)
        #expect(separate.pendingMergeSuggestions.count == 1)

        IngredientIdentity.rejectMatch(named: "Jogurt", for: canonical, on: separate)
        #expect(separate.pendingMergeSuggestions.isEmpty)
        #expect(IngredientMatching.result(for: "Jogurt", in: [canonical]).matchClass == .noMatch)

        try context.save()
    }

    @Test func importedSpellingStaysFaithfulUntilConfirmedAndThenLearns() throws {
        let container = SharedStore.make(cloudKit: false, inMemory: true)
        let context = container.mainContext
        let household = Household(name: "Home")
        let canonical = Ingredient(name: "Joghurt")
        household.ingredients = [canonical]
        canonical.household = household
        context.insert(household)
        context.insert(canonical)

        var recipe = ImportedRecipe(name: "Breakfast")
        recipe.ingredientLines = ["200 g Jogurt (cremig)"]
        let dish = DishBuilder.makeDish(
            from: recipe,
            household: household,
            createdByName: nil,
            context: context
        )
        let line = try #require(dish.sortedIngredients.first)
        let imported = try #require(line.ingredient)
        #expect(imported !== canonical)
        #expect(line.rawText == "200 g Jogurt (cremig)")
        #expect(line.note == "cremig")
        #expect(imported.pendingMergeSuggestions.first?.candidateUUID == canonical.uuid)

        try IngredientIdentity.confirmMatch(
            newIngredient: imported,
            canonical: canonical,
            context: context
        )
        #expect(line.ingredient === canonical)
        #expect(line.rawText == "200 g Jogurt (cremig)")
        #expect(line.note == "cremig")
        #expect((canonical.aliases ?? []).contains { $0.normalizedName == "jogurt" })
        #expect(IngredientIdentity.upsert(named: "Jogurt", household: household, context: context) === canonical)
    }

    @Test func mergeRepointsRelationshipsAndKeepsCanonicalMetadata() throws {
        let container = SharedStore.make(cloudKit: false, inMemory: true)
        let context = container.mainContext
        let household = Household(name: "Home")
        let canonical = Ingredient(name: "Joghurt", category: .dairy)
        canonical.customAisleName = "Cold shelf"
        canonical.setNutrition(.init(energyKcal: 60, proteinGrams: 3.5, carbGrams: 4.7, fatGrams: 3.3))
        let duplicate = Ingredient(name: "Jogurt", category: .other)
        let dish = Dish(name: "Breakfast")
        let line = DishIngredient(canonicalValue: 200, dimension: .mass, rawText: "200 g Jogurt")
        let item = ShoppingListItem(name: "Jogurt", category: .other)

        household.ingredients = [canonical, duplicate]
        household.dishes = [dish]
        household.shoppingItems = [item]
        canonical.household = household
        duplicate.household = household
        dish.household = household
        item.household = household
        line.dish = dish
        line.ingredient = duplicate
        item.ingredient = duplicate
        context.insert(household)
        context.insert(canonical)
        context.insert(duplicate)
        context.insert(dish)
        context.insert(line)
        context.insert(item)
        try context.save()

        try IngredientMergeService.merge(duplicate: duplicate, into: canonical, context: context)

        let ingredients = try context.fetch(FetchDescriptor<Ingredient>())
        #expect(ingredients.count == 1)
        #expect(line.ingredient === canonical)
        #expect(item.ingredient === canonical)
        #expect(canonical.category == .dairy)
        #expect(canonical.customAisleName == "Cold shelf")
        #expect(canonical.nutritionFacts?.energyKcal == 60)
        #expect((canonical.aliases ?? []).contains { $0.normalizedName == "jogurt" })
    }
}
