import CloudKit
import CollaborationCloudKit
import CollaborationCore
import Foundation
import SwiftData

enum HouseholdSharingError: LocalizedError {
    case cloudKitUnavailable
    case invalidInvitation
    case invitationNotFound
    case notInvited
    case missingRootRecord
    case cloudKitDidNotReturnRecord
    case readOnlyHousehold
    case differentCloudKitEnvironment(source: String, target: String)
    /// This device's Apple Account is no longer on the household's share.
    /// `RootView` answers it by moving to a household of its own.
    case accessRemoved

    var errorDescription: String? {
        switch self {
        case .cloudKitUnavailable: String(localized: "iCloud sharing is unavailable on this device.")
        case .invalidInvitation: String(localized: "This invitation does not belong to MealPlan. Ask the owner to send a new invitation from the app.")
        case .invitationNotFound: String(localized: "This invitation no longer exists or was created in a different iCloud environment. Install MealPlan from the same source (Xcode, TestFlight, or App Store) on both phones, then send a new invitation.")
        case .notInvited: String(localized: "This invitation is for a different Apple Account. Ask the household owner to share it with the account on this device.")
        case .missingRootRecord: String(localized: "The shared household could not be found.")
        case .cloudKitDidNotReturnRecord: String(localized: "iCloud did not return the saved collaboration record.")
        case .readOnlyHousehold: String(localized: "This household is view only. Ask its owner for edit access to make changes.")
        case .differentCloudKitEnvironment(let source, let target): "This invitation belongs to the " + source + " iCloud environment, but this app uses " + target + ". Install the same build source on both devices, or restore the backup into the target environment before inviting again."
        case .accessRemoved: String(localized: "You no longer have access to this household.")
        }
    }
}

extension Notification.Name {
    static let mealPlanDidReceiveCloudShare = Notification.Name("MealPlanDidReceiveCloudShare")
}

@MainActor
final class HouseholdShareInvitationInbox {
    static let shared = HouseholdShareInvitationInbox()
    private var pending: [CKShare.Metadata] = []
    /// A share URL can reach us through more than one UIKit/SwiftUI lifecycle
    /// hook. Keep its key for the lifetime of the process so two callbacks
    /// cannot race two `CKContainer.accept` operations for the same invite.
    private var deliveryGate = CloudShareDeliveryGate()

    func enqueue(_ metadata: CKShare.Metadata) {
        guard deliveryGate.shouldDeliver(deliveryKey(for: metadata)) else { return }
        pending.append(metadata)
        NotificationCenter.default.post(name: .mealPlanDidReceiveCloudShare, object: nil)
    }

    func drain() -> [CKShare.Metadata] {
        defer { pending.removeAll() }
        return pending
    }

    /// A failed or deliberately cancelled join may be attempted again by
    /// opening the link once more. Successful deliveries remain deduplicated
    /// until the next process launch.
    func allowRedelivery(of metadata: CKShare.Metadata) {
        deliveryGate.allowRedelivery(deliveryKey(for: metadata))
    }

    private func deliveryKey(for metadata: CKShare.Metadata) -> String {
        let id = metadata.share.recordID
        return [
            metadata.containerIdentifier,
            id.zoneID.ownerName,
            id.zoneID.zoneName,
            id.recordName,
        ].joined(separator: "|")
    }
}

/// Small value-type core for the invitation inbox's at-most-once delivery.
/// Kept separate from `CKShare.Metadata`, which has no public initializer, so
/// the race prevention can be covered by a deterministic unit test.
struct CloudShareDeliveryGate {
    private var deliveredKeys: Set<String> = []

    mutating func shouldDeliver(_ key: String) -> Bool {
        deliveredKeys.insert(key).inserted
    }

    mutating func allowRedelivery(_ key: String) {
        deliveredKeys.remove(key)
    }
}

/// Creates zone-wide shares for the same per-record zone used by solo sync.
/// Invitations therefore change access to a household without copying or
/// re-encoding its data.
@MainActor
enum HouseholdCloudSharingService {
    private static let householdIDKey = "householdID"
    private static let cloudEnvironmentKey = "cloudEnvironment"

    static func isOwner(shareIdentifier: String?) -> Bool? {
        HouseholdShareLocator.decode(shareIdentifier)?.isOwner
    }

    /// The local household `accept(_:mergeRecipes:context:)` would replace
    /// (and its `mergeRecipes` option would salvage recipes from) if asked to
    /// join `metadata` right now — so the caller can warn before doing
    /// anything destructive instead of after. `nil` means there's nothing to
    /// warn about: either this device has no household with real content
    /// yet, or its household already *is* the one behind this invitation
    /// (re-opening a link you already accepted just refreshes it).
    ///
    /// Deliberately does no networking — `metadata.share` is already on
    /// hand — so a household that would be lost is never touched unless the
    /// person actually chooses to continue.
    static func localHouseholdAtRisk(ofAccepting metadata: CKShare.Metadata, context: ModelContext) -> Household? {
        let incomingShareRecordName = metadata.share.recordID.recordName
        let households = (try? context.fetch(FetchDescriptor<Household>())) ?? []
        return households.first { household in
            guard !(household.dishes ?? []).isEmpty || !(household.entries ?? []).isEmpty else { return false }
            let locator = HouseholdShareLocator.decode(household.cloudKitShareIdentifier)
            return locator?.shareRecordName != incomingShareRecordName
        }
    }

    /// Joins the household behind `metadata`. `mergeRecipes` decides what
    /// happens to any other local household this device already has (see
    /// `localHouseholdAtRisk(ofAccepting:context:)`): `false` drops it along
    /// with everything in it, `true` moves its dishes — and the ingredients
    /// they need — into the joined household first, so its recipes survive
    /// even though its plan, shopping list, and history don't.
    static func accept(
        _ metadata: CKShare.Metadata,
        mergeRecipes: Bool = false,
        context: ModelContext,
        sharing: CloudKitShareLifecycleService,
        progress: @escaping @MainActor @Sendable (HouseholdCloudDownloadProgress) -> Void = { _ in }
    ) async throws -> (household: Household, isGuest: Bool) {
        guard metadata.containerIdentifier == SharedStore.cloudKitContainerID else { throw HouseholdSharingError.invalidInvitation }

        // An owner's second device already has access through the private
        // database. CloudKit rejects accepting that owner's own share into the
        // shared database, so use its zone ID as a precise download locator.
        let privateDatabase = CKContainer(identifier: metadata.containerIdentifier).privateCloudDatabase
        let zoneIsInPrivateDatabase = (try? await privateDatabase.recordZone(for: metadata.share.recordID.zoneID)) != nil
        if metadata.share.currentUserParticipant?.role == .owner || zoneIsInPrivateDatabase {
            let local = (try? context.fetch(FetchDescriptor<Household>()))?.first {
                $0.uuid != HouseholdShareLocator.householdID(from: metadata.share.recordID.zoneID)
            }
            let household = try await HouseholdCloudBootstrapService.restoreOwnedHousehold(
                in: metadata.share.recordID.zoneID,
                shareRecordName: metadata.share.recordID.recordName,
                replacing: local,
                mergeRecipes: mergeRecipes,
                context: context,
                progress: progress
            )
            return (household, false)
        }

        progress(.connecting)
        var importedHousehold: (household: Household, isGuest: Bool)?
        sharing.onShareAccepted = { acceptedShare in
            importedHousehold = try await importAcceptedShare(
                acceptedShare,
                containerIdentifier: metadata.containerIdentifier,
                mergeRecipes: mergeRecipes,
                context: context,
                progress: progress
            )
        }
        do {
            try await sharing.accept(metadata)
        } catch {
            if let cloudError = error as? CKError {
                switch cloudError.code {
                case .unknownItem, .zoneNotFound: throw HouseholdSharingError.invitationNotFound
                case .participantMayNeedVerification: throw HouseholdSharingError.notInvited
                default: break
                }
            }
            if let packageError = error as? CloudKitShareBackendError,
               case .cloudKit(let failure) = packageError {
                if failure == .notInvited { throw HouseholdSharingError.notInvited }
                if failure == .wrongContainer { throw HouseholdSharingError.invalidInvitation }
            }
            throw error
        }
        guard let importedHousehold else { throw HouseholdSharingError.missingRootRecord }
        return importedHousehold
    }

    private static func importAcceptedShare(
        _ acceptedShare: CKShare,
        containerIdentifier: String,
        mergeRecipes: Bool,
        context: ModelContext,
        progress: @escaping @MainActor @Sendable (HouseholdCloudDownloadProgress) -> Void
    ) async throws -> (household: Household, isGuest: Bool) {
        let database = CKContainer(identifier: containerIdentifier).sharedCloudDatabase
        if let sourceEnvironment = acceptedShare[cloudEnvironmentKey] as? String,
           let source = CloudKitEnvironment(rawValue: sourceEnvironment),
           source != .unknown,
           BuildEnvironment.cloudKit != .unknown,
           source != BuildEnvironment.cloudKit {
            throw HouseholdSharingError.differentCloudKitEnvironment(
                source: source.localizedName,
                target: BuildEnvironment.cloudKit.localizedName
            )
        }

        progress(.downloading(0))

        let share = acceptedShare
        let zoneID = share.recordID.zoneID
        var lastError: Error = HouseholdSharingError.missingRootRecord
        var householdRecord: CKRecord?
        for attempt in 0..<6 {
            do {
                // `accept` returns the authoritative share immediately, but
                // CloudKit may still be making its zone records visible in
                // the shared database. Reusing it avoids an unnecessary race
                // on fetching the CKShare itself; only the root data record
                // needs the bounded retry below.
                let fetched = try await fetchHouseholdRecord(from: share, zoneID: zoneID, database: database)
                guard HouseholdRecordIdentity(recordType: fetched.recordType, recordName: fetched.recordID.recordName) != nil,
                      fetched[HouseholdRecordCodec.payloadKey] is Data else {
                    throw HouseholdSharingError.missingRootRecord
                }
                householdRecord = fetched
                break
            } catch {
                lastError = error
                if attempt < 5 { try? await Task.sleep(for: .milliseconds(650)) }
            }
        }
        guard let householdRecord,
              let identity = HouseholdRecordIdentity(recordType: householdRecord.recordType, recordName: householdRecord.recordID.recordName),
              let payload = householdRecord[HouseholdRecordCodec.payloadKey] as? Data else {
            throw lastError
        }

        let isReadOnly = share.currentUserParticipant?.permission == .readOnly
        let locator = HouseholdShareLocator(
            zoneName: zoneID.zoneName,
            ownerName: zoneID.ownerName,
            shareRecordName: share.recordID.recordName,
            isOwner: false,
            isReadOnly: isReadOnly
        )
        // This is a local-only transaction. Keep cascade deletion, save, and
        // rollback under the same disabled UndoManager scope; no network await
        // is allowed inside it. Once committed, a later CloudKit sync failure
        // leaves the accepted household available for the normal retry path.
        let household = try withoutUndoRegistration(in: context) {
            do {
                let localHouseholds = try context.fetch(FetchDescriptor<Household>())
                let existing = localHouseholds.first { $0.uuid == identity.uuid }
                let household = existing ?? Household()
                if existing == nil {
                    household.uuid = identity.uuid
                    context.insert(household)
                }
                for other in localHouseholds where other.uuid != identity.uuid {
                    if mergeRecipes { mergeDishes(from: other, into: household) }
                    context.delete(other)
                }
                try HouseholdRecordApplier.apply(
                    payloadData: payload,
                    identity: identity,
                    modifiedAt: HouseholdRecordCodec.modifiedAt(of: householdRecord),
                    assetData: nil,
                    household: household,
                    context: context
                )
                household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(locator)
                refreshMembers(from: share, household: household, context: context)
                try context.save()
                return household
            } catch {
                context.rollback()
                throw error
            }
        }

        // The invitation and its root are committed locally at this point.
        // A later fetch failure must not make the caller keep displaying the
        // household that was just replaced. RootView switches to this root,
        // then its household task retries the remaining record download.
        do {
            try await HouseholdRecordSyncService.shared.synchronize(household: household, context: context)
        } catch {
            // The accepted share remains attached for the normal retry path.
        }
        return (household, isReadOnly)
    }

    /// Runs a sync round and refreshes the member roster from the share.
    ///
    /// On a participant's device this is also where losing access shows up:
    /// once the owner removes them, or replaces the invitation, the share and
    /// its zone vanish from this account's shared database. That throws
    /// `HouseholdSharingError.accessRemoved` — only for a missing share or
    /// zone, never for a network or server failure (see
    /// `indicatesLostAccess(_:)`), because the answer to it replaces the
    /// household on this device.
    static func synchronize(
        _ household: Household,
        context: ModelContext,
        session: HouseholdCollaborationSession? = nil
    ) async throws {
        let locator = HouseholdShareLocator.decode(household.cloudKitShareIdentifier)
        var syncError: Error?
        do {
            try await HouseholdRecordSyncService.shared.synchronize(household: household, context: context)
        } catch {
            // A removed participant's engine fails first; the share lookup
            // below decides whether that failure means removal.
            syncError = error
        }

        guard let locator, locator.shareRecordID != nil else {
            if let syncError { throw syncError }
            return
        }
        var lostAccess = false
        var shareLookupError: Error?
        do {
            let sharing = try await MealPlanCloudSharing.service(for: household, context: context)
            let participants = try await sharing.participants(rootID: household.uuid.uuidString)
            let current = participants.first { $0.isCurrentUser && ($0.status == .accepted || $0.isOwner) }
            lostAccess = !locator.isOwner && current == nil
            if !lostAccess, locator.isOwner || current != nil {
                let role: HouseholdCollaborationRole
                if locator.isOwner || current?.role == .owner {
                    role = .owner
                } else {
                    role = current?.permission == .readWrite ? .editor : .viewOnly
                }
                var corrected = locator
                corrected.isReadOnly = role == .viewOnly
                if household.cloudKitShareIdentifier != (try? HouseholdShareLocator.encode(corrected)) {
                    household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(corrected)
                    household.modifiedAt = .now
                }
                refreshMembers(from: participants, household: household, context: context)
                // Commit the corrected locator and roster together.
                try context.save()
                if let session {
                    session.reconcile(household: household, role: role, participantID: current?.id, fallbackName: current?.displayName)
                } else {
                    let member = (household.members ?? []).first { $0.cloudKitParticipantID == current?.id }
                    HouseholdCollaborationStore.store(.init(
                        householdID: household.uuid,
                        role: role,
                        memberID: member?.uuid,
                        participantID: current?.id,
                        displayName: member?.name ?? current?.displayName ?? String(localized: "Me")
                    ))
                }
            }
        } catch {
            lostAccess = !locator.isOwner && indicatesLostAccess(error)
            if !lostAccess { shareLookupError = error }
        }

        if lostAccess { throw HouseholdSharingError.accessRemoved }
        if let syncError { throw syncError }
        if let shareLookupError { throw shareLookupError }
    }

    /// Whether a CloudKit failure on a participant's device means the share
    /// itself is gone for this account — the owner removed them, or replaced
    /// the invitation — rather than a passing network or server problem.
    static func indicatesLostAccess(_ error: Error) -> Bool {
        if let failure = error as? CollaborationFailure {
            return failure == .revokedAccess
        }
        if let backendError = error as? CloudKitShareBackendError,
           case .cloudKit(let failure) = backendError {
            return failure == .revokedAccess
        }
        guard let error = error as? CKError else { return false }
        if error.code == .partialFailure {
            guard let itemErrors = error.partialErrorsByItemID?.values, !itemErrors.isEmpty else { return false }
            return itemErrors.allSatisfy(indicatesLostAccess)
        }
        return [.unknownItem, .zoneNotFound, .userDeletedZone].contains(error.code)
    }

    /// Background refreshes should retry ordinary CloudKit interruptions
    /// without opening an alert over the person's current task.
    static func isTemporarySyncFailure(_ error: Error) -> Bool {
        if let failure = error as? CollaborationFailure {
            return failure == .offline || failure == .cancelled
        }
        if let backendError = error as? CloudKitShareBackendError,
           case .cloudKit(let failure) = backendError {
            return failure == .offline || failure == .cancelled
        }
        guard let cloudError = error as? CKError else { return false }
        if cloudError.code == .partialFailure {
            guard let itemErrors = cloudError.partialErrorsByItemID?.values,
                  !itemErrors.isEmpty else { return false }
            return itemErrors.allSatisfy(isTemporarySyncFailure)
        }
        return [
            .networkUnavailable, .networkFailure, .serviceUnavailable,
            .requestRateLimited, .zoneBusy, .accountTemporarilyUnavailable,
            .operationCancelled,
        ].contains(cloudError.code)
    }

    /// Moves this device off a shared household it can no longer reach onto
    /// a new household of its own. The recipes come along, as with joining's
    /// Merge Recipes; the shared plan, shopping list, history, and routines
    /// stay with the old household, which is deleted from this device only.
    /// Household preferences (units, portions, nutrition) carry over; the
    /// synced App Store unlock deliberately doesn't.
    static func startOwnHousehold(afterLosingAccessTo old: Household, context: ModelContext) async throws -> Household {
        // Stop syncing the lost zone before anything is deleted, or the
        // deletion scan would queue deletes for the owner's records.
        await HouseholdRecordSyncService.shared.stop()
        if let locator = HouseholdShareLocator.decode(old.cloudKitShareIdentifier) {
            try await HouseholdRecordSyncService.shared.discardState(for: locator)
        }

        let household = Household(name: String(localized: "Family"))
        household.unitSystemRaw = old.unitSystemRaw
        household.roundsDisplayedAmounts = old.roundsDisplayedAmounts
        household.calendarStyleRaw = old.calendarStyleRaw
        household.standardServings = old.standardServings
        household.showsNutritionEstimates = old.showsNutritionEstimates
        household.leftoverSuggestionsEnabled = old.leftoverSuggestionsEnabled
        household.packageSizeCountryCode = old.packageSizeCountryCode
        household.energyUnitRaw = old.energyUnitRaw
        household.localeIdentifier = old.localeIdentifier
        context.insert(household)

        mergeDishes(from: old, into: household)
        for packageSize in old.packageSizeOverrides ?? [] {
            packageSize.household = household
        }
        context.delete(old)
        try context.save()
        PantryStaples.seedDefaults(for: household, context: context)
        NotificationCenter.default.post(name: .mealPlanDataDidChange, object: nil)
        return household
    }

    /// Moves every dish in `oldHousehold` to `newHousehold`, along with the
    /// ingredients each one needs, ahead of `oldHousehold` being deleted.
    /// Everything else about `oldHousehold` — its plan, shopping list, cooked
    /// history, routines — isn't a recipe and is left to go with it.
    ///
    /// Ingredients are shared across a household's dishes, so a moved dish's
    /// ingredient either joins an ingredient `newHousehold` already has with
    /// the same normalized name (keeping the shopping list's aggregation
    /// intact) or moves over with the dish when there's no match yet.
    static func mergeDishes(from oldHousehold: Household, into newHousehold: Household) {
        var ingredientsByName = [String: Ingredient](
            (newHousehold.ingredients ?? []).map { ($0.normalizedName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for dish in oldHousehold.dishes ?? [] {
            dish.household = newHousehold
            for dishIngredient in dish.ingredients ?? [] {
                guard let ingredient = dishIngredient.ingredient, ingredient.household === oldHousehold else { continue }
                if let match = ingredientsByName[ingredient.normalizedName] {
                    dishIngredient.ingredient = match
                } else {
                    ingredient.household = newHousehold
                    ingredientsByName[ingredient.normalizedName] = ingredient
                }
            }
        }
    }

    static func refreshMembers(from share: CKShare, household: Household, context: ModelContext) {
        let currentID = share.currentUserParticipant?.participantID
        let accepted = share.participants.filter { $0.acceptanceStatus == .accepted || $0.role == .owner }
        let acceptedIDs = Set(accepted.map(\.participantID))
        let formatter = PersonNameComponentsFormatter()

        for member in household.members ?? [] where member.cloudKitParticipantID.map({ !acceptedIDs.contains($0) }) == true {
            if member.isActive || member.isCurrentUser {
                member.isActive = false
                member.isCurrentUser = false
                let now = Date.now
                member.shareMetadataModifiedAt = now
                member.modifiedAt = now
            }
        }
        for participant in accepted {
            let id = participant.participantID
            let existing = (household.members ?? []).first { $0.cloudKitParticipantID == id }
            let member = existing ?? {
                let value = HouseholdMember()
                value.cloudKitParticipantID = id
                value.household = household
                context.insert(value)
                return value
            }()
            let name = participant.userIdentity.nameComponents
                .map { formatter.string(from: $0) }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? String(localized: "Family member")
            let role: MemberRole = participant.role == .owner ? .owner : (participant.permission == .readOnly ? .guest : .editor)
            let isCurrentUser = id == currentID
            if existing == nil || member.name != name || member.role != role || member.isCurrentUser != isCurrentUser || !member.isActive {
                member.name = name
                member.role = role
                member.isCurrentUser = isCurrentUser
                member.isActive = true
                let now = Date.now
                member.shareMetadataModifiedAt = now
                member.modifiedAt = now
            }
        }
    }

    /// Projects package-owned participant snapshots into MealPlan's local
    /// SwiftData member cache. The package remains the source for share access
    /// and participant status; this is only the app's persisted display model.
    private static func refreshMembers(from participants: [ShareParticipant], household: Household, context: ModelContext) {
        let accepted = participants.filter { $0.status == .accepted || $0.isOwner }
        let acceptedIDs = Set(accepted.map(\.id))

        for member in household.members ?? [] where member.cloudKitParticipantID.map({ !acceptedIDs.contains($0) }) == true {
            if member.isActive || member.isCurrentUser {
                member.isActive = false
                member.isCurrentUser = false
                let now = Date.now
                member.shareMetadataModifiedAt = now
                member.modifiedAt = now
            }
        }
        for participant in accepted {
            let existing = (household.members ?? []).first { $0.cloudKitParticipantID == participant.id }
            let member = existing ?? {
                let value = HouseholdMember()
                value.cloudKitParticipantID = participant.id
                value.household = household
                context.insert(value)
                return value
            }()
            let name = participant.displayName.flatMap { $0.isEmpty ? nil : $0 }
                ?? String(localized: "Family member")
            let role: MemberRole
            if participant.isOwner || participant.role == .owner {
                role = .owner
            } else {
                role = participant.permission == .readWrite ? .editor : .guest
            }
            if existing == nil || member.name != name || member.role != role || member.isCurrentUser != participant.isCurrentUser || !member.isActive {
                member.name = name
                member.role = role
                member.isCurrentUser = participant.isCurrentUser
                member.isActive = true
                let now = Date.now
                member.shareMetadataModifiedAt = now
                member.modifiedAt = now
            }
        }
    }

    private static func fetchHouseholdRecord(from share: CKShare, zoneID: CKRecordZone.ID, database: CKDatabase) async throws -> CKRecord {
        let householdID = resolvedHouseholdID(
            shareValue: share[householdIDKey] as? String,
            zoneID: zoneID
        )
        guard let householdID else { throw HouseholdSharingError.missingRootRecord }
        let identity = HouseholdRecordIdentity(type: .household, uuid: householdID)
        return try await fetchRecord(CKRecord.ID(recordName: identity.recordName, zoneID: zoneID), from: database)
    }

    /// Every MealPlan household zone embeds the same UUID as its root record.
    /// That makes legacy shares — which have no `householdID` field — directly
    /// addressable without a CKQuery or Production schema index.
    static func resolvedHouseholdID(shareValue: String?, zoneID: CKRecordZone.ID) -> UUID? {
        shareValue.flatMap(UUID.init(uuidString:))
            ?? HouseholdShareLocator.householdID(from: zoneID)
    }

    private static func fetchRecord(_ id: CKRecord.ID, from database: CKDatabase) async throws -> CKRecord {
        let records = try await database.records(for: [id])
        guard let result = records[id] else { throw HouseholdSharingError.cloudKitDidNotReturnRecord }
        return try result.get()
    }

}
