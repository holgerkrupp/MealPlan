import Foundation
import SwiftData

/// The `ModelContext` half of the Pantry screen. Every edit stamps the
/// ingredient's `modifiedAt` so household sync carries it, and starting to
/// track anything switches the household's inventory on — the same switch
/// "I have this" on the shopping list flips — so the list rebuild subtracts
/// what is at home.
@MainActor
enum PantryActions {

    static func canEdit(_ household: Household?, isGuest: Bool) -> Bool {
        !isGuest && household != nil && HouseholdMutationAuthorization.canMutate(household: household)
    }

    /// Save after an edit made directly on `ingredient`.
    static func commit(_ ingredient: Ingredient, household: Household?, context: ModelContext) {
        ingredient.modifiedAt = .now
        if ingredient.inventoryMode != .none, let household, !household.inventoryEnabled {
            household.inventoryEnabled = true
        }
        try? context.save()
    }

    static func setMode(_ mode: InventoryMode, for ingredient: Ingredient, household: Household?, context: ModelContext) {
        PantryInventory.setMode(mode, for: ingredient)
        commit(ingredient, household: household, context: context)
    }

    static func markUsedUp(_ ingredient: Ingredient, household: Household?, context: ModelContext) {
        PantryInventory.markUsedUp(ingredient)
        commit(ingredient, household: household, context: context)
    }

    static func useOne(_ ingredient: Ingredient, household: Household?, context: ModelContext) {
        guard PantryInventory.useOne(ingredient) else { return }
        commit(ingredient, household: household, context: context)
    }

    /// Start tracking `name` as on hand — the household's catalogue entry when
    /// there is one, a new ingredient when there isn't.
    @discardableResult
    static func startTracking(
        named name: String,
        location: InventoryStorageLocation? = nil,
        household: Household,
        context: ModelContext
    ) -> Ingredient? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, HouseholdMutationAuthorization.canMutate(household: household) else { return nil }
        let ingredient: Ingredient
        if let existing = IngredientMatching.match(
            trimmed, in: household.ingredients ?? [], rules: household.matchRules ?? []
        ) {
            ingredient = existing
        } else {
            ingredient = Ingredient(name: trimmed)
            ingredient.household = household
            context.insert(ingredient)
        }
        startTracking(ingredient, location: location, household: household, context: context)
        return ingredient
    }

    static func startTracking(
        _ ingredient: Ingredient,
        location: InventoryStorageLocation? = nil,
        household: Household?,
        context: ModelContext
    ) {
        if ingredient.inventoryMode == .none || ingredient.inventoryMode == .out {
            ingredient.inventoryMode = .have
        }
        if let location, ingredient.storageLocation == nil {
            ingredient.storageLocation = location
        }
        commit(ingredient, household: household, context: context)
    }

    /// Whether an unticked shopping line already stands for `ingredient`.
    static func isOnShoppingList(_ ingredient: Ingredient, items: [ShoppingListItem]) -> Bool {
        let key = IngredientMatching.key(for: ingredient.name)
        return items.contains { !$0.isChecked && ($0.ingredient === ingredient || IngredientMatching.key(for: $0.name) == key) }
    }
}
