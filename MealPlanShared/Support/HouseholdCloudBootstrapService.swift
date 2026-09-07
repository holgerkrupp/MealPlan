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
            context: context,
            progress: progress
        )
    }

    static func restoreOwnedHousehold(
        in zoneID: CKRecordZone.ID,
        shareRecordName: String?,
        replacing localHousehold: Household?,
        mergeRecipes: Bool,
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
            if mergeRecipes {
                HouseholdCloudSharingService.mergeDishes(from: localHousehold, into: household)
            }
            context.delete(localHousehold)
        }
        try context.save()
        NotificationCenter.default.post(name: .mealPlanDataDidChange, object: nil)
        return household
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
