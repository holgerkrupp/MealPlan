import Testing
import Foundation
@testable import MealPlan

/// The staple rules a household depends on: what a new family starts with,
/// how seeding meets a catalogue that already has some of it, and that a
/// staple stays off a rebuilt shopping list while a hand-added line stays on.
///
/// Everything here runs on transient model objects — standing up a
/// `ModelContainer` inside the app test host crashes it, which is why the
/// seeding logic is split into the pure `PantryStaples.plan(_:existing:)` the
/// `ModelContext` half then applies.
@MainActor
struct PantryStaplesTests {

    private func ingredient(_ name: String, staple: Bool = false) -> Ingredient {
        let ingredient = Ingredient(name: name)
        ingredient.isPantryStaple = staple
        return ingredient
    }

    // MARK: - The default set

    @Test func defaultsCoverTheEverydayThings() {
        let names = PantryStaples.defaultSeeds.map { Ingredient.normalize($0.name) }
        #expect(names.contains(Ingredient.normalize(String(localized: "Salt"))))
        #expect(names.contains(Ingredient.normalize(String(localized: "Pepper"))))
        #expect(names.contains(Ingredient.normalize(String(localized: "Water"))))
    }

    @Test func defaultsDontRepeatThemselves() {
        let names = PantryStaples.defaultSeeds.map { Ingredient.normalize($0.name) }
        #expect(Set(names).count == names.count)
        #expect(!names.contains(""))
    }

    // MARK: - Seeding

    @Test func seedsEverythingIntoAnEmptyCatalogue() {
        let plan = PantryStaples.plan(existing: [])
        #expect(plan.mark.isEmpty)
        #expect(plan.create.count == PantryStaples.defaultSeeds.count)
    }

    @Test func reusesAnIngredientTheRecipesAlreadyBroughtIn() {
        let salt = ingredient(String(localized: "Salt"))
        let plan = PantryStaples.plan(existing: [salt, ingredient("Hackfleisch")])

        #expect(plan.mark.count == 1)
        #expect(plan.mark.first === salt)
        #expect(plan.create.count == PantryStaples.defaultSeeds.count - 1)
        // Nothing is flagged by planning alone; that's the caller's half.
        #expect(!salt.isPantryStaple)
    }

    @Test func matchesRegardlessOfCaseAccentsAndSpacing() {
        let seeds = [PantryStaples.Seed(name: "Crème fraîche", category: .dairy)]
        let existing = ingredient("creme fraiche")
        #expect(PantryStaples.plan(seeds, existing: [existing]).create.isEmpty)

        let oil = ingredient("  Olivenöl  ")
        #expect(PantryStaples.match("OLIVENÖL", in: [oil]) === oil)
        #expect(PantryStaples.match("   ", in: [oil]) == nil)
    }

    @Test func seedsOnlyOncePerName() {
        let seeds = [
            PantryStaples.Seed(name: "Salz", category: .spices),
            PantryStaples.Seed(name: "salz", category: .other),
        ]
        #expect(PantryStaples.plan(seeds, existing: []).create.count == 1)
    }

    // MARK: - What reaches the shopping list

    @Test func staplesAreLeftOutWhenTheListIsRebuilt() {
        let dish = Dish(name: "Nudeln")
        dish.servings = 2
        let salt = ingredient("Salz", staple: true)
        let pasta = ingredient("Nudeln")
        for (index, item) in [salt, pasta].enumerated() {
            let line = DishIngredient(canonicalValue: 200, dimension: .mass, sortIndex: index)
            line.ingredient = item
            line.dish = dish
            dish.ingredients = (dish.ingredients ?? []) + [line]
        }

        let lines = ShoppingListBuilder.aggregate([MealPlanEntry(date: .now, slot: .dinner, dish: dish)])
        #expect(lines.map(\.name) == ["Nudeln"])
    }
}
