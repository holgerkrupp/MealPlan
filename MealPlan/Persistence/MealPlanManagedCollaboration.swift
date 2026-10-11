@preconcurrency import CloudKit
@preconcurrency import CoreData
import CollaborationCore
import CollaborationCoreData
import CollaborationDiagnostics
import CollaborationUI
import Foundation

/// MealPlan's host adapter for the reusable collaboration package. Construction
/// is deliberately explicit: callers must load a CloudKit-enabled managed
/// persistence instance first, and share creation remains an explicit user action.
@MainActor
final class MealPlanManagedCollaboration {
    let sharing: ManagedSharingService
    let invitations: InvitationAcceptanceCoordinator
    let eventMonitor: ManagedContainerEventMonitor
    let container: NSPersistentCloudKitContainer
    let cloudKitContainer: CKContainer
    let privateStore: NSPersistentStore
    let sharedStore: NSPersistentStore
    private let graphPreflight: MealPlanShareGraphPreflight

    init(persistence: ManagedHouseholdPersistence) throws {
        guard persistence.isLoaded, persistence.cloudKitEnabled else {
            throw MealPlanManagedCollaborationError.managedStoresUnavailable
        }
        container = persistence.container
        privateStore = try persistence.persistentStore(for: .private)
        sharedStore = try persistence.persistentStore(for: .shared)
        cloudKitContainer = CKContainer(identifier: SharedStore.cloudKitContainerID)

        let configuration = CollaborationConfiguration(
            containerIdentifier: SharedStore.cloudKitContainerID,
            environment: Self.packageEnvironment(BuildEnvironment.cloudKit)
        )
        let resolver = MealPlanShareRootResolver(
            context: persistence.container.viewContext,
            privateStore: privateStore
        )
        let graphPreflight = try MealPlanShareGraphPreflight(
            container: persistence.container,
            privateStore: privateStore
        )
        self.graphPreflight = graphPreflight
        sharing = try ManagedSharingService(
            configuration: configuration,
            container: persistence.container,
            privateStore: privateStore,
            sharedStore: sharedStore,
            rootResolver: resolver,
            preflight: graphPreflight
        )
        invitations = InvitationAcceptanceCoordinator(
            containerIdentifier: configuration.containerIdentifier
        ) { [sharing] metadata in
            try await sharing.accept(metadata)
        }
        eventMonitor = ManagedContainerEventMonitor(container: persistence.container) { event in
            NotificationCenter.default.post(
                name: .mealPlanManagedCollaborationEvent,
                object: event
            )
        }
    }

    func makeSession(for household: Household) -> ManagedCollaborationSession {
        ManagedCollaborationSession(
            rootID: household.uuid.uuidString,
            title: household.name,
            service: sharing
        )
    }

    func makeVerifiedSession(for household: Household) throws -> ManagedCollaborationSession {
        guard isVerifiedManagedHousehold(household.uuid) else {
            throw MealPlanManagedCollaborationError.householdNotFound
        }
        return makeSession(for: household)
    }

    func isVerifiedManagedHousehold(_ householdID: UUID) -> Bool {
        guard let objectID = try? sharing.resolveRootObjectID(householdID.uuidString),
              let root = try? container.viewContext.existingObject(with: objectID),
              root.value(forKey: "managedMigrationPhaseRaw") as? String == "verified",
              let count = root.value(forKey: "managedGraphObjectCount") as? NSNumber,
              count.intValue > 0 else { return false }
        // The durable marker is written only after migration validates every
        // object and relationship. Full share-boundary validation runs on a
        // background context when the person explicitly starts an invitation.
        // Do not rescan the complete graph on the main actor during view refresh.
        return true
    }

    func reinviteNoticeWasDismissed(for householdID: UUID) -> Bool {
        guard let objectID = try? sharing.resolveRootObjectID(householdID.uuidString),
              let root = try? container.viewContext.existingObject(with: objectID) else { return false }
        return root.value(forKey: "reinviteNoticeDismissedAt") as? Date != nil
    }

    func dismissReinviteNotice(for householdID: UUID) throws {
        let objectID = try sharing.resolveRootObjectID(householdID.uuidString)
        let context = container.viewContext
        let root = try context.existingObject(with: objectID)
        root.setValue(Date.now, forKey: "reinviteNoticeDismissedAt")
        if context.hasChanges { try context.save() }
        try ManagedHouseholdRolloutAuthority.shared.markReinviteNoticeDismissed(for: householdID)
    }

    func prepareVerifiedShare(rootID: String) async throws -> CKShare {
        guard let householdID = UUID(uuidString: rootID), isVerifiedManagedHousehold(householdID) else {
            throw MealPlanManagedCollaborationError.householdNotFound
        }
        return try await sharing.prepareShare(rootID: rootID)
    }

    func existingShare(for household: Household) throws -> CKShare? {
        try sharing.existingShare(for: sharing.resolveRootObjectID(household.uuid.uuidString))
    }

    func effectiveAccess(for household: Household) -> AccessLevel {
        guard let objectID = try? sharing.resolveRootObjectID(household.uuid.uuidString) else {
            return .unavailable
        }
        return sharing.effectiveAccess(for: objectID).level
    }

    func receive(_ metadata: CKShare.Metadata) async throws -> InvitationDeliveryDisposition {
        try await invitations.receive(metadata)
    }

    func storesDidLoad() async -> [InvitationProcessingResult] {
        await invitations.storesDidLoad()
    }

    func retryPendingInvitations() async -> [InvitationProcessingResult] {
        await invitations.processPendingInvitations()
    }

    func persistUpdatedShare(_ share: CKShare) async throws {
        try await sharing.persistUpdatedShare(share, in: privateStore)
    }

    private static func packageEnvironment(_ environment: CloudKitEnvironment) -> CollaborationEnvironment {
        switch environment {
        case .development: .development
        case .production: .production
        case .unknown: .unknown
        }
    }
}

@MainActor
private final class MealPlanShareRootResolver: ManagedShareRootResolving {
    private let context: NSManagedObjectContext
    private let privateStore: NSPersistentStore

    init(context: NSManagedObjectContext, privateStore: NSPersistentStore) {
        self.context = context
        self.privateStore = privateStore
    }

    func resolveObjectID(for rootID: String) throws -> NSManagedObjectID {
        guard let uuid = UUID(uuidString: rootID) else {
            throw MealPlanManagedCollaborationError.invalidHouseholdID
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: ManagedHouseholdEntity.household.rawValue)
        request.predicate = NSPredicate(format: "uuid == %@", uuid as NSUUID)
        request.affectedStores = [privateStore]
        let matches = try context.fetch(request)
        guard matches.count == 1, let household = matches.first else {
            throw MealPlanManagedCollaborationError.householdNotFound
        }
        guard !household.objectID.isTemporaryID,
              household.objectID.persistentStore === privateStore,
              household.value(forKey: "uuid") as? UUID == uuid else {
            throw MealPlanManagedCollaborationError.invalidRootStore
        }
        return household.objectID
    }

    func shareBoundary(for rootID: String) -> ShareGraphBoundary {
        ShareGraphBoundary(rootID: rootID, scope: .workspace, identifier: rootID)
    }
}

private final class MealPlanShareGraphPreflight: ManagedSharePreflighting, @unchecked Sendable {
    private let container: NSPersistentCloudKitContainer
    private let privateStoreURL: URL

    init(container: NSPersistentCloudKitContainer, privateStore: NSPersistentStore) throws {
        guard let url = privateStore.url else {
            throw MealPlanManagedCollaborationError.managedStoresUnavailable
        }
        self.container = container
        privateStoreURL = url
    }

    func validateShareGraph(rootID: String, boundary: ShareGraphBoundary) async throws -> ShareGraphPreflightResult {
        guard boundary.scope == .workspace,
              boundary.rootID == rootID,
              boundary.identifier == rootID,
              UUID(uuidString: rootID) != nil else {
            throw MealPlanManagedCollaborationError.invalidHouseholdID
        }
        let context = container.newBackgroundContext()
        let privateStoreURL = self.privateStoreURL
        let count = try await context.perform {
            try Self.validate(rootID: rootID, context: context, privateStoreURL: privateStoreURL)
        }
        return ShareGraphPreflightResult(validatedObjectCount: count)
    }

    private static func validate(
        rootID: String,
        context: NSManagedObjectContext,
        privateStoreURL: URL
    ) throws -> Int {
        guard let householdID = UUID(uuidString: rootID) else {
            throw MealPlanManagedCollaborationError.invalidHouseholdID
        }
        let coordinator = context.persistentStoreCoordinator
        guard let privateStore = coordinator?.persistentStores.first(where: { $0.url == privateStoreURL }) else {
            throw MealPlanManagedCollaborationError.managedStoresUnavailable
        }
        let rootRequest = NSFetchRequest<NSManagedObject>(entityName: ManagedHouseholdEntity.household.rawValue)
        rootRequest.predicate = NSPredicate(format: "uuid == %@", householdID as NSUUID)
        rootRequest.affectedStores = [privateStore]
        let roots = try context.fetch(rootRequest)
        guard roots.count == 1, let root = roots.first else {
            throw MealPlanManagedCollaborationError.householdNotFound
        }

        let allowedEntities = Set(ManagedHouseholdEntity.allCases.map(\.rawValue))
        var pending = [root]
        var seen: Set<NSManagedObjectID> = []
        var seenUUIDsByEntity: [String: Set<UUID>] = [:]

        while let object = pending.popLast() {
            guard seen.insert(object.objectID).inserted else { continue }
            let entityName = object.entity.name ?? ""
            guard allowedEntities.contains(entityName) else {
                throw MealPlanManagedCollaborationError.unexpectedEntity
            }
            guard object.managedObjectContext === context,
                  object.objectID.persistentStore === privateStore,
                  object.objectID.persistentStore?.url == privateStoreURL else {
                throw MealPlanManagedCollaborationError.objectOutsidePrivateStore
            }
            guard let uuid = object.value(forKey: "uuid") as? UUID else {
                throw MealPlanManagedCollaborationError.missingStableIdentity
            }
            guard seenUUIDsByEntity[entityName, default: []].insert(uuid).inserted else {
                throw MealPlanManagedCollaborationError.duplicateStableIdentity
            }
            guard Self.householdID(for: object) == householdID else {
                throw MealPlanManagedCollaborationError.crossHouseholdRelationship
            }

            for relationship in object.entity.relationshipsByName.values {
                guard let value = object.value(forKey: relationship.name) else {
                    if Self.requiredRelationships[entityName, default: []].contains(relationship.name) {
                        throw MealPlanManagedCollaborationError.incompleteHouseholdGraph
                    }
                    continue
                }
                let related: [NSManagedObject]
                if relationship.isToMany {
                    if let set = value as? NSSet {
                        related = set.allObjects.compactMap { $0 as? NSManagedObject }
                    } else if let array = value as? [NSManagedObject] {
                        related = array
                    } else {
                        related = []
                    }
                } else if let object = value as? NSManagedObject {
                    related = [object]
                } else {
                    related = []
                }
                if related.isEmpty,
                   !relationship.isOptional,
                   Self.requiredRelationships[entityName, default: []].contains(relationship.name) {
                    throw MealPlanManagedCollaborationError.incompleteHouseholdGraph
                }
                pending.append(contentsOf: related)
            }
        }
        return seen.count
    }

    private static let requiredRelationships: [String: Set<String>] = [
        ManagedHouseholdEntity.dish.rawValue: ["household"],
        ManagedHouseholdEntity.dishImage.rawValue: ["dish"],
        ManagedHouseholdEntity.ingredient.rawValue: ["household"],
        ManagedHouseholdEntity.ingredientAlias.rawValue: ["ingredient"],
        ManagedHouseholdEntity.dishIngredient.rawValue: ["dish", "ingredient"],
        ManagedHouseholdEntity.mealPlanEntry.rawValue: ["household"],
        ManagedHouseholdEntity.mealRoutine.rawValue: ["household", "dish"],
        ManagedHouseholdEntity.shoppingListItem.rawValue: ["household"],
        ManagedHouseholdEntity.weekTemplate.rawValue: ["household"],
        ManagedHouseholdEntity.recipeFeed.rawValue: ["household"],
        ManagedHouseholdEntity.recipeFeedItem.rawValue: ["feed"],
    ]

    private static func householdID(for object: NSManagedObject) -> UUID? {
        if object.entity.name == ManagedHouseholdEntity.household.rawValue {
            return object.value(forKey: "uuid") as? UUID
        }
        if let household = object.value(forKey: "household") as? NSManagedObject {
            return household.value(forKey: "uuid") as? UUID
        }
        for relationshipName in ["dish", "ingredient", "template", "feed", "entry"] {
            guard let related = object.value(forKey: relationshipName) as? NSManagedObject else { continue }
            if related.entity.name == ManagedHouseholdEntity.household.rawValue {
                return related.value(forKey: "uuid") as? UUID
            }
            if let household = related.value(forKey: "household") as? NSManagedObject {
                return household.value(forKey: "uuid") as? UUID
            }
        }
        return nil
    }
}

enum MealPlanManagedCollaborationError: LocalizedError {
    case managedStoresUnavailable
    case invalidHouseholdID
    case householdNotFound
    case invalidRootStore
    case unexpectedEntity
    case objectOutsidePrivateStore
    case missingStableIdentity
    case duplicateStableIdentity
    case crossHouseholdRelationship
    case incompleteHouseholdGraph

    var errorDescription: String? {
        switch self {
        case .managedStoresUnavailable: "Managed household sharing is not ready yet."
        case .invalidHouseholdID: "This household cannot be shared yet."
        case .householdNotFound: "The verified household was not found in the private store."
        case .invalidRootStore: "Only the canonical private household can be shared."
        case .unexpectedEntity: "The household contains an unsupported record type."
        case .objectOutsidePrivateStore: "The household graph includes data outside its private store."
        case .missingStableIdentity: "The household graph contains a record without a stable identity."
        case .duplicateStableIdentity: "The household graph contains duplicate record identities."
        case .crossHouseholdRelationship: "The household graph contains a link to another household."
        case .incompleteHouseholdGraph: "The household graph has an incomplete relationship."
        }
    }
}

extension Notification.Name {
    static let mealPlanManagedCollaborationEvent = Notification.Name("MealPlan.ManagedCollaborationEvent")
}
