import Foundation
import SwiftData
import Testing
@testable import MealPlan

@MainActor
struct IngredientCleanupTests {
    @Test func findsExistingDuplicateWithEvidenceAndRecipeExamples() throws {
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
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
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
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
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
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

    @Test func bilingualDuplicateGroupUsesOneCanonicalAndBatchLeavesOneRow() throws {
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let context = container.mainContext
        let household = Household(name: "Home")
        let salt = Ingredient(name: "Salt")
        salt.modifiedAt = Date(timeIntervalSince1970: 1)
        let duplicates = (0..<3).map { index -> Ingredient in
            let ingredient = Ingredient(name: "Salz")
            ingredient.modifiedAt = Date(timeIntervalSince1970: TimeInterval(index + 2))
            return ingredient
        }
        household.ingredients = [salt] + duplicates
        for ingredient in household.ingredients ?? [] {
            ingredient.household = household
            context.insert(ingredient)
        }
        context.insert(household)
        try context.save()

        let suggestions = IngredientCleanupService.suggestions(in: household)
        #expect(suggestions.count == 3)
        #expect(suggestions.allSatisfy { $0.canonical === salt })
        #expect(IngredientCleanupService.highConfidenceNonConflicting(in: household).count == 3)

        for suggestion in IngredientCleanupService.highConfidenceNonConflicting(in: household) {
            try IngredientCleanupService.merge(suggestion, context: context)
        }
        #expect(try context.fetch(FetchDescriptor<Ingredient>()).count == 1)
        #expect((salt.aliases ?? []).contains { $0.normalizedName == "salz" })
    }

    @Test func automaticReconciliationIsBoundedAndIdempotentlyMergesExactAndMarkedNames() throws {
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let context = container.mainContext
        let household = Household(name: "Home")
        let canonical = Ingredient(name: "Butter")
        canonical.uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let exactDuplicate = Ingredient(name: "butter")
        exactDuplicate.uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let markedDuplicate = Ingredient(name: "Butter* ")
        markedDuplicate.uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let doubleMarked = Ingredient(name: "Butter**")
        doubleMarked.uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let dish = Dish(name: "Butter toast")
        let line = DishIngredient(rawText: "Butter* on toast")
        line.dish = dish
        line.ingredient = markedDuplicate
        dish.ingredients = [line]
        household.ingredients = [canonical, exactDuplicate, markedDuplicate, doubleMarked]
        household.dishes = [dish]
        for ingredient in household.ingredients ?? [] {
            ingredient.household = household
            context.insert(ingredient)
        }
        dish.household = household
        context.insert(household)
        context.insert(dish)
        context.insert(line)
        try context.save()

        #expect(try IngredientCleanupService.reconcileObviousDuplicates(in: household, context: context, limit: 1) == 1)
        #expect((household.ingredients ?? []).contains(where: { $0 === canonical }))
        #expect((household.ingredients ?? []).contains(where: { $0 === markedDuplicate }))

        #expect(try IngredientCleanupService.reconcileObviousDuplicates(in: household, context: context, limit: 1) == 1)
        #expect(line.ingredient === canonical)
        #expect((canonical.aliases ?? []).contains { $0.normalizedName == Ingredient.normalize(markedDuplicate.name) })
        #expect((household.ingredients ?? []).contains(where: { $0 === doubleMarked }))
        #expect(try IngredientCleanupService.reconcileObviousDuplicates(in: household, context: context) == 0)
    }

    @Test func automaticReconciliationLeavesSeparateMetadataAndInventoryForReview() throws {
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let context = container.mainContext
        let household = Household(name: "Home")

        let stockCanonical = Ingredient(name: "Milk")
        let stockDuplicate = Ingredient(name: "Milk")
        stockCanonical.inventoryMode = .have
        stockDuplicate.inventoryMode = .have
        stockCanonical.inventoryQuantity = Quantity(value: 1, dimension: .volume)
        stockDuplicate.inventoryQuantity = Quantity(value: 2, dimension: .volume)

        let metadataCanonical = Ingredient(name: "Oil", category: .other)
        let metadataDuplicate = Ingredient(name: "Oil", category: .dairy)

        let singleStockCanonical = Ingredient(name: "Sugar")
        let singleStockDuplicate = Ingredient(name: "Sugar")
        singleStockCanonical.inventoryMode = .have

        let separateCanonical = Ingredient(name: "Salt")
        let separateDuplicate = Ingredient(name: "Salt")
        IngredientIdentity.rejectMatch(named: separateDuplicate.name, for: separateCanonical, on: separateDuplicate)

        let bilingualOne = Ingredient(name: "Salz")
        let bilingualTwo = Ingredient(name: "Salt")
        household.ingredients = [
            stockCanonical, stockDuplicate, metadataCanonical, metadataDuplicate,
            singleStockCanonical, singleStockDuplicate, separateCanonical, separateDuplicate,
            bilingualOne, bilingualTwo,
        ]
        for ingredient in household.ingredients ?? [] {
            ingredient.household = household
            context.insert(ingredient)
        }
        context.insert(household)
        try context.save()

        #expect(try IngredientCleanupService.reconcileObviousDuplicates(in: household, context: context) == 0)
        #expect((household.ingredients ?? []).count == 10)
        #expect(stockCanonical.inventoryQuantity?.value == 1)
        #expect(stockDuplicate.inventoryQuantity?.value == 2)
    }

    @Test func confirmedDeleteKeepsRecipeAndShoppingValuesButUnlinksThem() throws {
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let context = container.mainContext
        let household = Household(name: "Home")
        let canonical = Ingredient(name: "Butter")
        let duplicate = Ingredient(name: "Butter*")
        let dish = Dish(name: "Toast")
        let line = DishIngredient(
            canonicalValue: 125,
            dimension: .mass,
            displayUnit: "g",
            rawText: "Butter* 125 g"
        )
        line.dish = dish
        line.ingredient = duplicate
        dish.ingredients = [line]
        let item = ShoppingListItem(name: "Butter*", isManual: true)
        item.canonicalValue = 125
        item.dimension = .mass
        item.displayText = "125 g"
        item.isChecked = true
        item.ingredient = duplicate
        item.household = household
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
        context.insert(item)
        try context.save()

        let match = IngredientMatching.result(for: duplicate.name, in: [canonical])
        let suggestion = IngredientCleanupSuggestion(canonical: canonical, duplicate: duplicate, match: match)
        try IngredientCleanupService.deleteDuplicateKeepingUnlinkedUses(suggestion, context: context)

        #expect((household.ingredients ?? []).count == 1)
        #expect((household.ingredients ?? []).first === canonical)
        #expect(line.ingredient == nil)
        #expect(line.rawText == "Butter* 125 g")
        #expect(line.canonicalValue == 125)
        #expect(item.ingredient == nil)
        #expect(item.name == "Butter*")
        #expect(item.canonicalValue == 125)
        #expect(item.displayText == "125 g")
        #expect(item.isChecked)
    }
}
