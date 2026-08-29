import Testing
import Foundation
import SwiftData
@testable import MealPlan

@MainActor
@Suite(.serialized)
struct ShoppingListBuilderTests {

    // Transient model objects (no ModelContext) are enough for the pure
    // aggregation logic.

    private func dish(_ name: String, servings: Int) -> Dish {
        let d = Dish(name: name)
        d.servings = servings
        return d
    }

    private func line(
        _ dish: Dish, _ ingredientName: String, _ value: Double, _ dim: QuantityDimension,
        category: IngredientCategory = .other
    ) {
        let ing = Ingredient(name: ingredientName, category: category)
        let li = DishIngredient(canonicalValue: value, dimension: dim, sortIndex: dish.ingredients?.count ?? 0)
        li.ingredient = ing
        var existing = dish.ingredients ?? []
        existing.append(li)
        dish.ingredients = existing
        li.dish = dish
    }

    @Test func sumsSameIngredientAcrossMeals() {
        let a = dish("Pfannkuchen", servings: 4)
        line(a, "Mehl", 250, .mass)
        let b = dish("Waffeln", servings: 4)
        line(b, "Mehl", 300, .mass)

        let lines = ShoppingListBuilder.aggregate([
            MealPlanEntry(date: .now, slot: .breakfast, dish: a),
            MealPlanEntry(date: .now, slot: .dinner, dish: b),
        ])
        #expect(lines.count == 1)
        #expect(lines[0].name == "Mehl")
        #expect(lines[0].quantity == Quantity(value: 550, dimension: .mass))
    }

    @Test func scalesToPlannedServings() {
        let d = dish("Bolognese", servings: 4)
        line(d, "Hackfleisch", 500, .mass)
        let entry = MealPlanEntry(date: .now, slot: .dinner, dish: d)
        entry.servingsOverride = 6 // 1.5×
        #expect(ShoppingListBuilder.aggregate([entry])[0].quantity == Quantity(value: 750, dimension: .mass))
    }

    @Test func skippedEntriesAreIgnored() {
        let d = dish("Suppe", servings: 2)
        line(d, "Kürbis", 800, .mass)
        let entry = MealPlanEntry(date: .now, slot: .dinner, dish: d)
        entry.skipped = true
        #expect(ShoppingListBuilder.aggregate([entry]).isEmpty)
    }

    @Test func groupsAndSortsByCategory() {
        let d = dish("Salat", servings: 2)
        line(d, "Tomate", 3, .count, category: .produce)
        line(d, "Öl", 30, .volume, category: .pantry)
        let lines = ShoppingListBuilder.aggregate([MealPlanEntry(date: .now, slot: .lunch, dish: d)])
        #expect(lines.count == 2)
        #expect(lines.first?.category == .produce) // produce sorts before pantry
    }

    @Test func unmeasuredIngredientsAreCounted() {
        let d = dish("Nudeln", servings: 2)
        let salt = Ingredient(name: "Salz", category: .spices)
        let li = DishIngredient(note: "nach Geschmack", rawText: "Salz nach Geschmack")
        li.ingredient = salt
        li.dish = d
        d.ingredients = [li]
        let lines = ShoppingListBuilder.aggregate([MealPlanEntry(date: .now, slot: .dinner, dish: d)])
        #expect(lines.count == 1)
        #expect(lines[0].quantity == nil)
        #expect(lines[0].unmeasuredCount == 1)
    }

    @Test func displayTextForApproximateVolume() {
        let l = AggregatedLine(
            name: "Olivenöl", normalizedName: "olivenol", category: .pantry,
            quantity: Quantity(value: 45, dimension: .volume), displayUnit: "EL", isApproximate: true
        )
        let text = ShoppingListBuilder.displayText(for: l, system: .metric, locale: Locale(identifier: "de_DE"))
        #expect(text.contains("≈"))
        #expect(text.contains("ml"))
    }

    @Test func displayTextHonorsExactAmountPreference() {
        let line = AggregatedLine(
            name: "Eggs", normalizedName: "eggs", category: .dairy,
            quantity: Quantity(value: 2.75, dimension: .count)
        )

        let rounded = ShoppingListBuilder.displayText(
            for: line,
            system: .metric,
            locale: Locale(identifier: "en_US")
        )
        let exact = ShoppingListBuilder.displayText(
            for: line,
            system: .metric,
            roundsAmounts: false,
            locale: Locale(identifier: "en_US")
        )

        #expect(rounded == "≈ 3 ×")
        #expect(exact == "2.75 ×")
    }

    @Test func pantryStaplesAreExcluded() {
        let d = dish("Pasta", servings: 2)
        line(d, "Salt", 2, .mass, category: .spices)
        d.sortedIngredients.first?.ingredient?.isPantryStaple = true
        let lines = ShoppingListBuilder.aggregate([MealPlanEntry(date: .now, slot: .dinner, dish: d)])
        #expect(lines.isEmpty)
    }
}
