import CloudKit
import CollaborationCloudKit
import CollaborationCore
import SwiftData

@MainActor
enum MealPlanSharePreparation {
    /// Existing zone shares are already synchronized by the app's normal
    /// transport lifecycle. Only a new share needs a full pre-share flush.
    static func run(
        existingShare: @MainActor () async throws -> CKShare?,
        synchronize: @MainActor () async throws -> Void
    ) async throws {
        guard try await existingShare() == nil else { return }
        try await synchronize()
    }
}

@MainActor
enum MealPlanCloudSharing {
    static func service(for household: Household, context: ModelContext) async throws -> CloudKitShareLifecycleService {
        let pool = try await HouseholdRecordSyncService.shared.prepareTransport(household: household, context: context)
        let rootID = household.uuid.uuidString
        let resolver = MealPlanShareRootResolver(context: context)
        let service = CloudKitShareLifecycleService(
            configuration: CollaborationConfiguration(
                containerIdentifier: SharedStore.cloudKitContainerID,
                environment: collaborationEnvironment
            ),
            rootResolver: resolver,
            syncEngines: pool
        )
        service.onPreparingShare = { [weak service] requestedRootID in
            guard requestedRootID == rootID else { return }
            // Share preparation also runs when the owner reopens Apple's
            // invitation UI or when a legacy public-link share is hardened.
            // Existing shares already have a complete CloudKit zone, so
            // flushing the full local household again only adds latency. A
            // first share still needs its records uploaded before the
            // zone-wide CKShare can be created.
            try await MealPlanSharePreparation.run(
                existingShare: {
                    guard let service else { return nil }
                    return try await service.existingShare(rootID: rootID)
                },
                synchronize: {
                    try await HouseholdRecordSyncService.shared.synchronize(household: household, context: context)
                }
            )
        }
        service.onSharePrepared = { share in
            var updated = HouseholdShareLocator.decode(household.cloudKitShareIdentifier)
                ?? .solo(householdID: household.uuid)
            guard updated.isOwner else { return }
            updated.shareRecordName = share.recordID.recordName
            household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(updated)
            try context.save()
        }
        return service
    }

    private static var collaborationEnvironment: CollaborationEnvironment {
        switch BuildEnvironment.cloudKit {
        case .development: .development
        case .production: .production
        case .unknown: .unknown
        }
    }
}

@MainActor
private final class MealPlanShareRootResolver: CloudKitShareRootResolving {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func plan(for rootID: String) throws -> CloudKitShareRootPlan {
        guard let householdID = UUID(uuidString: rootID) else {
            throw CloudKitShareBackendError.rootResolverUnavailable
        }
        let descriptor = FetchDescriptor<Household>(predicate: #Predicate { $0.uuid == householdID })
        guard let household = try context.fetch(descriptor).first else {
            throw CloudKitShareBackendError.rootResolverUnavailable
        }
        let locator = HouseholdShareLocator.decode(household.cloudKitShareIdentifier)
            ?? .solo(householdID: household.uuid)
        let root = try HouseholdRecordCodec.rootRecord(for: household, zoneID: locator.zoneID)
        var shareFields: [String: CKRecordValue] = [
            "householdID": household.uuid.uuidString as CKRecordValue,
            CKShare.SystemFieldKey.shareType: "de.holgerkrupp.mealplan.household" as CKRecordValue,
        ]
        if BuildEnvironment.cloudKit != .unknown {
            shareFields["cloudEnvironment"] = BuildEnvironment.cloudKit.rawValue as CKRecordValue
        }
        return CloudKitShareRootPlan(
            rootID: rootID,
            title: household.name,
            rootRecord: root,
            topology: .recordZone,
            shareFields: shareFields
        )
    }
}
