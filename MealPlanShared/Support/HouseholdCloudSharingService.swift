import CloudKit
import Foundation
import SwiftData

enum HouseholdSharingError: LocalizedError {
    case cloudKitUnavailable
    case notInvited
    case missingRootRecord
    case cloudKitDidNotReturnRecord
    case readOnlyHousehold
    /// This device's Apple Account is no longer on the household's share.
    /// `RootView` answers it by moving to a household of its own.
    case accessRemoved

    var errorDescription: String? {
        switch self {
        case .cloudKitUnavailable: String(localized: "iCloud sharing is unavailable on this device.")
        case .notInvited: String(localized: "This invitation is for a different Apple Account. Ask the household’s owner to invite the email address or phone number of the Apple Account on this device.")
        case .missingRootRecord: String(localized: "The shared household could not be found.")
        case .cloudKitDidNotReturnRecord: String(localized: "iCloud did not return the saved collaboration record.")
        case .readOnlyHousehold: String(localized: "This household is view only. Ask its owner for edit access to make changes.")
        case .accessRemoved: String(localized: "You no longer have access to this household.")
        }
    }
}

extension Notification.Name {
    static let mealPlanDidReceiveCloudShare = Notification.Name("MealPlanDidReceiveCloudShare")
}

@MainActor
final class CloudShareMetadataInbox {
    static let shared = CloudShareMetadataInbox()
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

    /// Keeps a new managed invitation in memory when its managed stores have
    /// not finished loading yet. The host drains it again when readiness
    /// changes; legacy links are deliberately not parked here.
    func parkUntilManagedStoreLoads(_ metadata: CKShare.Metadata) {
        guard !pending.contains(where: { deliveryKey(for: $0) == deliveryKey(for: metadata) }) else { return }
        pending.append(metadata)
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

/// Legacy zone-sync and recovery support for households created by older
/// MealPlan versions. New household invitations and participant management
/// are exclusively handled by CloudKitCollaborationKit.
@MainActor
enum HouseholdCloudSharingService {

    static func isOwner(shareIdentifier: String?) -> Bool? {
        HouseholdShareLocator.decode(shareIdentifier)?.isOwner
    }

    /// Whether `url` looks like an iCloud share link, so the app can forward
    /// it to CloudKitCollaborationKit when the universal link reaches
    /// `onOpenURL` instead of the system's share-delivery callback.
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
    /// through `onOpenURL`, so the invitation coordinator receives the same
    /// metadata as the app/scene delegate path.
    static func fetchMetadata(for url: URL) async throws -> CKShare.Metadata {
        let container = CKContainer(identifier: SharedStore.cloudKitContainerID)
        do {
            return try await container.shareMetadata(for: url)
        } catch let error as CKError where error.code == .participantMayNeedVerification {
            throw HouseholdSharingError.notInvited
        }
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

        guard let locator, let shareID = locator.shareRecordID else {
            if let syncError { throw syncError }
            return
        }
        let container = CKContainer(identifier: SharedStore.cloudKitContainerID)
        let database = locator.isOwner ? container.privateCloudDatabase : container.sharedCloudDatabase
        var lostAccess = false
        do {
            let share = try await fetchRecord(shareID, from: database) as? CKShare
            let isStillOnShare = share?.currentUserParticipant.map { $0.acceptanceStatus == .accepted } ?? true
            lostAccess = !locator.isOwner && !isStillOnShare
            if let share, !lostAccess {
                let current = share.currentUserParticipant
                let role: HouseholdCollaborationRole = locator.isOwner || current?.role == .owner
                    ? .owner
                    : (current?.permission == .readOnly ? .viewOnly : .editor)
                var corrected = locator
                corrected.isReadOnly = role == .viewOnly
                if household.cloudKitShareIdentifier != (try? HouseholdShareLocator.encode(corrected)) {
                    household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(corrected)
                    household.modifiedAt = .now
                }
                refreshMembers(from: share, household: household, context: context)
                // `refreshMembers` saves its cache as well. A second save here
                // is harmless and ensures the corrected locator commits with
                // the same local transaction.
                try context.save()
                let formatter = PersonNameComponentsFormatter()
                let fallback = current?.userIdentity.nameComponents
                    .map { formatter.string(from: $0) }
                    .flatMap { $0.isEmpty ? nil : $0 }
                if let session {
                    session.reconcile(household: household, role: role, participantID: current?.participantID, fallbackName: fallback)
                } else {
                    let member = (household.members ?? []).first { $0.cloudKitParticipantID == current?.participantID }
                    HouseholdCollaborationStore.store(.init(
                        householdID: household.uuid,
                        role: role,
                        memberID: member?.uuid,
                        participantID: current?.participantID,
                        displayName: member?.name ?? fallback ?? String(localized: "Me")
                    ))
                }
            }
        } catch {
            lostAccess = !locator.isOwner && indicatesLostAccess(error)
        }

        if lostAccess { throw HouseholdSharingError.accessRemoved }
        if let syncError { throw syncError }
    }

    /// Whether a CloudKit failure on a participant's device means the share
    /// itself is gone for this account — the owner removed them, or replaced
    /// the invitation — rather than a passing network or server problem.
    static func indicatesLostAccess(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        if error.code == .partialFailure {
            guard let itemErrors = error.partialErrorsByItemID?.values, !itemErrors.isEmpty else { return false }
            return itemErrors.allSatisfy(indicatesLostAccess)
        }
        return [.unknownItem, .zoneNotFound, .userDeletedZone].contains(error.code)
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
            HouseholdRecordSyncService.shared.discardState(for: locator)
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
        try? context.save()
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
