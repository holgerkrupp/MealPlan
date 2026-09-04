import CloudKit
import Foundation
import Testing
@testable import MealPlan

@MainActor
struct HouseholdRecordSyncTests {
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
