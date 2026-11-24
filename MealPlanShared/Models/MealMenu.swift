import Foundation
import SwiftData

/// A lightweight, reusable combination of dishes such as “Taco night” or
/// “Sunday roast”. Unlike a routine or week template, a menu is applied once
/// to a chosen date and keeps references to the household's existing dishes.
@Model
final class MealMenu {
    var uuid: UUID = UUID()
    var modifiedAt: Date = Date.now
    var name: String = ""
    var createdByName: String?
    var dateCreated: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \MealMenuEntry.menu)
    var entries: [MealMenuEntry]? = []

    var household: Household?

    init(name: String = "") {
        self.uuid = UUID()
        self.name = name
        self.dateCreated = .now
    }

    var sortedEntries: [MealMenuEntry] {
        (entries ?? []).sorted { ($0.sortIndex, $0.uuid.uuidString) < ($1.sortIndex, $1.uuid.uuidString) }
    }

    var availableDishCount: Int { sortedEntries.compactMap(\.dish).count }
    var missingDishCount: Int { sortedEntries.filter { $0.dish == nil }.count }
}

/// One dish in a reusable menu. `mealKey == nil` means the menu item has no
/// preferred slot and uses the slot selected when the menu is applied.
@Model
final class MealMenuEntry {
    var uuid: UUID = UUID()
    var modifiedAt: Date = Date.now
    var mealKey: String?
    var servingsOverride: Int?
    var sortIndex: Int = 0

    var dish: Dish?
    var menu: MealMenu?

    init(dish: Dish? = nil, mealKey: String? = nil, servingsOverride: Int? = nil, sortIndex: Int = 0) {
        self.uuid = UUID()
        self.dish = dish
        self.mealKey = mealKey
        self.servingsOverride = servingsOverride
        self.sortIndex = sortIndex
    }
}
