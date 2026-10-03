import CoreData
import Foundation
import SwiftData
import Testing
@testable import MealPlan

@MainActor
struct ManagedHouseholdMigrationTests {
    @Test func copiesRelationshipsAssetsAndStableUUIDsThenRetainsLegacyForRollback() async throws {
        let fixture = MigrationFixture.standard()
        let stateStore = MemoryMigrationStateStore()
        let persistence = try ManagedHouseholdPersistence(cloudKitEnabled: false, inMemory: true)
        let migration = ManagedHouseholdMigration(
            source: fixture,
            destination: persistence,
            stateStore: stateStore,
            batchSize: 1
        )

        try await migration.run()

        #expect(stateStore.state?.phase == .legacyRetainedForRollback)
        let context = persistence.container.viewContext
        let dish = try #require(fetch(.dish, uuid: fixture.dishID, from: context).first)
        let image = try #require(fetch(.dishImage, uuid: fixture.imageID, from: context).first)
        let entry = try #require(fetch(.mealPlanEntry, uuid: fixture.entryID, from: context).first)
        let ingredientLine = try #require(fetch(.dishIngredient, uuid: fixture.lineID, from: context).first)

        #expect(dish.value(forKey: "uuid") as? UUID == fixture.dishID)
        #expect(dish.value(forKey: "name") as? String == "Pumpkin soup")
        #expect(image.value(forKey: "data") as? Data == Data([9, 8, 7]))
        #expect((image.value(forKey: "dish") as? NSManagedObject)?.value(forKey: "uuid") as? UUID == fixture.dishID)
        #expect((entry.value(forKey: "dish") as? NSManagedObject)?.value(forKey: "uuid") as? UUID == fixture.dishID)
        #expect((ingredientLine.value(forKey: "ingredient") as? NSManagedObject)?.value(forKey: "uuid") as? UUID == fixture.ingredientID)

        // A second launch observes the retained completion marker and cannot
        // duplicate rows or turn the one-way copy into a bridge.
        try await migration.run()
        #expect(try context.fetch(NSFetchRequest<NSManagedObject>(entityName: ManagedHouseholdEntity.dish.rawValue)).count == 1)
    }

    @Test func resumesAfterAPersistedEntityCheckpoint() async throws {
        let fixture = MigrationFixture.standard()
        let persistence = try ManagedHouseholdPersistence(cloudKitEnabled: false, inMemory: true)
        try await persistence.load()
        let context = persistence.container.viewContext
        let preCopiedDish = try persistence.insert(.dish, into: .private, context: context, uuid: fixture.dishID)
        preCopiedDish.setValue(fixture.dishModifiedAt, forKey: "modifiedAt")
        preCopiedDish.setValue("Pumpkin soup", forKey: "name")
        preCopiedDish.setValue(Data("[\"soup\"]".utf8), forKey: "tagNames")
        try context.save()

        let stateStore = MemoryMigrationStateStore(state: .init(
            version: ManagedHouseholdMigrationState.currentVersion,
            phase: .copying,
            sourceCounts: try fixture.inventory().counts,
            entityCheckpoints: [ManagedHouseholdEntity.dish.rawValue: fixture.dishID.uuidString],
            updatedAt: .now,
            failureCode: nil
        ))
        let migration = ManagedHouseholdMigration(source: fixture, destination: persistence, stateStore: stateStore, batchSize: 1)
        try await migration.run()

        #expect(stateStore.state?.phase == .legacyRetainedForRollback)
        #expect(try context.fetch(NSFetchRequest<NSManagedObject>(entityName: ManagedHouseholdEntity.dish.rawValue)).count == 1)
        let entry = try #require(fetch(.mealPlanEntry, uuid: fixture.entryID, from: context).first)
        #expect((entry.value(forKey: "dish") as? NSManagedObject)?.value(forKey: "uuid") as? UUID == fixture.dishID)
    }

    @Test func rejectsUnknownMigrationFormatBeforeOpeningTheDestination() async throws {
        let fixture = MigrationFixture.standard()
        let persistence = try ManagedHouseholdPersistence(cloudKitEnabled: false, inMemory: true)
        let stateStore = MemoryMigrationStateStore(state: .init(
            version: ManagedHouseholdMigrationState.currentVersion + 1,
            phase: .copying,
            sourceCounts: [:],
            entityCheckpoints: [:],
            updatedAt: .now,
            failureCode: nil
        ))

        await #expect(throws: ManagedHouseholdMigrationError.unsupportedStateVersion(ManagedHouseholdMigrationState.currentVersion + 1)) {
            try await ManagedHouseholdMigration(source: fixture, destination: persistence, stateStore: stateStore).run()
        }
        #expect(!persistence.isLoaded)
    }

    @Test func readsTheRealSwiftDataGraphWithoutChangingIt() throws {
        let container = SharedStore.make(cloudKit: false, inMemory: true)
        let context = container.mainContext
        let household = Household(name: "Original family")
        let dish = Dish(name: "Kartoffelsuppe")
        dish.recipeText = "Boil potatoes."
        dish.tagNames = ["weeknight"]
        let image = DishImage(data: Data([1, 2, 3]), isPrimary: true)
        household.dishes = [dish]
        dish.images = [image]
        context.insert(household)
        try context.save()

        let source = SwiftDataLegacyHouseholdMigrationSource(context: context)
        let records = try source.records(for: .dish)
        let dishRecord = try #require(records.first(where: { $0.uuid == dish.uuid }))
        let imageRecord = try #require(try source.records(for: .dishImage).first(where: { $0.uuid == image.uuid }))

        #expect(dishRecord.attributes["name"] == .string("Kartoffelsuppe"))
        #expect(dishRecord.attributes["recipeText"] == .string("Boil potatoes."))
        #expect(dishRecord.relationships["household"] == household.uuid)
        #expect(imageRecord.attributes["data"] == .data(Data([1, 2, 3])))
        #expect(imageRecord.relationships["dish"] == dish.uuid)
        #expect(try context.fetch(FetchDescriptor<Household>()).count == 1)
    }

    private func fetch(
        _ entity: ManagedHouseholdEntity,
        uuid: UUID,
        from context: NSManagedObjectContext
    ) -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity.rawValue)
        request.predicate = NSPredicate(format: "uuid == %@", uuid as CVarArg)
        return (try? context.fetch(request)) ?? []
    }
}

@MainActor
private final class MemoryMigrationStateStore: ManagedHouseholdMigrationStateStore {
    var state: ManagedHouseholdMigrationState?

    init(state: ManagedHouseholdMigrationState? = nil) {
        self.state = state
    }

    func load() throws -> ManagedHouseholdMigrationState? { state }
    func save(_ state: ManagedHouseholdMigrationState) throws { self.state = state }
}

@MainActor
private final class MigrationFixture: LegacyHouseholdMigrationSource {
    let householdID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let dishID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let imageID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let ingredientID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    let lineID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    let entryID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    let dishModifiedAt = Date(timeIntervalSinceReferenceDate: 1_000)

    static func standard() -> MigrationFixture { MigrationFixture() }

    func inventory() throws -> ManagedHouseholdMigrationInventory {
        var identifiers = Dictionary(uniqueKeysWithValues: ManagedHouseholdEntity.allCases.map { ($0, Set<UUID>()) })
        for record in records { identifiers[record.entity, default: []].insert(record.uuid) }
        return .init(identifiersByEntity: identifiers)
    }

    func records(for entity: ManagedHouseholdEntity) throws -> [ManagedHouseholdMigrationRecord] {
        records.filter { $0.entity == entity }
    }

    private var records: [ManagedHouseholdMigrationRecord] {
        [
            .init(
                entity: .household,
                uuid: householdID,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 900),
                scope: .private,
                attributes: [
                    "name": .string("Original family"),
                    "dateCreated": .date(Date(timeIntervalSinceReferenceDate: 800)),
                    "bringShadowKeys": .data(Data("[]".utf8)),
                ],
                relationships: [:]
            ),
            .init(
                entity: .dish,
                uuid: dishID,
                modifiedAt: dishModifiedAt,
                scope: .private,
                attributes: ["name": .string("Pumpkin soup"), "tagNames": .data(Data("[\"soup\"]".utf8))],
                relationships: ["household": householdID]
            ),
            .init(
                entity: .dishImage,
                uuid: imageID,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 1_001),
                scope: .private,
                attributes: ["data": .data(Data([9, 8, 7]))],
                relationships: ["dish": dishID]
            ),
            .init(
                entity: .ingredient,
                uuid: ingredientID,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 1_002),
                scope: .private,
                attributes: ["name": .string("Pumpkin"), "normalizedName": .string("pumpkin"), "rejectedMatchKeys": .data(Data("[]".utf8))],
                relationships: ["household": householdID]
            ),
            .init(
                entity: .dishIngredient,
                uuid: lineID,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 1_003),
                scope: .private,
                attributes: ["rawText": .string("Pumpkin"), "sortIndex": .integer(0)],
                relationships: ["dish": dishID, "ingredient": ingredientID]
            ),
            .init(
                entity: .mealPlanEntry,
                uuid: entryID,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 1_004),
                scope: .private,
                attributes: [
                    "placementModifiedAt": .date(Date(timeIntervalSinceReferenceDate: 1_004)),
                    "contentModifiedAt": .date(Date(timeIntervalSinceReferenceDate: 1_004)),
                    "date": .date(Date(timeIntervalSinceReferenceDate: 1_005)),
                    "mealSlotRaw": .string("dinner"),
                    "participatingMemberUUIDs": .data(Data("[]".utf8)),
                ],
                relationships: ["household": householdID, "dish": dishID]
            ),
        ]
    }
}
