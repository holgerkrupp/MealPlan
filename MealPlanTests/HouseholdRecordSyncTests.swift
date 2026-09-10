import CloudKit
import Foundation
import SwiftData
import Testing
@testable import MealPlan

@MainActor
struct HouseholdRecordSyncTests {
    @Test func unsavedPhotoStaysInItsOwningContext() {
        let container = SharedStore.make(cloudKit: false, inMemory: true)
        let image = DishImage(data: Data([1, 2, 3]))
        container.mainContext.insert(image)

        #expect(image.persistentModelID.storeIdentifier == nil)
        #expect(DishPhotoLoading.persistentID(for: image) == nil)
    }

    @Test func fingerprintUsesStableLowercaseHex() {
        let record = LocalHouseholdRecord(
            identity: .init(type: .dish, uuid: UUID()),
            householdID: UUID(),
            modifiedAt: .now,
            payloadData: Data("abc".utf8)
        )

        #expect(record.fingerprint == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func photoLoaderDistinguishesLegacyDuplicateUUIDs() async throws {
        // A separate ModelActor needs a real SQLite connection. SwiftData's
        // in-memory configuration has no eligible background connection on
        // macOS, so mirror the production topology in a disposable store.
        let storeDirectory = FileManager.default.temporaryDirectory
            .appending(path: "MealPlan-photo-loader-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let schema = SharedStore.makeSchema()
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeDirectory.appending(path: "test.sqlite"),
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let duplicateUUID = UUID()
        let first = DishImage(data: Data([1, 2, 3]))
        let second = DishImage(data: Data([7, 8, 9]))
        first.uuid = duplicateUUID
        second.uuid = duplicateUUID
        context.insert(first)
        context.insert(second)
        try context.save()

        let firstID = first.persistentModelID
        let secondID = second.persistentModelID
        let loader = DishPhotoDataActor(modelContainer: container)

        #expect(await loader.data(for: firstID, uuid: duplicateUUID) == Data([1, 2, 3]))
        #expect(await loader.data(for: secondID, uuid: duplicateUUID) == Data([7, 8, 9]))
    }

    @Test func stableIdentityRoundTripsFromCloudKitName() throws {
        let uuid = UUID()
        let identity = HouseholdRecordIdentity(type: .dish, uuid: uuid)
        let decoded = try #require(HouseholdRecordIdentity(recordType: HouseholdRecordType.dish.rawValue, recordName: identity.recordName))

        #expect(decoded == identity)
        #expect(decoded.recordName == "MPDish-\(uuid.uuidString)")
    }

    @Test func shareLocatorRoundTripsWithoutLosingPermission() throws {
        let source = HouseholdShareLocator(
            zoneName: "MealPlanHousehold-test",
            ownerName: "owner",
            shareRecordName: "share",
            isOwner: false,
            isReadOnly: true
        )

        #expect(HouseholdShareLocator.decode(try HouseholdShareLocator.encode(source)) == source)
    }

    @Test func householdZoneRoundTripsItsIdentity() {
        let householdID = UUID()
        let locator = HouseholdShareLocator.solo(householdID: householdID)

        #expect(HouseholdShareLocator.householdID(from: locator.zoneID) == householdID)
        #expect(HouseholdShareLocator.householdID(from: CKRecordZone.ID(zoneName: "Unrelated")) == nil)
    }

    @Test func legacyShareResolvesRootDirectlyFromZone() {
        let householdID = UUID()
        let zoneID = HouseholdShareLocator.solo(householdID: householdID).zoneID

        #expect(HouseholdCloudSharingService.resolvedHouseholdID(shareValue: nil, zoneID: zoneID) == householdID)
        #expect(HouseholdCloudSharingService.resolvedHouseholdID(shareValue: "invalid", zoneID: zoneID) == householdID)
    }

    @Test func cloudBootstrapPrefersSharedThenOldestHousehold() {
        let oldUnshared = CandidateSummary(zoneName: "old", isShared: false, dateCreated: Date(timeIntervalSince1970: 100))
        let newShared = CandidateSummary(zoneName: "shared", isShared: true, dateCreated: Date(timeIntervalSince1970: 300))
        let oldShared = CandidateSummary(zoneName: "original", isShared: true, dateCreated: Date(timeIntervalSince1970: 200))

        let ordered = [oldUnshared, newShared, oldShared].sorted(by: HouseholdCloudBootstrapService.candidateComesFirst)

        #expect(ordered == [oldShared, newShared, oldUnshared])
    }

    @Test func syncStateIsNamespacedByCloudKitEnvironment() {
        let locator = HouseholdShareLocator(
            zoneName: "MealPlanHousehold-test",
            ownerName: CKCurrentUserDefaultName,
            shareRecordName: CKRecordNameZoneWideShare,
            isOwner: true,
            isReadOnly: false
        )

        let development = HouseholdRecordSyncService.storageSuffix(for: locator, environment: .development)
        let production = HouseholdRecordSyncService.storageSuffix(for: locator, environment: .production)

        #expect(development != production)
    }

    @Test func planMoveAndContentEditMergeIndependently() {
        let earlier = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        let localValue = planValue(date: earlier, meal: "lunch", note: "local note")
        var serverValue = localValue
        serverValue.date = later
        serverValue.mealKey = "dinner"
        serverValue.note = "old note"

        let merged = HouseholdRecordConflictResolver.merge(
            .init(value: localValue, placementModifiedAt: earlier, contentModifiedAt: later),
            .init(value: serverValue, placementModifiedAt: later, contentModifiedAt: earlier)
        )

        #expect(merged.value.date == later)
        #expect(merged.value.mealKey == "dinner")
        #expect(merged.value.note == "local note")
        #expect(merged.placementModifiedAt == later)
        #expect(merged.contentModifiedAt == later)
    }

    @Test func shoppingCheckAndQuantityEditMergeIndependently() {
        let earlier = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        let content = shoppingValue(amount: 2, checked: false)
        var checked = content
        checked.canonicalValue = 1
        checked.isChecked = true

        let merged = HouseholdRecordConflictResolver.merge(
            .init(value: content, ingredientID: nil, contentModifiedAt: later, checkStateModifiedAt: earlier),
            .init(value: checked, ingredientID: nil, contentModifiedAt: earlier, checkStateModifiedAt: later)
        )

        #expect(merged.value.canonicalValue == 2)
        #expect(merged.value.isChecked)
    }

    @Test func equalShoppingCheckClockPrefersChecked() {
        let clock = Date(timeIntervalSince1970: 100)
        let unchecked = ShoppingItemPayload(value: shoppingValue(amount: 1, checked: false), ingredientID: nil, contentModifiedAt: clock, checkStateModifiedAt: clock)
        let checked = ShoppingItemPayload(value: shoppingValue(amount: 1, checked: true), ingredientID: nil, contentModifiedAt: clock, checkStateModifiedAt: clock)

        #expect(HouseholdRecordConflictResolver.merge(unchecked, checked).value.isChecked)
    }

    @Test func newerLocalRecordWinsAndIsResubmitted() throws {
        let uuid = UUID()
        let localDate = Date(timeIntervalSince1970: 200)
        let serverDate = Date(timeIntervalSince1970: 100)
        let localPayload = HouseholdRecordPayload.recipeBookmark(.init(uuid: uuid, title: "Local", urlString: "https://example.com/local", dateAdded: localDate))
        let serverPayload = HouseholdRecordPayload.recipeBookmark(.init(uuid: uuid, title: "Server", urlString: "https://example.com/server", dateAdded: serverDate))
        let local = LocalHouseholdRecord(
            identity: .init(type: .recipeBookmark, uuid: uuid),
            householdID: UUID(),
            modifiedAt: localDate,
            payloadData: try HouseholdRecordCodec.encode(localPayload)
        )
        let record = CKRecord(recordType: HouseholdRecordType.recipeBookmark.rawValue)
        record[HouseholdRecordCodec.payloadKey] = try HouseholdRecordCodec.encode(serverPayload) as CKRecordValue
        record[HouseholdRecordCodec.modifiedAtKey] = serverDate as CKRecordValue

        let resolution = try HouseholdRecordConflictResolver.resolve(local: local, server: record)
        #expect(resolution.payloadData == local.payloadData)
        #expect(resolution.shouldUpload)
    }

    @Test func newerLocalPhotoKeepsItsOwnAssetDuringConflict() throws {
        let imageID = UUID()
        let dishID = UUID()
        let localDate = Date(timeIntervalSince1970: 200)
        let serverDate = Date(timeIntervalSince1970: 100)
        let payload = HouseholdRecordPayload.dishImage(.init(
            dishID: dishID, sortIndex: 0, isPrimary: true, dateAdded: serverDate
        ))
        let localBytes = Data([1, 2, 3])
        let local = LocalHouseholdRecord(
            identity: .init(type: .dishImage, uuid: imageID),
            householdID: UUID(),
            modifiedAt: localDate,
            payloadData: try HouseholdRecordCodec.encode(payload),
            assetData: localBytes
        )
        let record = CKRecord(recordType: HouseholdRecordType.dishImage.rawValue)
        record[HouseholdRecordCodec.payloadKey] = try HouseholdRecordCodec.encode(payload) as CKRecordValue
        record[HouseholdRecordCodec.modifiedAtKey] = serverDate as CKRecordValue

        let resolution = try HouseholdRecordConflictResolver.resolve(
            local: local,
            server: record,
            serverAssetData: Data([9, 9, 9])
        )

        #expect(resolution.assetData == localBytes)
        #expect(resolution.shouldUpload)
    }

    @Test func missingServerPhotoDoesNotEraseLocalAssetAndIsRepaired() throws {
        let imageID = UUID()
        let dishID = UUID()
        let localDate = Date(timeIntervalSince1970: 100)
        let serverDate = Date(timeIntervalSince1970: 200)
        let payload = HouseholdRecordPayload.dishImage(.init(
            dishID: dishID, sortIndex: 0, isPrimary: true, dateAdded: localDate
        ))
        let localBytes = Data([4, 5, 6])
        let local = LocalHouseholdRecord(
            identity: .init(type: .dishImage, uuid: imageID),
            householdID: UUID(),
            modifiedAt: localDate,
            payloadData: try HouseholdRecordCodec.encode(payload),
            assetData: localBytes
        )
        let record = CKRecord(recordType: HouseholdRecordType.dishImage.rawValue)
        record[HouseholdRecordCodec.payloadKey] = try HouseholdRecordCodec.encode(payload) as CKRecordValue
        record[HouseholdRecordCodec.modifiedAtKey] = serverDate as CKRecordValue

        let resolution = try HouseholdRecordConflictResolver.resolve(
            local: local,
            server: record,
            serverAssetData: nil
        )

        #expect(resolution.assetData == localBytes)
        #expect(resolution.shouldUpload)
    }

    @Test func temporarilyUnreadableServerPhotoDoesNotOverwriteCloudAsset() throws {
        let imageID = UUID()
        let localDate = Date(timeIntervalSince1970: 100)
        let serverDate = Date(timeIntervalSince1970: 200)
        let payload = HouseholdRecordPayload.dishImage(.init(
            dishID: UUID(), sortIndex: 0, isPrimary: true, dateAdded: localDate
        ))
        let localBytes = Data([4, 5, 6])
        let local = LocalHouseholdRecord(
            identity: .init(type: .dishImage, uuid: imageID),
            householdID: UUID(),
            modifiedAt: localDate,
            payloadData: try HouseholdRecordCodec.encode(payload),
            assetData: localBytes
        )
        let record = CKRecord(recordType: HouseholdRecordType.dishImage.rawValue)
        record[HouseholdRecordCodec.payloadKey] = try HouseholdRecordCodec.encode(payload) as CKRecordValue
        record[HouseholdRecordCodec.modifiedAtKey] = serverDate as CKRecordValue

        let resolution = try HouseholdRecordConflictResolver.resolve(
            local: local,
            server: record,
            serverAssetData: nil,
            serverHasAsset: true
        )

        #expect(resolution.assetData == localBytes)
        #expect(!resolution.shouldUpload)
    }

    @Test func applyingMissingPhotoAssetPreservesStoredBytes() throws {
        // External-storage attributes need a real SQLite connection on macOS;
        // the in-memory store can report "No eligible connection available".
        let storeDirectory = FileManager.default.temporaryDirectory
            .appending(path: "MealPlan-photo-apply-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let schema = SharedStore.makeSchema()
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeDirectory.appending(path: "test.sqlite"),
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let household = Household(name: "Test")
        let dish = Dish(name: "Soup")
        let image = DishImage(data: Data([7, 8, 9]), isPrimary: true)
        dish.household = household
        image.dish = dish
        context.insert(household)
        context.insert(dish)
        context.insert(image)
        try context.save()

        let payload = HouseholdRecordPayload.dishImage(.init(
            dishID: dish.uuid,
            sortIndex: 2,
            isPrimary: false,
            dateAdded: image.dateAdded
        ))
        try HouseholdRecordApplier.apply(
            payloadData: HouseholdRecordCodec.encode(payload),
            identity: .init(type: .dishImage, uuid: image.uuid),
            modifiedAt: .now,
            assetData: nil,
            household: household,
            context: context
        )

        #expect(image.data == Data([7, 8, 9]))
        #expect(image.sortIndex == 2)
        #expect(!image.isPrimary)
    }

    @Test func assetBackedRecordCannotUploadWithoutBytes() throws {
        let identity = HouseholdRecordIdentity(type: .dishImage, uuid: UUID())
        let payload = HouseholdRecordPayload.dishImage(.init(
            dishID: UUID(), sortIndex: 0, isPrimary: true, dateAdded: .now
        ))
        let snapshot = LocalHouseholdRecord(
            identity: identity,
            householdID: UUID(),
            modifiedAt: .now,
            payloadData: try HouseholdRecordCodec.encode(payload),
            assetData: nil
        )

        #expect(throws: HouseholdRecordCodecError.self) {
            try HouseholdRecordCodec.makeRecord(
                from: snapshot,
                zoneID: CKRecordZone.ID(zoneName: "test")
            )
        }
    }

    private func planValue(date: Date, meal: String, note: String?) -> MealPlanBackup.PortableEntry {
        .init(
            uuid: UUID(), date: date, mealKey: meal, dishUUID: nil, servingsOverride: nil,
            note: note, sortIndex: 0, reactionRaw: nil, skipped: false, prepReminder: false,
            plannedByName: nil, lastEditedByName: nil, lastEditedDate: nil,
            isEatingOut: false, placeName: nil, placeAddress: nil,
            placeLatitude: nil, placeLongitude: nil, routineUUID: nil
        )
    }

    private func shoppingValue(amount: Double, checked: Bool) -> MealPlanBackup.PortableShoppingItem {
        .init(
            uuid: UUID(), name: "Milk", normalizedName: "milk", categoryRaw: IngredientCategory.dairy.rawValue,
            customAisleName: nil, canonicalValue: amount, canonicalDimensionRaw: QuantityDimension.volume.rawValue,
            displayText: nil, displayUnit: "l", isChecked: checked, isManual: true,
            isApproximate: false, sortIndex: 0, rangeStart: nil, rangeEnd: nil,
            sourceDishNames: [], dateCreated: .now, ingredientKey: nil
        )
    }
}
