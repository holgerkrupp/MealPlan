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

        let participant = CKShare.Participant.oneTimeURLParticipant()
        participant.permission = canEdit ? .readWrite : .readOnly
        share.addParticipant(participant)
        let result = try await database.modifyRecords(saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard let savedShare = try savedRecord(share.recordID, in: result.saveResults) as? CKShare,
              let url = savedShare.oneTimeURL(for: participant.participantID) else {
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

                let existing = try context.fetch(FetchDescriptor<Household>()).first { $0.uuid == identity.uuid }
                let household = existing ?? Household()
                if existing == nil {
                    household.uuid = identity.uuid
                    context.insert(household)
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
