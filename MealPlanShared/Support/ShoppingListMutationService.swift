import Foundation
import SwiftData

/// The mutation boundary shared by the app UI, widgets and App Intents.
///
/// Keeping the stamps and reload in one place matters for CloudKit: a tick
/// made by Siri must look exactly like a tick made in the shopping-list view.
@MainActor
enum ShoppingListMutationService {
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
        try? context.save()
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
