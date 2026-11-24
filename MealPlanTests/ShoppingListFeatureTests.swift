import Foundation
import SwiftData
import Testing

@MainActor
@Suite(.serialized)
struct ShoppingListFeatureTests {
    @Test func generatedAndNamedListsStaySeparateAcrossCrud() throws {
        let container = SharedStore.container(cloudKit: false, inMemory: true)
        let context = container.mainContext
        let household = Household(name: "Test")
        context.insert(household)
        try context.save()

        let generated = ShoppingListStoreMigration.ensureGeneratedList(for: household, context: context)
        let list = try #require(ShoppingListMutationService.createList(named: "Party", household: household, context: context))
        let item = try #require(ShoppingListBuilder.addManualItem(
            named: "2 apples",
            household: household,
            system: .metric,
            list: list,
            context: context
        ))
        #expect(generated.isGenerated)
        #expect(item.list?.uuid == list.uuid)
        #expect(generated.items?.isEmpty != false)

        let copy = try #require(ShoppingListMutationService.duplicate(list, named: nil, context: context))
        #expect(copy.name == "Copy of Party")
        #expect(copy.items?.count == 1)
        #expect(copy.items?.first?.isChecked == false)

        #expect(ShoppingListMutationService.rename(list, to: "Birthday", context: context))
        #expect(list.name == "Birthday")
        #expect(ShoppingListMutationService.deleteList(list, context: context))
        #expect((try context.fetch(FetchDescriptor<ShoppingList>())).contains { $0.uuid == copy.uuid })
    }

    @Test func migrationRepairsLegacyRowsWithoutAnOwningList() throws {
        let container = SharedStore.container(cloudKit: false, inMemory: true)
        let context = container.mainContext
        let household = Household(name: "Legacy")
        let item = ShoppingListItem(name: "Milk", isManual: false)
        item.household = household
        context.insert(household)
        context.insert(item)
        try context.save()

        let generated = ShoppingListStoreMigration.ensureGeneratedList(for: household, context: context)
        #expect(item.list?.uuid == generated.uuid)
        #expect(generated.uuid == ShoppingList.generatedID(for: household.uuid))
    }
}
