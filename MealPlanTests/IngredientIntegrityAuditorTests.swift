import Foundation
import SwiftData
import Testing
@testable import MealPlan

@MainActor
struct IngredientIntegrityAuditorTests {
    @Test func auditFindsOnlyMechanicalIssuesTheRepairWorkflowChanges() throws {
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let context = container.mainContext
        let household = Household(name: "Home")
        let ingredient = Ingredient(name: "Tomaten")
        ingredient.normalizedName = "stale"
        let alias = IngredientAlias(name: "Tomate")
        alias.normalizedName = "also stale"
        alias.ingredient = ingredient
        household.ingredients = [ingredient]
        ingredient.household = household
        context.insert(household)
        context.insert(ingredient)
        context.insert(alias)
        try context.save()

        let audit = IngredientIntegrityAuditor.audit(household: household)
        #expect(audit.issues.map(\.kind).contains(.normalizedNameMismatch))
        #expect(audit.issues.map(\.kind).contains(.aliasNormalizedNameMismatch))
        let repaired = try IngredientIntegrityRepairService.repairSafely(audit, in: household, context: context)
        #expect(repaired.repairedIssueIDs.count == 2)
        #expect(ingredient.normalizedName == "tomaten")
        #expect(alias.normalizedName == "tomate")
    }

    @Test func auditReportsDuplicateNamesButWillNotGuessAMerge() throws {
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let context = container.mainContext
        let household = Household(name: "Home")
        let first = Ingredient(name: "Salz")
        let second = Ingredient(name: "Salz")
        household.ingredients = [first, second]
        first.household = household
        second.household = household
        context.insert(household)
        context.insert(first)
        context.insert(second)

        let audit = IngredientIntegrityAuditor.audit(household: household)
        #expect(audit.issues.filter { $0.kind == .duplicateCanonicalName }.count == 2)
        let repaired = try IngredientIntegrityRepairService.repairSafely(audit, in: household, context: context)
        #expect(repaired.repairedIssueIDs.isEmpty)
        #expect(repaired.skippedIssueIDs.count == 2)
    }

    @Test func auditReportsDistinctIdenticalRecipeLinesAsReviewOnly() throws {
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let context = container.mainContext
        let household = Household(name: "Home")
        let salt = Ingredient(name: "Salt")
        let dish = Dish(name: "Soup")
        let first = DishIngredient(canonicalValue: 5, dimension: .mass, displayUnit: "g", rawText: "5 g salt")
        let second = DishIngredient(canonicalValue: 5, dimension: .mass, displayUnit: "g", rawText: "5 g salt")
        first.dish = dish
        second.dish = dish
        first.ingredient = salt
        second.ingredient = salt
        dish.ingredients = [first, second]
        household.dishes = [dish]
        household.ingredients = [salt]
        dish.household = household
        salt.household = household
        context.insert(household)
        context.insert(salt)
        context.insert(dish)
        context.insert(first)
        context.insert(second)
        try context.save()

        let audit = IngredientIntegrityAuditor.audit(household: household, context: context)
        let duplicate = try #require(audit.issues.first { $0.kind == .duplicateDishIngredientContent })
        #expect(duplicate.classification == .reviewRecommended)
        #expect(!duplicate.isSafeToRepair)
        #expect(duplicate.relatedDishIngredientUUIDs.count == 2)
        #expect(audit.safeRecipeRepairs.isEmpty)
    }

    @Test func rawTextMismatchCanBeReviewedWithoutChangingQuantityOrSourceText() throws {
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let context = container.mainContext
        let household = Household(name: "Home")
        let beef = Ingredient(name: "Ground beef")
        let pork = Ingredient(name: "Pork neck")
        let dish = Dish(name: "Chili")
        let line = DishIngredient(canonicalValue: 500, dimension: .mass, displayUnit: "g", rawText: "500 g ground beef")
        line.dish = dish
        line.ingredient = pork
        dish.ingredients = [line]
        household.dishes = [dish]
        household.ingredients = [beef, pork]
        dish.household = household
        beef.household = household
        pork.household = household
        context.insert(household)
        context.insert(beef)
        context.insert(pork)
        context.insert(dish)
        context.insert(line)
        try context.save()

        let audit = IngredientIntegrityAuditor.audit(household: household, context: context)
        let mismatch = try #require(audit.issues.first { $0.kind == .dishIngredientRawTextMismatch })
        #expect(mismatch.suggestedIngredientUUID == beef.uuid)
        #expect(mismatch.classification == .reviewRecommended)

        try IngredientIntegrityRepairService.reassignRecipeLine(line, to: beef, context: context)
        #expect(line.ingredient === beef)
        #expect(line.rawText == "500 g ground beef")
        #expect(line.canonicalValue == 500)
        #expect(line.dimension == .mass)
    }

    @Test func reviewedDuplicateLineRemovalDoesNotRewriteTheIngredientCatalogue() throws {
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let context = container.mainContext
        let household = Household(name: "Home")
        let salt = Ingredient(name: "Salt")
        let dish = Dish(name: "Soup")
        let line = DishIngredient(canonicalValue: 5, dimension: .mass, displayUnit: "g", rawText: "5 g salt")
        line.dish = dish
        line.ingredient = salt
        dish.ingredients = [line]
        household.dishes = [dish]
        household.ingredients = [salt]
        dish.household = household
        salt.household = household
        context.insert(household)
        context.insert(salt)
        context.insert(dish)
        context.insert(line)
        try context.save()

        try IngredientIntegrityRepairService.removeReviewedDuplicateLine(line, from: dish, context: context)
        #expect((household.ingredients ?? []).first === salt)
        #expect(salt.name == "Salt")
        #expect(try context.fetch(FetchDescriptor<DishIngredient>()).isEmpty)
    }
}
