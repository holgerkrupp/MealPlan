import Foundation
import SwiftData
import Testing
@testable import MealPlan

/// Field crashes in the CloudKit apply path. A crash here takes the test host
/// down rather than failing an expectation.
@MainActor
@Suite(.serialized)
struct HouseholdRecordApplierCrashTests {
    private func cookedLogPayload(uuid: UUID, dish: UUID?, entry: UUID?) throws -> Data {
        try HouseholdRecordCodec.encode(HouseholdRecordPayload.cookedLog(.init(
            uuid: uuid,
            date: .now,
            dishName: "Soup",
            servings: 2,
            dishUUID: dish,
            entryUUID: entry
        )))
    }

    private func apply(
        _ data: Data,
        uuid: UUID,
        household: Household,
        context: ModelContext,
        expectedRecordCount: Int
    ) throws {
        try HouseholdRecordApplier.withBatchLookup(in: context, expectedRecordCount: expectedRecordCount) {
            try HouseholdRecordApplier.apply(
                payloadData: data,
                identity: .init(type: .cookedLog, uuid: uuid),
                modifiedAt: .now,
                assetData: nil,
                household: household,
                context: context
            )
        }
    }

    private func seed(_ context: ModelContext) throws -> (Household, Dish, MealPlanEntry) {
        let household = Household(name: "Test")
        let dish = Dish(name: "Soup")
        dish.household = household
        let entry = MealPlanEntry(date: .now, slot: .dinner, dish: dish)
        entry.household = household
        context.insert(household)
        context.insert(dish)
        context.insert(entry)
        try context.save()
        return (household, dish, entry)
    }

    @Test(arguments: [1, 100])
    func remoteCookedLogAttachesToHouseholdWithExistingLogs(expectedRecordCount: Int) throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let (household, dish, entry) = try seed(context)
        let existing = CookedLog(date: .now, dish: dish, servings: 2)
        existing.household = household
        context.insert(existing)
        try context.save()

        let uuid = UUID()
        try apply(try cookedLogPayload(uuid: uuid, dish: dish.uuid, entry: entry.uuid),
                  uuid: uuid, household: household, context: context, expectedRecordCount: expectedRecordCount)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<CookedLog>()) == 2)
        #expect(household.cookedLogs?.count == 2)
    }

    /// A batch that fails rolls back, and the fetched records are then applied
    /// again in the same process by the retry path.
    @Test(arguments: [1, 100])
    func remoteCookedLogAppliesAfterARolledBackBatch(expectedRecordCount: Int) throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let (household, dish, entry) = try seed(context)

        let uuid = UUID()
        let data = try cookedLogPayload(uuid: uuid, dish: dish.uuid, entry: entry.uuid)
        struct BatchFailed: Error {}
        #expect(throws: BatchFailed.self) {
            try nonUndoableStoreTransaction(in: context) {
                try apply(data, uuid: uuid, household: household, context: context, expectedRecordCount: expectedRecordCount)
                throw BatchFailed()
            }
        }

        try nonUndoableStoreTransaction(in: context) {
            try apply(data, uuid: uuid, household: household, context: context, expectedRecordCount: expectedRecordCount)
            try context.save()
        }

        #expect(try context.fetchCount(FetchDescriptor<CookedLog>()) == 1)
        #expect(household.cookedLogs?.count == 1)
    }

    /// A large fetch adds several logs before saving, so the household's
    /// relationship already holds unsaved rows when the next one is attached.
    @Test(arguments: [1, 100])
    func severalRemoteCookedLogsApplyInOneTransaction(expectedRecordCount: Int) throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let (household, dish, entry) = try seed(context)
        #expect(household.cookedLogs?.isEmpty == true)

        try HouseholdRecordApplier.withBatchLookup(in: context, expectedRecordCount: expectedRecordCount) {
            for index in 0..<5 {
                let uuid = UUID()
                try HouseholdRecordApplier.apply(
                    payloadData: try cookedLogPayload(uuid: uuid, dish: dish.uuid, entry: index == 0 ? entry.uuid : nil),
                    identity: .init(type: .cookedLog, uuid: uuid),
                    modifiedAt: .now,
                    assetData: nil,
                    household: household,
                    context: context
                )
            }
            try context.save()
        }
        #expect(household.cookedLogs?.count == 5)
    }

    /// Deletion markers are applied in the same pass as modifications, and
    /// deleting a plan entry cascades to its log.
    @Test(arguments: [1, 100])
    func remoteCookedLogAppliesAfterASiblingWasDeletedInTheBatch(expectedRecordCount: Int) throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let (household, dish, entry) = try seed(context)
        let deleted = CookedLog(date: .now, dish: dish, servings: 2)
        deleted.household = household
        let cascaded = CookedLog(date: .now, dish: dish, servings: 2)
        cascaded.household = household
        cascaded.entry = entry
        context.insert(deleted)
        context.insert(cascaded)
        try context.save()
        #expect(household.cookedLogs?.count == 2)

        try HouseholdRecordApplier.withBatchLookup(in: context, expectedRecordCount: expectedRecordCount) {
            try HouseholdRecordApplier.delete(type: .cookedLog, uuid: deleted.uuid, context: context)
            try HouseholdRecordApplier.delete(type: .planEntry, uuid: entry.uuid, context: context)
            let uuid = UUID()
            try HouseholdRecordApplier.apply(
                payloadData: try cookedLogPayload(uuid: uuid, dish: dish.uuid, entry: nil),
                identity: .init(type: .cookedLog, uuid: uuid),
                modifiedAt: .now,
                assetData: nil,
                household: household,
                context: context
            )
            try context.save()
        }
        #expect(try context.fetchCount(FetchDescriptor<CookedLog>()) == 1)
    }

    /// Rows can hang off a second `Household` row, and two logs can claim one
    /// plan entry even though the entry holds a single log.
    @Test(arguments: [1, 100])
    func remoteCookedLogMovesBetweenHouseholdsAndEntries(expectedRecordCount: Int) throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let (household, dish, entry) = try seed(context)
        let duplicate = Household(name: "Duplicate")
        context.insert(duplicate)
        let moved = CookedLog(date: .now, dish: dish, servings: 2)
        moved.household = duplicate
        let claimant = CookedLog(date: .now, dish: dish, servings: 2)
        claimant.household = household
        claimant.entry = entry
        context.insert(moved)
        context.insert(claimant)
        try context.save()

        try apply(try cookedLogPayload(uuid: moved.uuid, dish: dish.uuid, entry: entry.uuid),
                  uuid: moved.uuid, household: household, context: context, expectedRecordCount: expectedRecordCount)
        try context.save()

        #expect(moved.household?.uuid == household.uuid)
        #expect(entry.cookedLog?.uuid == moved.uuid)
    }

    /// Only `CookedLog` keeps external-storage bytes on a row that hangs
    /// directly off `Household`.
    @Test(arguments: [1, 100])
    func remoteCookedLogAttachesBesideALogWithAPhoto(expectedRecordCount: Int) throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let (household, dish, entry) = try seed(context)
        let existing = CookedLog(date: .now, dish: dish, servings: 2)
        existing.photoData = Data(repeating: 7, count: 300_000)
        existing.household = household
        context.insert(existing)
        try context.save()

        // A fresh context faults the relationship in, as a relaunch does.
        let fresh = ModelContext(container)
        let householdID = household.uuid
        let reloaded = try #require(try fresh.fetch(FetchDescriptor<Household>(
            predicate: #Predicate { $0.uuid == householdID }
        )).first)
        let uuid = UUID()
        try apply(try cookedLogPayload(uuid: uuid, dish: dish.uuid, entry: entry.uuid),
                  uuid: uuid, household: reloaded, context: fresh, expectedRecordCount: expectedRecordCount)
        try apply(try cookedLogPayload(uuid: existing.uuid, dish: dish.uuid, entry: nil),
                  uuid: existing.uuid, household: reloaded, context: fresh, expectedRecordCount: expectedRecordCount)
        try fresh.save()
        #expect(reloaded.cookedLogs?.count == 2)
    }

    /// Local-first launch adopts a placeholder and deletes it, and the sync
    /// service can still hold that instance.
    @Test func remoteCookedLogAppliesToAHouseholdDeletedByReconciliation() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let (_, dish, _) = try seed(context)
        let placeholder = Household(name: "Placeholder")
        context.insert(placeholder)
        try context.save()
        context.delete(placeholder)
        try context.save()

        let uuid = UUID()
        try apply(try cookedLogPayload(uuid: uuid, dish: dish.uuid, entry: nil),
                  uuid: uuid, household: placeholder, context: context, expectedRecordCount: 1)
        context.rollback()
    }

    /// The sync service holds one `Household` instance while background
    /// contexts and the main context both save relationship changes.
    @Test func remoteCookedLogAppliesAfterAnotherContextChangedTheHousehold() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let (household, dish, entry) = try seed(context)
        #expect(household.cookedLogs?.isEmpty == true)

        let other = ModelContext(container)
        let householdID = household.uuid
        let otherHousehold = try #require(try other.fetch(FetchDescriptor<Household>(
            predicate: #Predicate { $0.uuid == householdID }
        )).first)
        let foreign = CookedLog()
        foreign.household = otherHousehold
        other.insert(foreign)
        try other.save()

        let uuid = UUID()
        try apply(try cookedLogPayload(uuid: uuid, dish: dish.uuid, entry: entry.uuid),
                  uuid: uuid, household: household, context: context, expectedRecordCount: 1)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<CookedLog>()) == 2)
    }

    /// CloudKit redelivers unchanged dishes as part of normal reconciliation.
    /// Reapplying the same household relationship must not needlessly mutate
    /// Household.dishes' inverse, while a genuinely moved dish still attaches.
    @Test func repeatedRemoteDishApplyKeepsRelationshipAndPlanReference() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let (household, dish, entry) = try seed(context)
        let record = try #require(try HouseholdRecordCodec.records(for: household, context: context)
            .first { $0.identity.type == .dish && $0.identity.uuid == dish.uuid })

        let otherHousehold = Household(name: "Other")
        context.insert(otherHousehold)
        dish.household = otherHousehold
        try context.save()

        for _ in 0..<3 {
            try HouseholdRecordApplier.withBatchLookup(in: context, expectedRecordCount: 1) {
                try HouseholdRecordApplier.apply(
                    payloadData: record.payloadData,
                    identity: record.identity,
                    modifiedAt: record.modifiedAt,
                    assetData: record.assetData,
                    household: household,
                    context: context
                )
            }
        }
        try context.save()

        #expect(dish.household?.uuid == household.uuid)
        #expect(household.dishes?.contains { $0.uuid == dish.uuid } == true)
        #expect(otherHousehold.dishes?.contains { $0.uuid == dish.uuid } == false)
        #expect(entry.dish?.uuid == dish.uuid)
        #expect(try context.fetchCount(FetchDescriptor<Dish>()) == 1)
    }

    /// The small CloudKit path previously called `context.delete` before
    /// removing the same model from its lookup cache. Keep the live instance
    /// valid until that cache entry has been evicted, and preserve its plan row.
    @Test func targetedRemoteDishDeleteEvictsLookupBeforeInvalidation() throws {
        let (container, directory) = try makeTestModelContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = container.mainContext
        let (_, dish, entry) = try seed(context)

        try HouseholdRecordApplier.withBatchLookup(in: context, expectedRecordCount: 1) {
            try HouseholdRecordApplier.delete(type: .dish, uuid: dish.uuid, context: context)
        }
        try context.save()

        let reloaded = ModelContext(container)
        #expect(try reloaded.fetchCount(FetchDescriptor<Dish>()) == 0)
        let entryID = entry.uuid
        let savedEntry = try #require(try reloaded.fetch(FetchDescriptor<MealPlanEntry>(
            predicate: #Predicate { $0.uuid == entryID }
        )).first)
        #expect(savedEntry.mealSlotRaw == "dinner")
        #expect(savedEntry.dish == nil)
    }
}
