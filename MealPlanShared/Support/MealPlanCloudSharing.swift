import CloudKit
import CollaborationCloudKit
import CollaborationCore
import SwiftData

@MainActor
enum MealPlanSharePreparationMode {
    case invitation
    case management
}

@MainActor
enum MealPlanSharePreparation {
    /// Invitations flush local edits before opening Apple's invite flow.
    /// Management may skip that flush only after confirming the share exists.
    static func run(
        mode: MealPlanSharePreparationMode,
        existingShare: @MainActor () async throws -> CKShare?,
        synchronize: @MainActor () async throws -> Void
    ) async throws {
        switch mode {
        case .invitation:
            try await synchronize()
        case .management:
            guard try await existingShare() == nil else { return }
            try await synchronize()
        }
    }
}

@MainActor
enum MealPlanCloudSharing {
    static func service(
        for household: Household,
        context: ModelContext,
        preparationMode: MealPlanSharePreparationMode = .invitation
    ) async throws -> CloudKitShareLifecycleService {
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
            // Invitations always flush pending local edits. The management
            // service skips that work only after confirming the authoritative
            // share exists; CloudKitCollaborationKit still handles reuse and
            // legacy public-link hardening after this callback.
            try await MealPlanSharePreparation.run(
                mode: preparationMode,
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

    static func managementService(for household: Household, context: ModelContext) async throws -> CloudKitShareLifecycleService {
        try await service(for: household, context: context, preparationMode: .management)
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
