import Testing
import Foundation
@testable import MealPlan

/// The order the shop is walked in.
///
/// Three surfaces now share this one call — the list on screen, the printed
/// list, and the shopping widget (and through `WatchSnapshotBuilder`, the
/// watch) — so a change here moves all of them at once. That is the point of
/// it being one call, and the reason it is worth pinning down.
struct ShoppingListGroupingTests {

    private func item(
        _ name: String,
        _ category: IngredientCategory = .other,
        aisle: String? = nil,
        sortIndex: Int = 0
    ) -> ShoppingListItem {
        let item = ShoppingListItem(name: name, category: category)
        item.customAisleName = aisle
        item.sortIndex = sortIndex
        return item
    }

    @Test func groupsByAisleInTheOrderTheShopIsWalked() {
        let aisles = ShoppingListGrouping.aisles([
            item("Lentils", .pantry),
            item("Apples", .produce),
            item("Pears", .produce),
        ])
        #expect(aisles.map(\.name) == [
            IngredientCategory.produce.localizedName,
            IngredientCategory.pantry.localizedName,
        ])
        #expect(aisles.first?.items.count == 2)
    }

    @Test func keepsTheListsOwnOrderInsideAnAisle() {
        let aisles = ShoppingListGrouping.aisles([
            item("Pears", .produce, sortIndex: 9),
            item("Apples", .produce, sortIndex: 1),
        ])
        #expect(aisles.first?.items.map(\.name) == ["Apples", "Pears"])
    }

    /// A custom aisle name takes the position of its earliest item rather than
    /// landing alphabetically — otherwise renaming an aisle would silently
    /// reorder the walk.
    @Test func aCustomAisleInheritsThePositionOfItsEarliestItem() {
        let aisles = ShoppingListGrouping.aisles([
            item("Yeast", .pantry, aisle: "Baking counter"),
            item("Flour", .produce, aisle: "Baking counter"),
            item("Rice", .pantry),
        ])
        #expect(aisles.first?.name == "Baking counter")
    }

    /// Two items filed under the same custom name are one aisle, whatever
    /// categories they came from.
    @Test func oneCustomNameIsOneAisle() {
        let aisles = ShoppingListGrouping.aisles([
            item("Yeast", .pantry, aisle: "Baking counter"),
            item("Butter", .dairy, aisle: "Baking counter"),
        ])
        #expect(aisles.count == 1)
        #expect(aisles.first?.items.count == 2)
    }

    @Test func anEmptyListHasNoAisles() {
        #expect(ShoppingListGrouping.aisles([]).isEmpty)
    }

    @Test func nothingIsDroppedOrDuplicated() {
        let items = [
            item("Lentils", .pantry),
            item("Apples", .produce),
            item("Butter", .dairy, aisle: "Cold counter"),
            item("Salt", .pantry),
        ]
        let grouped = ShoppingListGrouping.aisles(items).flatMap(\.items)
        #expect(grouped.count == items.count)
        #expect(Set(grouped.map(\.name)) == Set(items.map(\.name)))
    }
}
