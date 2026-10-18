import Foundation
import SwiftData
import Testing
@testable import MealPlan

@MainActor
@Suite(.serialized)
struct HouseholdMealTypeRecoveryTests {
    @Test func diskReopenAndRecoveryPreserveMealRowsAndPlannedKeys() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MealPlan-meal-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let householdID = UUID()
        let entryID = UUID()
        let legacyEntryID = UUID()
        let customMealID = UUID()
        let storeURL = directory.appending(path: "household.sqlite")
        do {
            let schema = SharedStore.makeSchema()
            let configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            let household = Household(name: "Family")
            household.uuid = householdID
            let custom = MealType(key: "late-supper", name: "Late supper", symbolName: "moon", sortOrder: 3)
            custom.uuid = customMealID
            custom.household = household
            let planned = MealPlanEntry(date: .now, mealKey: "late-supper")
            planned.uuid = entryID
            planned.household = household
            let legacyPlanned = MealPlanEntry(date: .now, mealKey: "snack")
            legacyPlanned.uuid = legacyEntryID
            legacyPlanned.household = household
            context.insert(household)
            context.insert(custom)
            context.insert(planned)
            context.insert(legacyPlanned)
            try context.save()
        }

        let schema = SharedStore.makeSchema()
        let configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let context = reopened.mainContext
        let household = try #require(context.fetch(FetchDescriptor<Household>()).first { $0.uuid == householdID })
        let meal = try #require(context.fetch(FetchDescriptor<MealType>()).first { $0.uuid == customMealID })
        let planned = try #require(context.fetch(FetchDescriptor<MealPlanEntry>()).first { $0.uuid == entryID })
        let legacyPlanned = try #require(context.fetch(FetchDescriptor<MealPlanEntry>()).first { $0.uuid == legacyEntryID })

        #expect(meal.key == "late-supper")
        #expect(meal.name == "Late supper")
        #expect(meal.household?.uuid == householdID)
        #expect(planned.mealSlotRaw == "late-supper")
        #expect(legacyPlanned.mealSlotRaw == "snack")

        // Repair uses direct store fetches and keeps historical planned keys.
        // It does not reset the household or replace its existing custom meal.
        MealType.ensure(for: household, context: context)
        let recovered = try context.fetch(FetchDescriptor<MealType>())
        #expect(recovered.contains { $0.uuid == customMealID && $0.name == "Late supper" })
        #expect(recovered.contains { $0.key == "late-supper" })
        #expect(recovered.contains { $0.key == "snack" && $0.name == "Snack" })
        let persistedPlans = try context.fetch(FetchDescriptor<MealPlanEntry>())
        #expect(persistedPlans.contains { $0.uuid == entryID })
        #expect(persistedPlans.contains { $0.uuid == legacyEntryID && $0.mealSlotRaw == "snack" })
    }

    @Test func failedHouseholdReplacementRollsBackCascadeWithUndoManagerAttached() throws {
        let schema = SharedStore.makeSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        context.undoManager = UndoManager()
        let household = Household(name: "Keep me")
        let dish = Dish(name: "Family recipe")
        dish.household = household
        context.insert(household)
        context.insert(dish)
        try context.save()
        context.undoManager?.removeAllActions()

        do {
            try nonUndoableStoreTransaction(in: context) {
                context.delete(household)
                throw HouseholdRecoveryTestError.injected
            }
        } catch HouseholdRecoveryTestError.injected {
            // Expected: transaction rolled back before restoring UndoManager.
        }

        #expect(try context.fetch(FetchDescriptor<Household>()).contains { $0.uuid == household.uuid })
        #expect(try context.fetch(FetchDescriptor<Dish>()).contains { $0.uuid == dish.uuid })
        #expect(context.undoManager != nil)
        #expect(context.undoManager?.canUndo == false)
    }
}

private enum HouseholdRecoveryTestError: Error {
    case injected
}
