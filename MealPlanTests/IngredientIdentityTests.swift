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
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
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
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
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
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
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

    /// Regression for the Paprika incident: a structured import reused an
    /// existing exact ingredient, then overwrote the catalogue metadata used
    /// by an unrelated recipe.
    @Test func PaprikaImportNeverMutatesSharedIngredientMetadata() throws {
        IngredientIntegrityDiagnostics.resetForTesting()
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let context = container.mainContext
        let household = Household(name: "Home")
        let paprika = Ingredient(name: "Paprika", category: .produce)
        paprika.customAisleName = "Vegetables"
        paprika.isPantryStaple = false
        paprika.setNutrition(.init(energyKcal: 31, proteinGrams: 1, carbGrams: 6, fatGrams: 0.3))
        let unrelated = Dish(name: "Stuffed peppers")
        let unrelatedLine = DishIngredient(rawText: "2 Paprika")
        unrelatedLine.dish = unrelated
        unrelatedLine.ingredient = paprika
        household.ingredients = [paprika]
        household.dishes = [unrelated]
        paprika.household = household
        unrelated.household = household
        context.insert(household)
        context.insert(paprika)
        context.insert(unrelated)
        context.insert(unrelatedLine)
        try context.save()

        var imported = ImportedRecipe(name: "Paprika spice mix")
        imported.importedSourceApp = "Paprika"
        imported.structuredIngredients = [ImportedIngredient(
            name: "Paprika", category: .spices, customAisleName: "Spice rack", isPantryStaple: true,
            canonicalValue: 10, dimension: .mass, displayUnit: "g", isApproximate: false,
            note: nil, rawText: "10 g Paprika", nutrition: .init(energyKcal: 282), nutritionReference: .per100Grams
        )]
        let importedDish = DishBuilder.makeDish(from: imported, household: household, createdByName: nil, context: context)

        #expect(unrelatedLine.ingredient === paprika)
        #expect(importedDish.sortedIngredients.first?.ingredient === paprika)
        #expect(paprika.category == .produce)
        #expect(paprika.customAisleName == "Vegetables")
        #expect(!paprika.isPantryStaple)
        #expect(paprika.nutritionFacts?.energyKcal == 31)
        #expect(IngredientIntegrityDiagnostics.recent.contains { $0.kind == .ignoredImportedMetadataForExistingIngredient })
    }

    @Test func structuredImportInitializesOnlyItsNewIngredient() throws {
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let context = container.mainContext
        let household = Household(name: "Home")
        context.insert(household)
        try context.save()
        var imported = ImportedRecipe(name: "New recipe")
        imported.structuredIngredients = [ImportedIngredient(
            name: "Szechuan pepper", category: .spices, customAisleName: "Spice rack", isPantryStaple: true,
            canonicalValue: 5, dimension: .mass, displayUnit: "g", isApproximate: false,
            note: nil, rawText: "5 g Szechuan pepper", nutrition: .init(energyKcal: 251), nutritionReference: .per100Grams
        )]
        let dish = DishBuilder.makeDish(from: imported, household: household, createdByName: nil, context: context)
        let ingredient = try #require(dish.sortedIngredients.first?.ingredient)
        #expect(ingredient.category == .spices)
        #expect(ingredient.customAisleName == "Spice rack")
        #expect(ingredient.isPantryStaple)
        #expect(ingredient.nutritionFacts?.energyKcal == 251)
    }

    @Test func mergeHistoryCanRestoreTheDuplicateAndRelationships() throws {
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let context = container.mainContext
        let household = Household(name: "Home")
        let canonical = Ingredient(name: "Joghurt")
        let duplicate = Ingredient(name: "Jogurt", category: .dairy)
        let dish = Dish(name: "Breakfast")
        let line = DishIngredient(rawText: "Jogurt")
        line.dish = dish
        line.ingredient = duplicate
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

        try IngredientMergeService.merge(duplicate: duplicate, into: canonical, context: context)
        #expect(household.ingredientMergeAuditTrail.count == 1)
        let restored = try IngredientMergeService.reverseLatestMerge(in: household, context: context)
        #expect(restored.name == "Jogurt")
        #expect(restored.category == .dairy)
        #expect(line.ingredient === restored)
        #expect(household.ingredientMergeAuditTrail[0].revertedAt != nil)
    }

    @Test func mergeTransfersOnlyStockAndReverseRestoresBothInventoryRecords() throws {
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let context = container.mainContext
        let household = Household(name: "Home")
        let canonical = Ingredient(name: "Salz")
        let duplicate = Ingredient(name: "Salt")
        duplicate.isPantryStaple = true
        duplicate.markInventory(.have, quantity: .grams(300), bestBefore: Calendar.current.date(byAdding: .day, value: 5, to: .now))
        duplicate.storageLocation = .pantry
        duplicate.inventoryNote = "Opened"
        let dish = Dish(name: "Soup")
        let line = DishIngredient(canonicalValue: 500, dimension: .mass, rawText: "500 g Salt")
        line.dish = dish
        line.ingredient = duplicate
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

        try IngredientMergeService.merge(duplicate: duplicate, into: canonical, context: context)
        #expect(canonical.inventoryMode == .have)
        #expect(canonical.inventoryQuantity == .grams(300))
        #expect(canonical.storageLocation == .pantry)
        #expect(canonical.inventoryNote == "Opened")
        #expect(canonical.isPantryStaple)
        #expect(line.ingredient === canonical)

        let planned = AggregatedLine(name: "Salt", normalizedName: "salt", category: .spices, quantity: .grams(500))
        #expect(ShoppingListBuilder.subtractingInventory(planned, ingredient: canonical)?.quantity == .grams(200))

        let restored = try IngredientMergeService.reverseLatestMerge(in: household, context: context)
        #expect(restored.name == "Salt")
        #expect(restored.inventoryMode == .have)
        #expect(restored.inventoryQuantity == .grams(300))
        #expect(restored.storageLocation == .pantry)
        #expect(restored.inventoryNote == "Opened")
        #expect(canonical.inventoryMode == .none)
        #expect(!canonical.isPantryStaple)
        #expect(line.ingredient === restored)
    }

    @Test func stockConflictsRequireChoicesAndNeverSumAmounts() throws {
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let context = container.mainContext
        let household = Household(name: "Home")
        let canonical = Ingredient(name: "Salz")
        canonical.markInventory(.have, quantity: .grams(300))
        canonical.storageLocation = .pantry
        canonical.inventoryNote = "Unopened"
        let duplicate = Ingredient(name: "Salt")
        duplicate.markInventory(.low, quantity: .grams(500))
        duplicate.storageLocation = .freezer
        duplicate.inventoryNote = "Opened"
        household.ingredients = [canonical, duplicate]
        canonical.household = household
        duplicate.household = household
        context.insert(household)
        context.insert(canonical)
        context.insert(duplicate)
        try context.save()

        do {
            try IngredientMergeService.merge(duplicate: duplicate, into: canonical, context: context)
            Issue.record("A stock-conflicting merge should require explicit choices")
        } catch let error as IngredientMergeError {
            #expect(error == .stockConflictsUnresolved)
        }
        #expect(canonical.inventoryQuantity == .grams(300))
        #expect(household.ingredients?.count == 2)

        var choices = IngredientStockMergeChoices()
        choices[.status] = .duplicate
        choices[.amount] = .canonical
        choices[.location] = .duplicate
        choices[.note] = .canonical
        try IngredientMergeService.merge(duplicate: duplicate, into: canonical, stockChoices: choices, context: context)
        #expect(canonical.inventoryMode == .low)
        #expect(canonical.inventoryQuantity == .grams(300))
        #expect(canonical.storageLocation == .freezer)
        #expect(canonical.inventoryNote == "Unopened")
        #expect(household.ingredients?.count == 1)
    }
}
