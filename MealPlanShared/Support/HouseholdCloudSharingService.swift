import CloudKit
import Foundation
import SwiftData

/// Someone on the household's share, as the invitation sheet lists them.
struct HouseholdShareParticipant: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// Invited by Apple Account; hasn't opened the link yet.
        case invited
        case joined
    }

    /// `CKShare.Participant.participantID`.
    let id: String
    let name: String?
    let emailAddress: String?
    let phoneNumber: String?
    let isOwner: Bool
    let canEdit: Bool
    let status: Status

    /// CloudKit only learns an invitee's name once they accept, so until
    /// then they are shown by the address they were invited at.
    var displayName: String {
        name ?? emailAddress ?? phoneNumber ?? String(localized: "Invited person")
    }

    /// The address the invitation went to, when the name is shown instead.
    var detail: String? {
        name == nil ? nil : (emailAddress ?? phoneNumber)
    }
}

extension HouseholdShareParticipant {
    /// `nil` for anyone who is neither invited nor joined (removed, unknown).
    init?(_ participant: CKShare.Participant) {
        let status: Status
        switch participant.acceptanceStatus {
        case .accepted: status = .joined
        case .pending: status = .invited
        default: return nil
        }
        let formatter = PersonNameComponentsFormatter()
        self.init(
            id: participant.participantID,
            name: participant.userIdentity.nameComponents
                .map { formatter.string(from: $0) }
                .flatMap { $0.isEmpty ? nil : $0 },
            emailAddress: participant.userIdentity.lookupInfo?.emailAddress,
            phoneNumber: participant.userIdentity.lookupInfo?.phoneNumber,
            isOwner: participant.role == .owner,
            canEdit: participant.permission == .readWrite,
            status: status
        )
    }
}

struct HouseholdShareInvitation: Sendable {
    /// The share's one link. It only opens the household for the people
    /// invited to it; CloudKit turns every other Apple Account away.
    let url: URL
    let participants: [HouseholdShareParticipant]

    /// Everyone on the share except the owner.
    var invitees: [HouseholdShareParticipant] { participants.filter { !$0.isOwner } }
}

/// What the owner typed to invite someone: the email address or phone
/// number of that person's Apple Account.
enum HouseholdInviteAddress: Equatable, Sendable {
    case email(String)
    case phone(String)

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") {
            let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty,
                  parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
                  !trimmed.contains(where: \.isWhitespace) else { return nil }
            self = .email(trimmed)
        } else {
            // People paste numbers the way their contacts app shows them.
            let formatting = CharacterSet(charactersIn: " -()./\u{00A0}")
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: trimmed.unicodeScalars.filter { !formatting.contains($0) })
            let compact = String(scalars)
            let digits = compact.hasPrefix("+") ? compact.dropFirst() : Substring(compact)
            guard (6...15).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            self = .phone(compact)
        }
    }

    var text: String {
        switch self {
        case .email(let value), .phone(let value): value
        }
    }
}

enum HouseholdSharingError: LocalizedError {
    case cloudKitUnavailable
    case invalidInvitation
    case invitationNotFound
    case notInvited
    case missingShareURL
    case missingRootRecord
    case cloudKitDidNotReturnRecord
    case onlyOwnerCanInvite
    case readOnlyHousehold
    case onlyOwnerCanRemoveMembers
    case memberNotRemovable
    case inviteeNotFound(String)
    case cannotInviteYourself
    case legacyShareNotConverted
    /// This device's Apple Account is no longer on the household's share.
    /// `RootView` answers it by moving to a household of its own.
    case accessRemoved

    var errorDescription: String? {
        switch self {
        case .cloudKitUnavailable: String(localized: "iCloud sharing is unavailable on this device.")
        case .invalidInvitation: String(localized: "This invitation does not belong to MealPlan. Ask the owner to send a new invitation from the app.")
        case .invitationNotFound: String(localized: "This invitation no longer exists or was created in a different iCloud environment. Install MealPlan from the same source (Xcode, TestFlight, or App Store) on both phones, then send a new invitation.")
        case .notInvited: String(localized: "This invitation is for a different Apple Account. Ask the household’s owner to invite the email address or phone number of the Apple Account on this device.")
        case .missingShareURL: String(localized: "iCloud did not create an invitation link. Please try again.")
        case .missingRootRecord: String(localized: "The shared household could not be found.")
        case .cloudKitDidNotReturnRecord: String(localized: "iCloud did not return the saved collaboration record.")
        case .onlyOwnerCanInvite: String(localized: "Only the household owner can invite people.")
        case .readOnlyHousehold: String(localized: "This household is view only. Ask its owner for edit access to make changes.")
        case .onlyOwnerCanRemoveMembers: String(localized: "Only the household owner can remove people.")
        case .memberNotRemovable: String(localized: "This person can’t be removed from the household.")
        case .inviteeNotFound(let address): String(localized: "iCloud couldn’t find an Apple Account for “\(address)”. Check it for typos, or try another email address or phone number they use with their Apple Account.")
        case .cannotInviteYourself: String(localized: "That’s your own Apple Account. Your other devices signed in to it get the household automatically.")
        case .legacyShareNotConverted: String(localized: "Some people who joined with the old link couldn’t be moved to personal invitations. Use Create New Invitation, then invite everyone again.")
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
        do {
            return try await container.shareMetadata(for: url)
        } catch let error as CKError where error.code == .participantMayNeedVerification {
            throw HouseholdSharingError.notInvited
        }
    }

    /// Makes sure the household has a share, and returns its link and the
    /// people on it.
    ///
    /// The share is private (`publicPermission == .none`): only people the
    /// owner invites by Apple Account can open the link, so someone who was
    /// removed can't come back through it. Per-person
    /// `oneTimeURLParticipant()` links would work without knowing an address,
    /// but `addParticipant(_:)` traps — not throws — unless the app carries
    /// Apple's restricted `com.apple.developer.icloud-extended-share-access`
    /// entitlement, which crashed the app on every invitation. Participants
    /// looked up by email or phone need no entitlement.
    static func prepareInvitation(for household: Household, context: ModelContext) async throws -> HouseholdShareInvitation {
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
        }

        // Older shares predate this locator field. Persist it whenever the
        // invitation UI is opened so future participants can fetch the root
        // record by ID without relying on any CloudKit query indexes.
        share[householdIDKey] = household.uuid.uuidString as CKRecordValue
        try await convertToPersonalInvitations(share, container: container)
        let savedShare = try await save(share, to: database)

        locator.shareRecordName = savedShare.recordID.recordName
        locator.isReadOnly = false
        household.cloudKitShareIdentifier = try HouseholdShareLocator.encode(locator)
        household.modifiedAt = .now
        refreshMembers(from: savedShare, household: household, context: context)
        try context.save()

        return try invitation(from: savedShare)
    }

    /// Adds the person behind `address` to the share at the chosen access.
    /// They still have to open the link, and only an Apple Account with that
    /// email address or phone number can. Inviting someone already on the
    /// share updates their access instead of adding them twice.
    static func invite(
        _ address: HouseholdInviteAddress,
        canEdit: Bool,
        to household: Household,
        context: ModelContext
    ) async throws -> HouseholdShareInvitation {
        try await addParticipant(canEdit: canEdit, to: household, context: context) { container in
            try await lookUpParticipant(address, in: container)
        }
    }

    /// Adds the Apple Account a nearby device identified itself as (its
    /// iCloud user record name, handed over by `NearbyInviteHost`) and returns
    /// the invitation with the link that device joins with.
    static func invite(
        userRecordName: String,
        canEdit: Bool,
        to household: Household,
        context: ModelContext
    ) async throws -> HouseholdShareInvitation {
        try await addParticipant(canEdit: canEdit, to: household, context: context) { container in
            try await container.shareParticipant(forUserRecordID: CKRecord.ID(recordName: userRecordName))
        }
    }

    private static func addParticipant(
        canEdit: Bool,
        to household: Household,
        context: ModelContext,
        lookUp: (CKContainer) async throws -> CKShare.Participant
    ) async throws -> HouseholdShareInvitation {
        let container = CKContainer(identifier: SharedStore.cloudKitContainerID)
        let currentUserRecordID = try? await container.userRecordID()
        return try await modifyShare(of: household, context: context, unlessOwner: .onlyOwnerCanInvite) { share in
            // Looked up afresh on every attempt: a participant object belongs
            // to the share instance it was added to.
            let participant = try await lookUp(container)
            if let id = participant.userIdentity.userRecordID, id == currentUserRecordID {
                throw HouseholdSharingError.cannotInviteYourself
            }
            participant.role = .privateUser
            participant.permission = canEdit ? .readWrite : .readOnly
            share.addParticipant(participant)
        }
    }

    /// Revokes the current zone-wide share and immediately creates a new one.
    /// Deleting a `CKShare` stops sharing its zone but does not delete the zone
    /// or any of the household records inside it, so this is the safe escape
    /// hatch for an invitation URL that CloudKit can no longer resolve. The
    /// new share starts with nobody on it.
    static func replaceInvitation(for household: Household, context: ModelContext) async throws -> HouseholdShareInvitation {
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

        return try await prepareInvitation(for: household, context: context)
    }

    /// Whether the owner can take `member` out of the share: an active,
    /// CloudKit-backed participant who isn't the owner. The owner stops
    /// sharing altogether with `replaceInvitation`, not by removing themselves.
    static func canRemove(_ member: HouseholdMember) -> Bool {
        member.isActive && !member.isCurrentUser && member.role != .owner && member.cloudKitParticipantID != nil
    }

    /// Takes one person out of the household's share. For someone who joined,
    /// CloudKit revokes their access to the zone immediately, and their device
    /// moves to a household of its own on its next sync (see
    /// `startOwnHousehold(afterLosingAccessTo:context:)`). For a pending
    /// invitation, the link simply stops working for them. The household and
    /// its records stay put either way.
    static func removeParticipant(
        withID participantID: String,
        from household: Household,
        context: ModelContext
    ) async throws -> HouseholdShareInvitation {
        try await modifyShare(of: household, context: context, unlessOwner: .onlyOwnerCanRemoveMembers) { share in
            // Already gone: they left, or another owner device removed them.
            guard let participant = share.participants.first(where: { $0.participantID == participantID }) else { return }
            guard participant.role != .owner else { throw HouseholdSharingError.memberNotRemovable }
            share.removeParticipant(participant)
        }
    }

    static func removeMember(_ member: HouseholdMember, from household: Household, context: ModelContext) async throws {
        guard canRemove(member), let participantID = member.cloudKitParticipantID else {
            throw HouseholdSharingError.memberNotRemovable
        }
        _ = try await removeParticipant(withID: participantID, from: household, context: context)
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
                if let cloudError = error as? CKError {
                    switch cloudError.code {
                    case .unknownItem, .zoneNotFound: throw HouseholdSharingError.invitationNotFound
                    // The link was opened by an Apple Account the owner
                    // didn't invite.
                    case .participantMayNeedVerification: throw HouseholdSharingError.notInvited
                    default: break
                    }
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

    /// Runs a sync round and refreshes the member roster from the share.
    ///
    /// On a participant's device this is also where losing access shows up:
    /// once the owner removes them, or replaces the invitation, the share and
    /// its zone vanish from this account's shared database. That throws
    /// `HouseholdSharingError.accessRemoved` — only for a missing share or
    /// zone, never for a network or server failure (see
    /// `indicatesLostAccess(_:)`), because the answer to it replaces the
    /// household on this device.
    static func synchronize(_ household: Household, context: ModelContext) async throws {
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
        let lostAccess: Bool
        do {
            let share = try await fetchRecord(shareID, from: database) as? CKShare
            let isStillOnShare = share?.currentUserParticipant.map { $0.acceptanceStatus == .accepted } ?? true
            lostAccess = !locator.isOwner && !isStillOnShare
            if let share, !lostAccess {
                refreshMembers(from: share, household: household, context: context)
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
        household.energyUnitRaw = old.energyUnitRaw
        household.localeIdentifier = old.localeIdentifier
        context.insert(household)

        mergeDishes(from: old, into: household)
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

    /// Fetches the household's share, lets `change` edit it, and saves it —
    /// starting once more from a fresh copy if another owner device saved the
    /// share in between. A share from before per-person invitations is
    /// converted first: CloudKit only allows participant changes on a share
    /// that isn't open to anyone with the link.
    private static func modifyShare(
        of household: Household,
        context: ModelContext,
        unlessOwner notOwnerError: HouseholdSharingError,
        _ change: (CKShare) async throws -> Void
    ) async throws -> HouseholdShareInvitation {
        guard let locator = HouseholdShareLocator.decode(household.cloudKitShareIdentifier), locator.isOwner else {
            throw notOwnerError
        }
        guard let shareID = locator.shareRecordID else { throw HouseholdSharingError.missingShareURL }
        let container = CKContainer(identifier: SharedStore.cloudKitContainerID)
        let database = container.privateCloudDatabase

        var attempt = 0
        while true {
            guard let share = try await fetchRecord(shareID, from: database) as? CKShare else {
                throw HouseholdSharingError.cloudKitDidNotReturnRecord
            }
            try await convertToPersonalInvitations(share, container: container)
            try await change(share)
            do {
                let savedShare = try await save(share, to: database)
                refreshMembers(from: savedShare, household: household, context: context)
                return try invitation(from: savedShare)
            } catch let error as CKError where error.code == .serverRecordChanged && attempt == 0 {
                attempt += 1
            }
        }
    }

    /// Shares made before per-person invitations let anyone with the link
    /// join. Closing one (`publicPermission = .none`) would lock out everyone
    /// who joined that way, so each of them is looked up by user record and
    /// added back as a named participant at the access they had; CloudKit
    /// updates an existing participant with the same identity in place.
    /// Throws before touching the share if anyone can't be carried over.
    private static func convertToPersonalInvitations(_ share: CKShare, container: CKContainer) async throws {
        guard share.publicPermission != .none else { return }
        let joined = share.participants.filter { $0.role != .owner && $0.acceptanceStatus == .accepted }
        let userRecordIDs = joined.compactMap(\.userIdentity.userRecordID)
        guard userRecordIDs.count == joined.count else { throw HouseholdSharingError.legacyShareNotConverted }
        let lookups: [CKRecord.ID: Result<CKShare.Participant, any Error>] = userRecordIDs.isEmpty
            ? [:]
            : try await container.shareParticipants(forUserRecordIDs: userRecordIDs)

        var replacements: [CKShare.Participant] = []
        for previous in joined {
            guard let id = previous.userIdentity.userRecordID,
                  let participant = try? lookups[id]?.get() else {
                throw HouseholdSharingError.legacyShareNotConverted
            }
            participant.role = .privateUser
            participant.permission = previous.permission == .readOnly ? .readOnly : .readWrite
            replacements.append(participant)
        }

        share.publicPermission = .none
        for participant in replacements {
            share.addParticipant(participant)
        }
    }

    private static func lookUpParticipant(_ address: HouseholdInviteAddress, in container: CKContainer) async throws -> CKShare.Participant {
        do {
            switch address {
            case .email(let email): return try await container.shareParticipant(forEmailAddress: email)
            case .phone(let number): return try await container.shareParticipant(forPhoneNumber: number)
            }
        } catch let error as CKError where error.code == .unknownItem || error.code == .invalidArguments {
            throw HouseholdSharingError.inviteeNotFound(address.text)
        }
    }

    private static func invitation(from share: CKShare) throws -> HouseholdShareInvitation {
        guard let url = share.url else { throw HouseholdSharingError.missingShareURL }
        return .init(url: url, participants: share.participants.compactMap { HouseholdShareParticipant($0) })
    }

    private static func save(_ share: CKShare, to database: CKDatabase) async throws -> CKShare {
        let result = try await database.modifyRecords(saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard let savedShare = try savedRecord(share.recordID, in: result.saveResults) as? CKShare else {
            throw HouseholdSharingError.cloudKitDidNotReturnRecord
        }
        return savedShare
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
}
