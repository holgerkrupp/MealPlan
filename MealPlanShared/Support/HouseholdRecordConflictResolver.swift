import CloudKit
import Foundation

struct HouseholdRecordResolution: Sendable {
    var payloadData: Data
    var modifiedAt: Date
    var shouldUpload: Bool
}

@MainActor
enum HouseholdRecordConflictResolver {
    /// Resolves a fetched/server record against the current local record. The
    /// return value is always applied locally; `shouldUpload` asks the engine
    /// to submit the merged/local winner using the server change tag.
    static func resolve(local: LocalHouseholdRecord?, server: CKRecord) throws -> HouseholdRecordResolution {
        let serverData = try payloadData(server)
        let serverDate = HouseholdRecordCodec.modifiedAt(of: server)
        guard let local else {
            return .init(payloadData: serverData, modifiedAt: serverDate, shouldUpload: false)
        }
        let localPayload = try HouseholdRecordCodec.decode(local.payloadData)
        let serverPayload = try HouseholdRecordCodec.decode(serverData)

        switch (localPayload, serverPayload) {
        case (.planEntry(let lhs), .planEntry(let rhs)):
            let merged = merge(lhs, rhs)
            let data = try HouseholdRecordCodec.encode(HouseholdRecordPayload.planEntry(merged))
            return .init(
                payloadData: data,
                modifiedAt: max(local.modifiedAt, serverDate),
                shouldUpload: data != serverData
            )
        case (.shoppingItem(let lhs), .shoppingItem(let rhs)):
            let merged = merge(lhs, rhs)
            let data = try HouseholdRecordCodec.encode(HouseholdRecordPayload.shoppingItem(merged))
            return .init(
                payloadData: data,
                modifiedAt: max(local.modifiedAt, serverDate),
                shouldUpload: data != serverData
            )
        default:
            if local.modifiedAt > serverDate {
                return .init(payloadData: local.payloadData, modifiedAt: local.modifiedAt, shouldUpload: true)
            }
            return .init(payloadData: serverData, modifiedAt: serverDate, shouldUpload: false)
        }
    }

    static func merge(_ lhs: PlanEntryPayload, _ rhs: PlanEntryPayload) -> PlanEntryPayload {
        let placement = lhs.placementModifiedAt >= rhs.placementModifiedAt ? lhs : rhs
        let content = lhs.contentModifiedAt >= rhs.contentModifiedAt ? lhs : rhs
        var value = content.value
        value.date = placement.value.date
        value.mealKey = placement.value.mealKey
        value.sortIndex = placement.value.sortIndex
        return PlanEntryPayload(
            value: value,
            placementModifiedAt: max(lhs.placementModifiedAt, rhs.placementModifiedAt),
            contentModifiedAt: max(lhs.contentModifiedAt, rhs.contentModifiedAt)
        )
    }

    static func merge(_ lhs: ShoppingItemPayload, _ rhs: ShoppingItemPayload) -> ShoppingItemPayload {
        let content = lhs.contentModifiedAt >= rhs.contentModifiedAt ? lhs : rhs
        let check: ShoppingItemPayload
        if lhs.checkStateModifiedAt == rhs.checkStateModifiedAt {
            check = lhs.value.isChecked ? lhs : rhs
        } else {
            check = lhs.checkStateModifiedAt > rhs.checkStateModifiedAt ? lhs : rhs
        }
        var value = content.value
        value.isChecked = check.value.isChecked
        return ShoppingItemPayload(
            value: value,
            ingredientID: content.ingredientID,
            contentModifiedAt: max(lhs.contentModifiedAt, rhs.contentModifiedAt),
            checkStateModifiedAt: max(lhs.checkStateModifiedAt, rhs.checkStateModifiedAt)
        )
    }

    private static func payloadData(_ record: CKRecord) throws -> Data {
        guard let data = record[HouseholdRecordCodec.payloadKey] as? Data else {
            throw HouseholdRecordCodecError.missingPayload
        }
        return data
    }
}
