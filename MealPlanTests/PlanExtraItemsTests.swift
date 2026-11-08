import Testing
import Foundation
import SwiftData
@testable import MealPlan

/// Ad-hoc items attached to a planned meal ("bread, drinks") and how they
/// reach the shopping list, backups and sync. Transient model objects only.
@MainActor
@Suite(.serialized)
struct PlanExtraItemsTests {

    private func dish(_ name: String, servings: Int = 4) -> Dish {
        let d = Dish(name: name)
        d.servings = servings
        return d
    }

    private func line(_ dish: Dish, _ name: String, _ value: Double, _ dimension: QuantityDimension) {
        let item = DishIngredient(canonicalValue: value, dimension: dimension, sortIndex: dish.ingredients?.count ?? 0)
        item.ingredient = Ingredient(name: name)
        var existing = dish.ingredients ?? []
        existing.append(item)
        dish.ingredients = existing
        item.dish = dish
    }

    // MARK: - The entry

    @Test func extraItemsAreStoredAsTrimmedLines() {
        let entry = MealPlanEntry(date: .now, mealKey: "dinner")
        #expect(entry.extraItems.isEmpty)
        entry.extraItems = ["  Baguette ", "", "2 l Apfelschorle"]
        #expect(entry.extraItemsText == "Baguette\n2 l Apfelschorle")
        #expect(entry.extraItems == ["Baguette", "2 l Apfelschorle"])
        entry.extraItems = []
        #expect(entry.extraItemsText == nil)
    }

    // MARK: - Shopping list

    @Test func extrasReachTheShoppingListWithoutAnyRecipe() {
        let entry = MealPlanEntry(date: .now, mealKey: "dinner")
        entry.isEatingOut = true
        entry.placeName = "Picknick"
        entry.extraItems = ["Baguette", "2 l Apfelschorle"]

        let lines = ShoppingListBuilder.aggregate([entry])
        #expect(lines.count == 2)
        let schorle = lines.first { $0.name == "Apfelschorle" }
        #expect(schorle?.quantity == Quantity(value: 2000, dimension: .volume))
        let baguette = lines.first { $0.name == "Baguette" }
        #expect(baguette?.quantity == nil)
        #expect(baguette?.unmeasuredCount == 1)
        #expect(baguette?.sourceDishNames == ["Picknick"])
    }

    @Test func extrasAreNotScaledByTheHeadCount() {
        let soup = dish("Suppe", servings: 2)
        line(soup, "Karotten", 500, .mass)
        let entry = MealPlanEntry(date: .now, mealKey: "dinner", dish: soup)
        entry.servingsOverride = 8
        entry.extraItems = ["1 Brot"]

        let lines = ShoppingListBuilder.aggregate([entry])
        #expect(lines.first { $0.name == "Karotten" }?.quantity == Quantity(value: 2000, dimension: .mass))
        #expect(lines.first { $0.name == "Brot" }?.quantity == Quantity(value: 1, dimension: .count))
    }

    @Test func anExtraMergesIntoTheRecipesLineForTheSameIngredient() {
        let soup = dish("Suppe", servings: 4)
        line(soup, "Brot", 200, .mass)
        let entry = MealPlanEntry(date: .now, mealKey: "dinner", dish: soup)
        entry.extraItems = ["100 g Brot"]

        let lines = ShoppingListBuilder.aggregate([entry])
        #expect(lines.count == 1)
        #expect(lines[0].quantity == Quantity(value: 300, dimension: .mass))
        #expect(lines[0].sourceDishNames == ["Suppe"])
    }

    @Test func extrasOfASkippedMealAreLeftOff() {
        let entry = MealPlanEntry(date: .now, mealKey: "dinner")
        entry.extraItems = ["Wein"]
        entry.skipped = true
        #expect(ShoppingListBuilder.aggregate([entry]).isEmpty)
    }

    @Test func anExtraTakesItsAisleFromTheCatalogue() {
        let entry = MealPlanEntry(date: .now, mealKey: "dinner")
        entry.extraItems = ["Baguette"]
        let known = Ingredient(name: "Baguette", category: .bakery)

        let lines = ShoppingListBuilder.aggregate([entry], catalogue: [known])
        #expect(lines.first?.category == .bakery)
    }

    // MARK: - Backup and sync

    @Test func extrasSurviveABackupRoundTrip() throws {
        let household = Household(name: "Krupp")
        let entry = MealPlanEntry(date: Date(timeIntervalSince1970: 1_770_000_000), mealKey: "dinner")
        entry.extraItems = ["Baguette", "Wein"]
        entry.household = household

        var rows = MealPlanBackup.StoreRows()
        rows.households = [household]
        rows.entries = [entry]
        let data = try MealPlanBackup.encode(MealPlanBackup.make(from: rows))
        let restored = try MealPlanBackup.decode(data)

        #expect(restored.entries.first?.extraItemsText == "Baguette\nWein")
    }

    @Test func aPlanEntryFromBeforeExtraItemsStillDecodes() throws {
        let data = Data("""
        {"uuid":"00000000-0000-0000-0000-000000000001",\
        "date":"2026-10-15T00:00:00Z","mealKey":"dinner",\
        "sortIndex":0,"skipped":false,"prepReminder":false,"isEatingOut":false}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(MealPlanBackup.PortableEntry.self, from: data)
        #expect(entry.extraItemsText == nil)
    }

    @Test func extrasTravelInTheSyncPayload() throws {
        let entry = MealPlanEntry(date: .now, mealKey: "dinner")
        entry.extraItems = ["Baguette"]
        let payload = HouseholdRecordPayload.planEntry(PlanEntryPayload(
            value: HouseholdRecordCodec.portableEntry(entry),
            placementModifiedAt: entry.placementModifiedAt,
            contentModifiedAt: entry.contentModifiedAt
        ))

        let decoded = try HouseholdRecordCodec.decode(HouseholdRecordCodec.encode(payload))
        guard case .planEntry(let wrapped) = decoded else {
            Issue.record("Expected a plan entry payload")
            return
        }
        #expect(wrapped.value.extraItemsText == "Baguette")
    }

    @Test func extendedStatedNutritionTravelsInTheSyncPayload() throws {
        let d = dish("Importiert")
        d.setStatedNutritionPerServing(
            NutritionFacts(energyKcal: 500, saturatedFatGrams: 4, sodiumMilligrams: 600),
            provenance: .manuallyEntered
        )
        let portable = HouseholdRecordCodec.portableDish(d)
        #expect(portable.statedSaturatedFatGramsPerServing == 4)
        #expect(portable.statedSodiumMilligramsPerServing == 600)
        #expect(portable.statedNutritionProvenanceRaw == RecipeNutritionProvenance.manuallyEntered.rawValue)
    }
}
