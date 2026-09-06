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
    case missingShareURL
    case missingRootRecord
    case cloudKitDidNotReturnRecord
    case onlyOwnerCanInvite
    case readOnlyHousehold

    var errorDescription: String? {
        switch self {
        case .cloudKitUnavailable: String(localized: "iCloud sharing is unavailable on this device.")
        case .invalidInvitation: String(localized: "This invitation does not belong to MealPlan. Ask the owner to send a new invitation from the app.")
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

    func enqueue(_ metadata: CKShare.Metadata) {
        pending.append(metadata)
        NotificationCenter.default.post(name: .mealPlanDidReceiveCloudShare, object: nil)
    }

    func drain() -> [CKShare.Metadata] {
        defer { pending.removeAll() }
        return pending
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

    static func accept(_ metadata: CKShare.Metadata, context: ModelContext) async throws -> (household: Household, isGuest: Bool) {
        guard metadata.containerIdentifier == SharedStore.cloudKitContainerID else { throw HouseholdSharingError.invalidInvitation }
        let container = CKContainer(identifier: metadata.containerIdentifier)
        _ = try await container.accept([metadata])
        let database = container.sharedCloudDatabase
        let shareID = metadata.share.recordID

        var lastError: Error = HouseholdSharingError.missingRootRecord
        for attempt in 0..<6 {
            do {
                guard let share = try await fetchRecord(shareID, from: database) as? CKShare else {
                    throw HouseholdSharingError.missingRootRecord
                }
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
                // cleaned up in CloudKit too.
                for other in localHouseholds where other.uuid != identity.uuid {
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

    private static func savedRecord(_ id: CKRecord.ID, in results: [CKRecord.ID: Result<CKRecord, Error>]) throws -> CKRecord {
        guard let result = results[id] else { throw HouseholdSharingError.cloudKitDidNotReturnRecord }
        return try result.get()
    }

    private static func acceptedParticipantCount(in share: CKShare) -> Int {
        share.participants.filter { $0.role == .owner || $0.acceptanceStatus == .accepted }.count
    }
}
