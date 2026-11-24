import Foundation
import SwiftData

/// Creates the generated list and repairs older rows that predate named
/// lists. This is intentionally idempotent: it is safe to call after local
/// restore, CloudKit bootstrap, or an extension-side write.
@MainActor
enum ShoppingListStoreMigration {
    static func ensureGeneratedList(for household: Household, context: ModelContext) -> ShoppingList {
        let generatedID = ShoppingList.generatedID(for: household.uuid)
        let existing = (household.shoppingLists ?? []).filter { $0.isGenerated }
        let canonical = existing.first(where: { $0.uuid == generatedID })
            ?? existing.sorted { $0.uuid.uuidString < $1.uuid.uuidString }.first
            ?? ShoppingList(name: ShoppingList.generatedName, isGenerated: true, uuid: generatedID)

        if canonical.household?.persistentModelID != household.persistentModelID {
            canonical.household = household
        }
        if canonical.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            canonical.name = ShoppingList.generatedName
        }
        canonical.isGenerated = true

        if canonical.uuid != generatedID, existing.count == 1 {
            // An early development build may have created the generated list
            // before the deterministic identity was introduced. Keep its
            // contents and repair the identity before the first sync.
            canonical.uuid = generatedID
        }

        for item in household.shoppingItems ?? [] where item.list == nil {
            item.list = canonical
        }
        for duplicate in existing where duplicate.persistentModelID != canonical.persistentModelID {
            for item in duplicate.items ?? [] { item.list = canonical }
            context.delete(duplicate)
        }
        if canonical.modelContext == nil { context.insert(canonical) }
        return canonical
    }

    static func lists(for household: Household) -> [ShoppingList] {
        (household.shoppingLists ?? []).sorted {
            if $0.isGenerated != $1.isGenerated { return $0.isGenerated }
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
