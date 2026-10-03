import SwiftData
import Testing
@testable import MealPlan

@MainActor
struct IngredientIntegrityAuditorTests {
    @Test func auditFindsOnlyMechanicalIssuesTheRepairWorkflowChanges() throws {
        let container = SharedStore.make(cloudKit: false, inMemory: true)
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
        let container = SharedStore.make(cloudKit: false, inMemory: true)
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
}
