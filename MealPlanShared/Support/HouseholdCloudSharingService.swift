import CloudKit
import Foundation
import SwiftData

struct HouseholdShareInvitation: Sendable {
    let url: URL
    let participantCount: Int
    let isOwner: Bool
}

enum HouseholdSharingError: LocalizedError {
    case cloudKitUnavailable
    case invalidInvitation
    case invitationNotFound
    case missingShareURL
    case missingRootRecord
    case cloudKitDidNotReturnRecord
    case onlyOwnerCanInvite
    case readOnlyHousehold

    var errorDescription: String? {
        switch self {
        case .cloudKitUnavailable: String(localized: "iCloud sharing is unavailable on this device.")
        case .invalidInvitation: String(localized: "This invitation does not belong to MealPlan. Ask the owner to send a new invitation from the app.")
        case .invitationNotFound: String(localized: "This invitation no longer exists or was created in a different iCloud environment. Install MealPlan from the same source (Xcode, TestFlight, or App Store) on both phones, then send a new invitation.")
        case .missingShareURL: String(localized: "iCloud did not create an invitation link. Please try again.")
        case .missingRootRecord: String(localized: "The shared household could not be found.")
        case .cloudKitDidNotReturnRecord: String(localized: "iCloud did not return the saved collaboration record.")
        case .onlyOwnerCanInvite: String(localized: "Only the household owner can invite people.")
        case .readOnlyHousehold: String(localized: "This household is view only. Ask its owner for edit access to make changes.")
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

    /// Whether `url` looks like an iCloud share link, so a URL that reaches
    /// the app through `onOpenURL` instead of the system's CloudKit
    /// acceptance sheet can still be routed to `accept(_:context:)`.
    ///
    /// The system is supposed to intercept these links itself and call
    /// `application(_:userDidAcceptCloudKitShareWith:)` before the app ever
    /// sees the URL, but that hand-off is unreliable in practice — a link
    /// opened from inside another app's in-app browser, forwarded through a
    /// chat app's link preview, or tapped while MealPlan is already the
    /// foreground app can all fall through to a plain universal-link open
    /// instead. When that happens the invitation silently does nothing
    /// unless something here also treats `onOpenURL` as a valid entry point.
    static func isShareURL(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host.hasSuffix("icloud.com") && url.path.contains("/share/")
    }

    /// Resolves the `CKShare.Metadata` for an iCloud share link opened
    /// through `onOpenURL`, so it can be handed to `accept(_:context:)` the
    /// same way a metadata delivered via `userDidAcceptCloudKitShareWith`
    /// would be.
    static func fetchMetadata(for url: URL) async throws -> CKShare.Metadata {
        let container = CKContainer(identifier: SharedStore.cloudKitContainerID)
        return try await container.shareMetadata(for: url)
    }

    static func prepareInvitation(for household: Household, canEdit: Bool, context: ModelContext) async throws -> HouseholdShareInvitation {
        let container = CKContainer(identifier: SharedStore.cloudKitContainerID)
        var locator = HouseholdShareLocator.decode(household.cloudKitShareIdentifier) ?? .solo(householdID: household.uuid)
        guard locator.isOwner else { throw HouseholdSharingError.onlyOwnerCanInvite }

        try await HouseholdRecordSyncService.shared.synchronize(household: household, context: context)
        let database = container.privateCloudDatabase
        let share: CKShare
        if let shareID = locator.shareRecordID {
            guard let fetched = try await fetchRecord(shareID, from: database) as? CKShare else {
                throw HouseholdSharingError.missingShareURL
            }
            share = fetched
        } else {
            share = CKShare(recordZoneID: locator.zoneID)
            share[CKShare.SystemFieldKey.title] = household.name as CKRecordValue
            share[CKShare.SystemFieldKey.shareType] = "de.holgerkrupp.mealplan.household" as CKRecordValue
            share[householdIDKey] = household.uuid.uuidString as CKRecordValue
        }

        // Anyone holding the link may join, at the permission the owner picked.
        // A `CKShare.Participant.oneTimeURLParticipant()` would be tighter, but
        // `addParticipant(_:)` traps (not throws) unless the app carries Apple's
        // restricted `com.apple.developer.icloud-extended-share-access`
        // entitlement — which crashed the app on every invitation.
        share.publicPermission = canEdit ? .readWrite : .readOnly
        let result = try await database.modifyRecords(saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard let savedShare = try savedRecord(share.recordID, in: result.saveResults) as? CKShare,
              let url = savedShare.url else {
            throw HouseholdSharingError.missingShareURL
        }

        locator.shareRecordName = savedShare.recordID.recordName
        locator.isReadOnly = false
        household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(locator)
        household.modifiedAt = .now
        refreshMembers(from: savedShare, household: household, context: context)
        try context.save()

        return .init(url: url, participantCount: acceptedParticipantCount(in: savedShare), isOwner: true)
    }

    /// Revokes the current zone-wide share and immediately creates a new one.
    /// Deleting a `CKShare` stops sharing its zone but does not delete the zone
    /// or any of the household records inside it, so this is the safe escape
    /// hatch for an invitation URL that CloudKit can no longer resolve.
    static func replaceInvitation(for household: Household, canEdit: Bool, context: ModelContext) async throws -> HouseholdShareInvitation {
        var locator = HouseholdShareLocator.decode(household.cloudKitShareIdentifier) ?? .solo(householdID: household.uuid)
        guard locator.isOwner else { throw HouseholdSharingError.onlyOwnerCanInvite }

        // Push current household changes before access to the zone is reset.
        try await HouseholdRecordSyncService.shared.synchronize(household: household, context: context)

        if let shareID = locator.shareRecordID {
            let database = CKContainer(identifier: SharedStore.cloudKitContainerID).privateCloudDatabase
            do {
                let result = try await database.modifyRecords(
                    saving: [],
                    deleting: [shareID],
                    savePolicy: .ifServerRecordUnchanged,
                    atomically: true
                )
                guard let deletion = result.deleteResults[shareID] else {
                    throw HouseholdSharingError.cloudKitDidNotReturnRecord
                }
                _ = try deletion.get()
            } catch let error as CKError where error.code == .unknownItem {
                // A stale local locator is precisely one of the cases this
                // recovery action is meant to repair. There is no old share
                // left to revoke, so continue by creating a replacement.
            }
        }

        locator.shareRecordName = nil
        household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(locator)
        household.modifiedAt = .now
        try context.save()

        return try await prepareInvitation(for: household, canEdit: canEdit, context: context)
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
        let container = CKContainer(identifier: metadata.containerIdentifier)
        let database = container.sharedCloudDatabase
        // Use the single-share overload so a per-share CloudKit failure is
        // thrown directly. The array overload can finish successfully while
        // returning the actual rejection nested in its result dictionary.
        let acceptedShare: CKShare
        do {
            acceptedShare = try await container.accept(metadata)
        } catch {
            // Acceptance is not usefully idempotent: when the system delivers
            // the same URL twice, the second call can report "Share not
            // found" even though the first call succeeded. If the share is
            // already present in this account's shared database, continue the
            // local import instead of turning that harmless duplicate into an
            // error alert. Preserve the original error when the link really
            // is stale or belongs to another CloudKit environment.
            guard let existingShare = await fetchAcceptedShare(
                metadata.share.recordID,
                from: database
            ) else {
                if let cloudError = error as? CKError,
                   cloudError.code == .unknownItem || cloudError.code == .zoneNotFound {
                    throw HouseholdSharingError.invitationNotFound
                }
                throw error
            }
            acceptedShare = existingShare
        }

        progress(.downloading(0))

        var lastError: Error = HouseholdSharingError.missingRootRecord
        for attempt in 0..<6 {
            do {
                // `accept` returns the authoritative share immediately, but
                // CloudKit may still be making its zone records visible in
                // the shared database. Reusing it avoids an unnecessary race
                // on fetching the CKShare itself; only the root data record
                // needs the bounded retry below.
                let share = acceptedShare
                let zoneID = share.recordID.zoneID
                let householdRecord = try await fetchHouseholdRecord(from: share, zoneID: zoneID, database: database)
                guard let identity = HouseholdRecordIdentity(recordType: householdRecord.recordType, recordName: householdRecord.recordID.recordName),
                      let payload = householdRecord[HouseholdRecordCodec.payloadKey] as? Data else {
                    throw HouseholdSharingError.missingRootRecord
                }

                let localHouseholds = try context.fetch(FetchDescriptor<Household>())
                let existing = localHouseholds.first { $0.uuid == identity.uuid }
                let household = existing ?? Household()
                if existing == nil {
                    household.uuid = identity.uuid
                    context.insert(household)
                }
                // The app keeps exactly one household per device (see
                // `Household`'s doc comment). Joining a share replaces
                // whatever solo household this device already had rather
                // than adding a second one alongside it — otherwise the
                // invitation looked like it did nothing, since bootstrap's
                // "the household" fetch could still return the old one on
                // the next launch. The cascade delete this triggers is
                // picked up by the same safety-net scan that reports any
                // other local deletion, so the old household's own zone gets
                // cleaned up in CloudKit too. `RootView` warns about this
                // before ever calling `accept`, and offers `mergeRecipes` as
                // a way to keep the old household's dishes.
                for other in localHouseholds where other.uuid != identity.uuid {
                    if mergeRecipes {
                        mergeDishes(from: other, into: household)
                    }
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

                let isReadOnly = share.currentUserParticipant?.permission == .readOnly
                let locator = HouseholdShareLocator(
                    zoneName: zoneID.zoneName,
                    ownerName: zoneID.ownerName,
                    shareRecordName: share.recordID.recordName,
                    isOwner: false,
                    isReadOnly: isReadOnly
                )
                household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(locator)
                refreshMembers(from: share, household: household, context: context)
                try context.save()
                try await HouseholdRecordSyncService.shared.synchronize(household: household, context: context)
                return (household, isReadOnly)
            } catch {
                lastError = error
                if attempt < 5 { try? await Task.sleep(for: .milliseconds(650)) }
            }
        }
        throw lastError
    }

    static func synchronize(_ household: Household, context: ModelContext) async throws {
        try await HouseholdRecordSyncService.shared.synchronize(household: household, context: context)
        guard let locator = HouseholdShareLocator.decode(household.cloudKitShareIdentifier),
              let shareID = locator.shareRecordID else { return }
        let container = CKContainer(identifier: SharedStore.cloudKitContainerID)
        let database = locator.isOwner ? container.privateCloudDatabase : container.sharedCloudDatabase
        if let share = try? await fetchRecord(shareID, from: database) as? CKShare {
            refreshMembers(from: share, household: household, context: context)
        }
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

    private static func refreshMembers(from share: CKShare, household: Household, context: ModelContext) {
        let currentID = share.currentUserParticipant?.participantID
        let accepted = share.participants.filter { $0.acceptanceStatus == .accepted || $0.role == .owner }
        let acceptedIDs = Set(accepted.map(\.participantID))
        let formatter = PersonNameComponentsFormatter()

        for member in household.members ?? [] where member.cloudKitParticipantID.map({ !acceptedIDs.contains($0) }) == true {
            if member.isActive || member.isCurrentUser {
                member.isActive = false
                member.isCurrentUser = false
                member.modifiedAt = .now
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
                member.modifiedAt = .now
            }
        }
        try? context.save()
    }

    private static func fetchHouseholdRecord(from share: CKShare, zoneID: CKRecordZone.ID, database: CKDatabase) async throws -> CKRecord {
        if let raw = share[householdIDKey] as? String, let uuid = UUID(uuidString: raw) {
            let identity = HouseholdRecordIdentity(type: .household, uuid: uuid)
            return try await fetchRecord(CKRecord.ID(recordName: identity.recordName, zoneID: zoneID), from: database)
        }
        let result = try await database.records(matching: CKQuery(recordType: HouseholdRecordType.household.rawValue, predicate: NSPredicate(value: true)), inZoneWith: zoneID)
        for (_, record) in result.matchResults {
            if let record = try? record.get() { return record }
        }
        throw HouseholdSharingError.missingRootRecord
    }

    private static func fetchRecord(_ id: CKRecord.ID, from database: CKDatabase) async throws -> CKRecord {
        let records = try await database.records(for: [id])
        guard let result = records[id] else { throw HouseholdSharingError.cloudKitDidNotReturnRecord }
        return try result.get()
    }

    /// Share acceptance can return before CloudKit has finished exposing the
    /// shared zone. This bounded lookup recovers an already-accepted share and
    /// also covers two lifecycle callbacks arriving almost simultaneously.
    private static func fetchAcceptedShare(_ id: CKRecord.ID, from database: CKDatabase) async -> CKShare? {
        for attempt in 0..<6 {
            if let share = try? await fetchRecord(id, from: database) as? CKShare {
                return share
            }
            if attempt < 5 { try? await Task.sleep(for: .milliseconds(650)) }
        }
        return nil
    }

    private static func savedRecord(_ id: CKRecord.ID, in results: [CKRecord.ID: Result<CKRecord, Error>]) throws -> CKRecord {
        guard let result = results[id] else { throw HouseholdSharingError.cloudKitDidNotReturnRecord }
        return try result.get()
    }

    private static func acceptedParticipantCount(in share: CKShare) -> Int {
        share.participants.filter { $0.role == .owner || $0.acceptanceStatus == .accepted }.count
    }
}
