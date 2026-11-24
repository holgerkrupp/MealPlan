import Foundation
import SwiftData

/// The mutation boundary shared by the app UI, widgets and App Intents.
///
/// Keeping the stamps and reload in one place matters for CloudKit: a tick
/// made by Siri must look exactly like a tick made in the shopping-list view.
@MainActor
enum ShoppingListMutationService {
    static func createList(named name: String, household: Household, context: ModelContext) -> ShoppingList? {
        guard HouseholdMutationAuthorization.canMutate(household: household) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let list = ShoppingList(name: trimmed, sortIndex: (household.shoppingLists ?? []).count)
        list.household = household
        context.insert(list)
        try? context.save()
        return list
    }

    static func rename(_ list: ShoppingList, to name: String, context: ModelContext) -> Bool {
        guard !list.isGenerated,
              HouseholdMutationAuthorization.canMutate(household: list.household) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard list.name != trimmed else { return true }
        list.name = trimmed
        list.modifiedAt = .now
        try? context.save()
        return true
    }

    static func duplicate(_ source: ShoppingList, named name: String?, context: ModelContext) -> ShoppingList? {
        guard let household = source.household,
              HouseholdMutationAuthorization.canMutate(household: household) else { return nil }
        let fallback = String(localized: "Copy of \(source.name)")
        guard let copy = createList(named: name ?? fallback, household: household, context: context) else { return nil }
        for item in source.items ?? [] {
            let cloned = ShoppingListItem(name: item.name, category: item.category, isManual: item.isManual)
            cloned.normalizedName = item.normalizedName
            cloned.customAisleName = item.customAisleName
            cloned.canonicalValue = item.canonicalValue
            cloned.canonicalDimensionRaw = item.canonicalDimensionRaw
            cloned.additionalAmountsRaw = item.additionalAmountsRaw
            cloned.unmeasuredCount = item.unmeasuredCount
            cloned.displayText = item.displayText
            cloned.displayUnit = item.displayUnit
            cloned.isChecked = item.isChecked
            cloned.isApproximate = item.isApproximate
            cloned.sortIndex = item.sortIndex
            cloned.rangeStart = item.rangeStart
            cloned.rangeEnd = item.rangeEnd
            cloned.sourceDishNames = item.sourceDishNames
            cloned.ingredient = item.ingredient
            cloned.household = household
            cloned.list = copy
            context.insert(cloned)
        }
        try? context.save()
        return copy
    }

    static func deleteList(_ list: ShoppingList, context: ModelContext) -> Bool {
        guard !list.isGenerated,
              let household = list.household,
              HouseholdMutationAuthorization.canMutate(household: household) else { return false }
        context.delete(list)
        try? context.save()
        SharedStore.reloadWidgets()
        return true
    }

    static func move(_ item: ShoppingListItem, to destination: ShoppingList, context: ModelContext) {
        guard let household = item.household,
              destination.household?.uuid == household.uuid,
              HouseholdMutationAuthorization.canMutate(household: household) else { return }
        item.list = destination
        item.modifiedAt = .now
        item.contentModifiedAt = item.modifiedAt
        try? context.save()
    }

    @discardableResult
    static func copy(_ item: ShoppingListItem, to destination: ShoppingList, context: ModelContext) -> ShoppingListItem? {
        guard let household = item.household,
              destination.household?.uuid == household.uuid,
              HouseholdMutationAuthorization.canMutate(household: household) else { return nil }
        let copy = ShoppingListItem(name: item.name, category: item.category, isManual: true)
        copy.normalizedName = item.normalizedName
        copy.customAisleName = item.customAisleName
        copy.canonicalValue = item.canonicalValue
        copy.canonicalDimensionRaw = item.canonicalDimensionRaw
        copy.additionalAmountsRaw = item.additionalAmountsRaw
        copy.unmeasuredCount = item.unmeasuredCount
        copy.displayText = item.displayText
        copy.displayUnit = item.displayUnit
        copy.isChecked = item.isChecked
        copy.isApproximate = item.isApproximate
        copy.sortIndex = item.sortIndex
        copy.rangeStart = item.rangeStart
        copy.rangeEnd = item.rangeEnd
        copy.sourceDishNames = item.sourceDishNames
        copy.ingredient = item.ingredient
        copy.household = household
        copy.list = destination
        context.insert(copy)
        try? context.save()
        return copy
    }

    static func setChecked(
        _ item: ShoppingListItem,
        checked: Bool,
        context: ModelContext
    ) {
        guard HouseholdMutationAuthorization.canMutate(household: item.household) else { return }
        guard item.isChecked != checked else { return }
        item.isChecked = checked
        let now = Date.now
        item.checkStateModifiedAt = now
        item.modifiedAt = now
        do { try context.save() } catch { return }
        // This also covers widget extension commits, whose ModelContext save
        // is invisible to the main app's in-process save observer.
        HouseholdStoreGeneration.markDirty()
        SharedStore.reloadWidgets()
    }

    static func remove(_ item: ShoppingListItem, context: ModelContext) {
        delete(ids: [item.uuid], context: context)
    }

    /// Delete by stable identities instead of retaining model objects in a
    /// view while SwiftData is invalidating them.
    static func delete(ids: some Sequence<UUID>, context: ModelContext) {
        let ids = Set(ids)
        guard !ids.isEmpty else { return }
        let current = (try? context.fetch(FetchDescriptor<ShoppingListItem>())) ?? []
        for item in current where ids.contains(item.uuid) && HouseholdMutationAuthorization.canMutate(household: item.household) {
            context.delete(item)
        }
        try? context.save()
        SharedStore.reloadWidgets()
    }

    static func clearCompleted(
        from items: [ShoppingListItem],
        context: ModelContext
    ) {
        delete(ids: items.compactMap { $0.isChecked ? $0.uuid : nil }, context: context)
    }
}
