import Foundation
import SwiftData

/// A small household-owned recipe combination. It references dishes by UUID,
/// rather than copying recipes, so edits and photos remain authoritative in
/// the dish library.
struct ReusableMenu: Codable, Equatable, Identifiable, Sendable {
    struct Item: Codable, Equatable, Identifiable, Sendable {
        var id: UUID { dishID }
        var dishID: UUID
        var servings: Int?
        var mealKey: String?
    }

    var id: UUID
    var name: String
    var modifiedAt: Date
    var items: [Item]

    init(id: UUID = UUID(), name: String, items: [Item] = [], modifiedAt: Date = .now) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modifiedAt = modifiedAt
        self.items = items
    }
}

struct ReusableMenuPreview: Equatable, Sendable {
    var menuID: UUID
    var targetDate: Date
    var existingCount: Int
    var availableItems: Int
    var missingDishIDs: [UUID]

    var hasMissingDishes: Bool { !missingDishIDs.isEmpty }
}

@MainActor
enum ReusableMenuStore {
    static func save(_ menu: ReusableMenu, in household: Household) {
        guard HouseholdMutationAuthorization.canMutate(household: household) else { return }
        var menus = household.reusableMenus.filter { $0.id != menu.id }
        menus.append(menu)
        household.reusableMenus = menus.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        household.modifiedAt = .now
    }

    static func delete(_ menuID: UUID, from household: Household) {
        guard HouseholdMutationAuthorization.canMutate(household: household) else { return }
        household.reusableMenus = household.reusableMenus.filter { $0.id != menuID }
        household.modifiedAt = .now
    }

    static func preview(_ menu: ReusableMenu, on date: Date, dishes: [Dish], entries: [MealPlanEntry]) -> ReusableMenuPreview {
        let dishIDs = Set(dishes.map(\.uuid))
        let missing = menu.items.map(\.dishID).filter { !dishIDs.contains($0) }
        let existing = entries.filter { $0.date.startOfDay == date.startOfDay && !$0.skipped }.count
        return ReusableMenuPreview(menuID: menu.id, targetDate: date.startOfDay, existingCount: existing, availableItems: menu.items.count - missing.count, missingDishIDs: Array(Set(missing)).sorted { $0.uuidString < $1.uuidString })
    }

    /// Applies a menu after the caller has shown the preview. Returns created
    /// entries so a UI can offer an immediate undo by deleting them.
    @discardableResult
    static func apply(_ menu: ReusableMenu, on date: Date, dishes: [Dish], household: Household, memberName: String, replaceExisting: Bool, context: ModelContext) -> [MealPlanEntry] {
        guard HouseholdMutationAuthorization.canMutate(household: household) else { return [] }
        let day = date.startOfDay
        let householdID = household.uuid
        let existing = (try? context.fetch(FetchDescriptor<MealPlanEntry>(predicate: #Predicate { $0.date == day && $0.household?.uuid == householdID }))) ?? []
        if replaceExisting { existing.forEach(context.delete) }

        let byID = Dictionary(dishes.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        var created: [MealPlanEntry] = []
        for item in menu.items {
            guard let dish = byID[item.dishID] else { continue }
            let key = item.mealKey ?? MealSlot.dinner.rawValue
            let entry = MealPlanEntry(date: day, mealKey: key, dish: dish)
            entry.household = household
            entry.servingsOverride = item.servings
            entry.plannedByName = memberName
            entry.sortIndex = created.filter { $0.mealKey == key }.count
            context.insert(entry)
            created.append(entry)
        }
        guard (try? context.save()) != nil else {
            created.forEach(context.delete)
            return []
        }
        return created
    }
}
