import Foundation
import SwiftData

/// The things a household always has at home.
///
/// A staple is an ordinary `Ingredient` with `isPantryStaple` set, so marking
/// one costs nothing and every recipe line that already points at the
/// ingredient picks the flag up. Staples are skipped when the shopping list is
/// rebuilt from the plan — nobody wants salt on the list every week — but they
/// can still be put on it by hand on the day you run out. See
/// `ShoppingListBuilder.aggregate(_:)` for the first half of that and
/// `ShoppingListBuilder.addManualItem(for:household:context:)` for the second.
///
/// Which ingredients count is a household setting, shared with everyone in the
/// family, and lives in Household ▸ Pantry staples.
enum PantryStaples {

    /// One of the staples a new household starts with.
    struct Seed: Sendable, Equatable {
        var name: String
        var category: IngredientCategory
    }

    /// What a brand-new household starts with: the handful of things nearly
    /// every kitchen keeps open all the time. Seeded once, by
    /// `seedDefaults(for:context:)`.
    static var defaultSeeds: [Seed] {
        [
            Seed(name: String(localized: "Salt"), category: .spices),
            Seed(name: String(localized: "Pepper"), category: .spices),
            Seed(name: String(localized: "Water"), category: .drinks),
            Seed(name: String(localized: "Sugar"), category: .pantry),
            Seed(name: String(localized: "Flour"), category: .pantry),
            Seed(name: String(localized: "Cooking oil"), category: .pantry),
            Seed(name: String(localized: "Vinegar"), category: .pantry),
            Seed(name: String(localized: "Butter"), category: .dairy),
        ]
    }

    /// How to seed a set of staples into a catalogue that may already hold
    /// some of them.
    struct SeedPlan {
        /// Ingredients the household already knows; they only need the flag.
        var mark: [Ingredient] = []
        /// Staples with no catalogue entry yet.
        var create: [Seed] = []
    }

    /// Work out which seeds are already in `existing` — matched the way the
    /// rest of the app matches ingredients, through `IngredientMatching`, so a
    /// catalogue that already knows "Salz*" isn't given a second salt — and
    /// which have to be created.
    ///
    /// Pure, so it can be tested without a `ModelContext`.
    static func plan(_ seeds: [Seed] = PantryStaples.defaultSeeds, existing: [Ingredient]) -> SeedPlan {
        var result = SeedPlan()
        var claimed: Set<String> = []
        for seed in seeds {
            let normalized = Ingredient.normalize(seed.name)
            guard !normalized.isEmpty, claimed.insert(normalized).inserted else { continue }
            if let known = IngredientMatching.match(seed.name, in: existing) {
                result.mark.append(known)
            } else {
                result.create.append(seed)
            }
        }
        return result
    }

    /// Give a household the default staples, once. Later calls do nothing, so
    /// a staple the family cleared stays cleared.
    ///
    /// Only ever called for a household created on this device — an existing
    /// family's shopping list must not quietly lose ingredients on an update.
    @MainActor
    static func seedDefaults(for household: Household, context: ModelContext) {
        guard !household.didSeedPantryStaples else { return }
        household.didSeedPantryStaples = true

        let steps = plan(existing: household.ingredients ?? [])
        for ingredient in steps.mark {
            ingredient.isPantryStaple = true
        }
        for seed in steps.create {
            insert(seed, into: household, context: context)
        }
        try? context.save()
    }

    /// Mark `name` as a staple, re-using the household's catalogue entry when
    /// there already is one (an ingredient a recipe brought in) and creating
    /// it when there isn't. Returns the ingredient, or `nil` for a blank name.
    @MainActor
    @discardableResult
    static func add(
        named name: String,
        category: IngredientCategory = .other,
        to household: Household,
        context: ModelContext
    ) -> Ingredient? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let existing = match(trimmed, in: household.ingredients ?? []) {
            existing.isPantryStaple = true
            return existing
        }
        return insert(Seed(name: trimmed, category: category), into: household, context: context)
    }

    /// The household's catalogue entry for `name`, if it has one — including
    /// one spelled a little differently, so marking "Salz" a staple picks up
    /// the "Salz*" a recipe left behind rather than adding a second row.
    static func match(_ name: String, in ingredients: [Ingredient]) -> Ingredient? {
        IngredientMatching.match(name, in: ingredients)
    }

    @MainActor
    @discardableResult
    private static func insert(
        _ seed: Seed,
        into household: Household,
        context: ModelContext
    ) -> Ingredient {
        let ingredient = Ingredient(name: seed.name, category: seed.category)
        ingredient.isPantryStaple = true
        ingredient.household = household
        context.insert(ingredient)
        return ingredient
    }
}
