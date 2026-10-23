import Foundation
import SwiftData
import Testing
@testable import MealPlan

@MainActor
struct HouseholdReplacementArchiveTests {
    @Test func archiveSurvivesReplacementAndCanRestoreTheFullOfflineGraph() throws {
        let (container, storeDirectory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let context = container.mainContext
        let archiveDirectory = FileManager.default.temporaryDirectory
            .appending(path: "MealPlan-archive-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: archiveDirectory) }

        let household = Household(name: "Offline home")
        household.standardServings = 5
        household.bringListUuid = "bring-list-id"
        household.bringListName = "Offline groceries"
        household.bringShadowKeys = ["bread", "milk"]
        household.bringAutoSync = false
        household.unlockedByPurchase = true
        context.insert(household)

        let profileID = UUID()
        let member = HouseholdMember(name: "Offline member", role: .editor)
        member.uuid = profileID
        member.allergies = ["peanut"]
        member.household = household
        context.insert(member)

        let dish = Dish(name: "Offline recipe")
        dish.household = household
        let image = DishImage(data: Data([0x10, 0x20, 0x30]), isPrimary: true)
        image.dish = dish
        dish.images = [image]
        context.insert(dish)
        context.insert(image)

        let entry = MealPlanEntry(date: Date(timeIntervalSince1970: 123_456), slot: .dinner, dish: dish)
        entry.household = household
        entry.note = "offline edit"
        entry.participatingMemberUUIDs = [profileID.uuidString]
        context.insert(entry)

        let shoppingItem = ShoppingListItem(name: "Offline ingredient", isManual: true)
        shoppingItem.isChecked = true
        shoppingItem.household = household
        context.insert(shoppingItem)

        let routine = MealRoutine(dish: dish)
        routine.household = household
        context.insert(routine)

        let log = CookedLog(date: Date(timeIntervalSince1970: 234_567), dish: dish)
        log.photoData = Data([0xAA, 0xBB])
        log.household = household
        context.insert(log)

        // The owner-adoption path can replace more than one local root. A
        // single portable archive must include the data attached to every
        // root, even though restore folds it into one detached household.
        let secondHousehold = Household(name: "Second offline home")
        context.insert(secondHousehold)
        let secondDish = Dish(name: "Second household recipe")
        secondDish.household = secondHousehold
        context.insert(secondDish)
        let secondEntry = MealPlanEntry(date: Date(timeIntervalSince1970: 345_678), slot: .lunch, dish: secondDish)
        secondEntry.household = secondHousehold
        secondEntry.note = "second household plan"
        context.insert(secondEntry)
        let secondShoppingItem = ShoppingListItem(name: "Second household grocery", isManual: true)
        secondShoppingItem.isChecked = true
        secondShoppingItem.household = secondHousehold
        context.insert(secondShoppingItem)
        try context.save()

        let archiveURL = try HouseholdRecoveryService.archiveBeforeReplacement(
            context: context,
            operationID: "test-join-operation",
            preferredHouseholdID: household.uuid,
            folder: archiveDirectory
        )
        let repeatedURL = try HouseholdRecoveryService.archiveBeforeReplacement(
            context: context,
            operationID: "test-join-operation",
            preferredHouseholdID: household.uuid,
            folder: archiveDirectory
        )
        #expect(archiveURL == repeatedURL)

        // Simulate termination after the archive commit but before/after the
        // active-store replacement: rediscovery reads only durable files.
        let archives = HouseholdRecoveryService.safetyBackups(at: archiveDirectory)
        #expect(archives.count == 2)
        let secondRootArchive = try #require(archives.first { $0.backup.household.name == secondHousehold.name })
        #expect(secondRootArchive.backup.contents.dishes == 2)
        let recovered = try #require(archives.first { $0.backup.household.name == household.name })
        let recoveredAfterRestart = try #require(HouseholdRecoveryService.safetyBackups(at: archiveDirectory).first { $0.backup.household.name == household.name })
        #expect(recovered.isDetachedArchive)
        #expect(recovered.detachedHouseholdUUID == recoveredAfterRestart.detachedHouseholdUUID)
        #expect(recovered.detachedHouseholdUUID != household.uuid)
        #expect(recovered.backup.householdCount == 2)
        #expect(recovered.backup.contents.dishes == 2)
        #expect(recovered.backup.contents.plannedMeals == 2)
        #expect(recovered.backup.contents.shoppingItems == 2)
        #expect(recovered.backup.contents.routines == 1)
        #expect(recovered.backup.contents.cookedMeals == 1)
        #expect(recovered.backup.contents.photos == 2)

        try MealPlanBackupRestore.replaceEverything(
            with: recovered.backup,
            context: context,
            householdUUID: recovered.detachedHouseholdUUID
        )
        let restoredHousehold = try #require(context.fetch(FetchDescriptor<Household>()).first)
        let restoredDish = try #require(context.fetch(FetchDescriptor<Dish>()).first { $0.name == "Offline recipe" })
        let restoredEntry = try #require(context.fetch(FetchDescriptor<MealPlanEntry>()).first { $0.note == "offline edit" })
        let restoredItem = try #require(context.fetch(FetchDescriptor<ShoppingListItem>()).first)
        let restoredRoutine = try #require(context.fetch(FetchDescriptor<MealRoutine>()).first { $0.dish?.name == "Offline recipe" })
        let restoredLog = try #require(context.fetch(FetchDescriptor<CookedLog>()).first)
        let restoredMember = try #require(context.fetch(FetchDescriptor<HouseholdMember>()).first)

        #expect(restoredHousehold.uuid != household.uuid)
        #expect(restoredHousehold.standardServings == 5)
        #expect(restoredHousehold.bringListUuid == "bring-list-id")
        #expect(restoredHousehold.bringListName == "Offline groceries")
        #expect(restoredHousehold.bringShadowKeys == ["bread", "milk"])
        #expect(!restoredHousehold.bringAutoSync)
        #expect(!restoredHousehold.unlockedByPurchase)
        #expect(restoredHousehold.cloudKitShareIdentifier == nil)
        #expect(restoredDish.sortedImages.first?.data == Data([0x10, 0x20, 0x30]))
        #expect(restoredEntry.note == "offline edit")
        #expect(restoredEntry.participatingMemberUUIDs == [profileID.uuidString])
        #expect(restoredMember.uuid == profileID)
        #expect(restoredMember.allergies == ["peanut"])
        #expect(restoredItem.isChecked)
        #expect(restoredRoutine.dish?.uuid == restoredDish.uuid)
        #expect(restoredLog.photoData == Data([0xAA, 0xBB]))
        #expect(try context.fetch(FetchDescriptor<Dish>()).map(\.name).contains("Second household recipe"))
        #expect(try context.fetch(FetchDescriptor<MealPlanEntry>()).contains { $0.note == "second household plan" })
        #expect(try context.fetch(FetchDescriptor<ShoppingListItem>()).contains { $0.name == "Second household grocery" && $0.isChecked })
    }
}
