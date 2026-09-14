import CloudKit
import Foundation
import SwiftData

enum HouseholdCloudDownloadProgress: Equatable, Sendable {
    case lookingForHousehold
    case connecting
    case downloading(Int)
    case importing(completed: Int, total: Int)
}

/// Finds and restores the household that already belongs to the current
/// iCloud account. A second device using the owner's Apple Account must read
/// the owner's private database; CloudKit does not allow that account to
/// accept its own `CKShare` into the shared database.
@MainActor
enum HouseholdCloudBootstrapService {
    private struct Candidate {
        let zone: CKRecordZone
        let dateCreated: Date

        var isShared: Bool { zone.share != nil }
    }

    static func restoreOwnedHouseholdIfAvailable(
        replacing localHousehold: Household?,
        context: ModelContext,
        progress: @escaping @MainActor (HouseholdCloudDownloadProgress) -> Void
    ) async throws -> Household? {
        progress(.lookingForHousehold)
        let database = CKContainer(identifier: SharedStore.cloudKitContainerID).privateCloudDatabase
        let zones = try await database.allRecordZones()
        var candidates: [Candidate] = []

        for zone in zones {
            guard let householdID = HouseholdShareLocator.householdID(from: zone.zoneID) else { continue }
            let rootID = CKRecord.ID(
                recordName: HouseholdRecordIdentity(type: .household, uuid: householdID).recordName,
                zoneID: zone.zoneID
            )
            guard let record = try? await fetchRecord(rootID, from: database),
                  let data = record[HouseholdRecordCodec.payloadKey] as? Data,
                  case .household(let payload) = try? HouseholdRecordCodec.decode(data) else { continue }
            candidates.append(.init(zone: zone, dateCreated: payload.dateCreated))
        }

        // A zone with a CKShare is the household the user deliberately chose
        // to share. Otherwise the oldest household is the original one; newer
        // unshared zones are usually placeholders created by older app builds
        // on additional devices.
        guard let candidate = candidates.sorted(by: candidateComesFirst).first else { return nil }
        return try await restoreOwnedHousehold(
            in: candidate.zone.zoneID,
            shareRecordName: candidate.zone.share?.recordID.recordName,
            replacing: localHousehold,
            mergeRecipes: false,
            adoptingLocalContent: true,
            context: context,
            progress: progress
        )
    }

    /// - Parameter adoptingLocalContent: The launch-time lookup runs behind an
    ///   ordinary, usable household, so by the time it replaces that
    ///   household the person may have started filling it. When set,
    ///   everything in it moves into the restored household first — see
    ///   `adoptContent(of:into:)` — instead of going down with it.
    static func restoreOwnedHousehold(
        in zoneID: CKRecordZone.ID,
        shareRecordName: String?,
        replacing localHousehold: Household?,
        mergeRecipes: Bool,
        adoptingLocalContent: Bool = false,
        context: ModelContext,
        progress: @escaping @MainActor (HouseholdCloudDownloadProgress) -> Void
    ) async throws -> Household {
        guard let householdID = HouseholdShareLocator.householdID(from: zoneID) else {
            throw HouseholdSharingError.missingRootRecord
        }

        progress(.connecting)
        let database = CKContainer(identifier: SharedStore.cloudKitContainerID).privateCloudDatabase
        let records = try await fetchAllRecords(in: zoneID, from: database, progress: progress)
        guard records.contains(where: {
            HouseholdRecordIdentity(recordType: $0.recordType, recordName: $0.recordID.recordName)?.type == .household
        }) else {
            throw HouseholdSharingError.missingRootRecord
        }

        // Stop an engine that may currently be attached to a placeholder zone
        // before changing the active household underneath it.
        await HouseholdRecordSyncService.shared.stop()

        let households = (try? context.fetch(FetchDescriptor<Household>())) ?? []
        let existing = households.first { $0.uuid == householdID }
        let household = existing ?? Household()
        if existing == nil {
            household.uuid = householdID
            context.insert(household)
        }

        let applicable = records.compactMap { record -> (CKRecord, HouseholdRecordIdentity)? in
            guard let identity = HouseholdRecordIdentity(recordType: record.recordType, recordName: record.recordID.recordName),
                  record[HouseholdRecordCodec.payloadKey] is Data else { return nil }
            return (record, identity)
        }.sorted {
            ($0.1.type.applyPriority, $0.1.recordName) < ($1.1.type.applyPriority, $1.1.recordName)
        }

        for (offset, item) in applicable.enumerated() {
            let (record, identity) = item
            let data = record[HouseholdRecordCodec.payloadKey] as! Data
            let asset = (record[HouseholdRecordCodec.assetKey] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
            try HouseholdRecordApplier.apply(
                payloadData: data,
                identity: identity,
                modifiedAt: HouseholdRecordCodec.modifiedAt(of: record),
                assetData: asset,
                household: household,
                context: context
            )
            progress(.importing(completed: offset + 1, total: applicable.count))
        }

        let fetchedShareName = records.compactMap { ($0 as? CKShare)?.recordID.recordName }.first
        let locator = HouseholdShareLocator(
            zoneName: zoneID.zoneName,
            ownerName: zoneID.ownerName,
            shareRecordName: shareRecordName ?? fetchedShareName,
            isOwner: true,
            isReadOnly: false
        )
        household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(locator)

        if let localHousehold, localHousehold.uuid != household.uuid {
            if adoptingLocalContent {
                adoptContent(of: localHousehold, into: household)
            } else if mergeRecipes {
                HouseholdCloudSharingService.mergeDishes(from: localHousehold, into: household)
            }
            context.delete(localHousehold)
        }
        try context.save()
        NotificationCenter.default.post(name: .mealPlanDataDidChange, object: nil)
        return household
    }

    /// Moves what someone created in the placeholder household — dishes and
    /// their ingredients, planned meals, the shopping list, history, routines,
    /// templates, feeds and bookmarks — into the restored one. Only what the
    /// placeholder was seeded with and nobody used (its default meals, unused
    /// pantry staples) is left to be deleted with it; the restored household
    /// has its own.
    static func adoptContent(of placeholder: Household, into household: Household) {
        HouseholdCloudSharingService.mergeDishes(from: placeholder, into: household)

        // Same rule `mergeDishes` applies to a dish's ingredients: join the
        // restored household's ingredient of that name, or move over.
        var ingredientsByName = [String: Ingredient](
            (household.ingredients ?? []).map { ($0.normalizedName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for item in placeholder.shoppingItems ?? [] {
            item.household = household
            guard let ingredient = item.ingredient, ingredient.household === placeholder else { continue }
            if let match = ingredientsByName[ingredient.normalizedName] {
                item.ingredient = match
            } else {
                ingredient.household = household
                ingredientsByName[ingredient.normalizedName] = ingredient
            }
        }

        for entry in placeholder.entries ?? [] { entry.household = household }
        for log in placeholder.cookedLogs ?? [] { log.household = household }
        for routine in placeholder.mealRoutines ?? [] { routine.household = household }
        for template in placeholder.weekTemplates ?? [] { template.household = household }
        for feed in placeholder.recipeFeeds ?? [] { feed.household = household }
        for bookmark in placeholder.recipeBookmarks ?? [] { bookmark.household = household }
    }

    static func candidateComesFirst(_ lhs: CandidateSummary, _ rhs: CandidateSummary) -> Bool {
        if lhs.isShared != rhs.isShared { return lhs.isShared }
        if lhs.dateCreated != rhs.dateCreated { return lhs.dateCreated < rhs.dateCreated }
        return lhs.zoneName < rhs.zoneName
    }

    private static func candidateComesFirst(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        candidateComesFirst(
            .init(zoneName: lhs.zone.zoneID.zoneName, isShared: lhs.isShared, dateCreated: lhs.dateCreated),
            .init(zoneName: rhs.zone.zoneID.zoneName, isShared: rhs.isShared, dateCreated: rhs.dateCreated)
        )
    }

    private static func fetchAllRecords(
        in zoneID: CKRecordZone.ID,
        from database: CKDatabase,
        progress: @escaping @MainActor (HouseholdCloudDownloadProgress) -> Void
    ) async throws -> [CKRecord] {
        var token: CKServerChangeToken?
        var records: [CKRecord] = []
        var moreComing = true
        while moreComing {
            let page = try await database.recordZoneChanges(
                inZoneWith: zoneID,
                since: token,
                desiredKeys: nil,
                resultsLimit: 100
            )
            for result in page.modificationResultsByID.values {
                records.append(try result.get().record)
            }
            token = page.changeToken
            moreComing = page.moreComing
            progress(.downloading(records.count))
        }
        return records
    }

    private static func fetchRecord(_ id: CKRecord.ID, from database: CKDatabase) async throws -> CKRecord {
        let records = try await database.records(for: [id])
        guard let result = records[id] else { throw HouseholdSharingError.cloudKitDidNotReturnRecord }
        return try result.get()
    }
}

/// Small, CloudKit-free projection used to test deterministic candidate
/// selection without manufacturing `CKRecordZone` server objects.
struct CandidateSummary: Equatable, Sendable {
    let zoneName: String
    let isShared: Bool
    let dateCreated: Date
}
