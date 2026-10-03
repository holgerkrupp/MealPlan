import CloudKit
import Foundation

struct HouseholdRecordResolution: Sendable {
    var payloadData: Data
    var modifiedAt: Date
    var shouldUpload: Bool
    /// The bytes that belong to the winning version of an asset-backed
    /// record. A missing CloudKit asset is never a request to clear a photo;
    /// photos are removed by deleting their dedicated record.
    var assetData: Data?
}

@MainActor
enum HouseholdRecordConflictResolver {
    /// A tombstone carries the only reliable server-side deletion clock. A
    /// newer local record is an edit/add and must be uploaded instead of
    /// being removed by the stale delete.
    static func shouldPreserveLocalForDeletion(
        local: LocalHouseholdRecord?,
        deletedAt: Date
    ) -> Bool {
        local.map { $0.modifiedAt > deletedAt } ?? false
    }

    /// Raw CK deletions have no deletion timestamp. Preserve anything that is
    /// pending or differs from the last acknowledged server value.
    static func shouldPreserveLocalForRawDeletion(
        local: LocalHouseholdRecord?,
        acknowledgedFingerprint: String?,
        isPending: Bool
    ) -> Bool {
        guard let local else { return false }
        return isPending || acknowledgedFingerprint != local.fingerprint
    }

    /// Resolves a fetched/server record against the current local record. The
    /// return value is always applied locally; `shouldUpload` asks the engine
    /// to submit the merged/local winner using the server change tag.
    static func resolve(
        local: LocalHouseholdRecord?,
        server: CKRecord,
        serverAssetData: Data? = nil,
        serverHasAsset: Bool = false
    ) throws -> HouseholdRecordResolution {
        let serverData = try payloadData(server)
        let serverDate = HouseholdRecordCodec.modifiedAt(of: server)
        guard let local else {
            return .init(
                payloadData: serverData,
                modifiedAt: serverDate,
                shouldUpload: false,
                assetData: serverAssetData
            )
        }
        let localPayload = try HouseholdRecordCodec.decode(local.payloadData)
        let serverPayload = try HouseholdRecordCodec.decode(serverData)

        switch (localPayload, serverPayload) {
        case (.member(let lhs), .member(let rhs)):
            let merged = merge(lhs, rhs, localModifiedAt: local.modifiedAt, serverModifiedAt: serverDate)
            let data = try HouseholdRecordCodec.encode(HouseholdRecordPayload.member(merged))
            return .init(
                payloadData: data,
                modifiedAt: max(local.modifiedAt, serverDate),
                shouldUpload: data != serverData,
                assetData: nil
            )
        case (.planEntry(let lhs), .planEntry(let rhs)):
            let merged = merge(lhs, rhs)
            let data = try HouseholdRecordCodec.encode(HouseholdRecordPayload.planEntry(merged))
            return .init(
                payloadData: data,
                modifiedAt: max(local.modifiedAt, serverDate),
                shouldUpload: data != serverData,
                assetData: nil
            )
        case (.shoppingItem(let lhs), .shoppingItem(let rhs)):
            let merged = merge(lhs, rhs)
            let data = try HouseholdRecordCodec.encode(HouseholdRecordPayload.shoppingItem(merged))
            return .init(
                payloadData: data,
                modifiedAt: max(local.modifiedAt, serverDate),
                shouldUpload: data != serverData,
                assetData: nil
            )
        default:
            if local.modifiedAt > serverDate {
                return .init(
                    payloadData: local.payloadData,
                    modifiedAt: local.modifiedAt,
                    shouldUpload: true,
                    assetData: local.assetData ?? serverAssetData
                )
            }
            return .init(
                payloadData: serverData,
                modifiedAt: serverDate,
                // Repair an older image record whose asset was accidentally
                // cleared, but do not overwrite an asset that merely failed
                // to download during this fetch.
                shouldUpload: !serverHasAsset && local.assetData != nil,
                assetData: serverAssetData ?? local.assetData
            )
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

    /// `CKShare` metadata and food preferences are unrelated conflict domains.
    /// Older payloads have no per-domain clocks, so their record timestamp is
    /// used conservatively for both domains during the silent upgrade path.
    static func merge(
        _ lhs: MemberPayload,
        _ rhs: MemberPayload,
        localModifiedAt: Date,
        serverModifiedAt: Date
    ) -> MemberPayload {
        let lhsMetadata = lhs.shareMetadataModifiedAt ?? localModifiedAt
        let rhsMetadata = rhs.shareMetadataModifiedAt ?? serverModifiedAt
        let lhsProfile = lhs.profileModifiedAt ?? localModifiedAt
        let rhsProfile = rhs.profileModifiedAt ?? serverModifiedAt
        let metadata = lhsMetadata >= rhsMetadata ? lhs : rhs
        let profile = lhsProfile >= rhsProfile ? lhs : rhs
        return .init(
            name: metadata.name,
            roleRaw: metadata.roleRaw,
            dateAdded: metadata.dateAdded,
            cloudKitParticipantID: metadata.cloudKitParticipantID,
            isActive: metadata.isActive,
            allergies: profile.allergies,
            mustAvoidIngredients: profile.mustAvoidIngredients,
            dietaryPatterns: profile.dietaryPatterns,
            dislikes: profile.dislikes,
            favorites: profile.favorites,
            preferredCuisines: profile.preferredCuisines,
            spiceTolerance: profile.spiceTolerance,
            shareMetadataModifiedAt: max(lhsMetadata, rhsMetadata),
            profileModifiedAt: max(lhsProfile, rhsProfile)
        )
    }

    private static func payloadData(_ record: CKRecord) throws -> Data {
        guard let data = record[HouseholdRecordCodec.payloadKey] as? Data else {
            throw HouseholdRecordCodecError.missingPayload
        }
        return data
    }
}
