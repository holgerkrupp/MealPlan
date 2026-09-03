import CloudKit
import CryptoKit
import Foundation
import SwiftData

/// A CloudKit invitation link ready to hand to another person.
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
    case missingPayload
    case unsupportedPayload
    case cloudKitDidNotReturnRecord
    case onlyOwnerCanInvite

    var errorDescription: String? {
        switch self {
        case .cloudKitUnavailable: String(localized: "iCloud sharing is unavailable on this device.")
        case .invalidInvitation: String(localized: "This invitation does not belong to MealPlan. Ask the owner to send a new invitation from the app.")
        case .missingShareURL: String(localized: "iCloud did not create an invitation link. Please try again.")
        case .missingRootRecord: String(localized: "The shared household could not be found.")
        case .missingPayload: String(localized: "The shared household did not contain downloadable data.")
        case .unsupportedPayload: String(localized: "This household was shared by a newer version of MealPlan.")
        case .cloudKitDidNotReturnRecord: String(localized: "iCloud did not return the saved collaboration record.")
        case .onlyOwnerCanInvite: String(localized: "Only the household owner can invite people.")
        }
    }
}

extension Notification.Name {
    static let mealPlanDidReceiveCloudShare = Notification.Name("MealPlanDidReceiveCloudShare")
}

/// Keeps delegate-delivered invitations until the SwiftUI model context is ready.
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

/// Shares a household with other iCloud users.
///
/// SwiftData's managed CloudKit store (`SharedStore`) mirrors through the
/// *private* database only — CloudKit sharing needs a `CKShare` rooted on a
/// record the invitee's device can actually see, which SwiftData's automatic
/// mirroring never exposes. So sharing carries the whole household as a
/// `MealPlanBackup` payload on one hand-managed record in a custom zone,
/// alongside (not instead of) SwiftData's own private sync for this device's
/// multi-device continuity. See `MealPlanBackupSync` for how a fetched
/// payload is merged back into the live store.
@MainActor
enum HouseholdCloudSharingService {
    private static let rootRecordType = "SharedHousehold"
    // Referenced from the nonisolated `ShareLocator` computed properties, so it
    // must not pick up the enum's `@MainActor` isolation.
    private nonisolated static let rootRecordName = "Household"
    private static let payloadKey = "backup"
    private static let householdIDKey = "householdID"
    private static let modifiedAtKey = "modifiedAt"
    private static let schemaVersionKey = "schemaVersion"

    private struct ShareLocator: Codable {
        var zoneName: String
        var ownerName: String
        var shareRecordName: String
        var isOwner: Bool

        var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName) }
        var rootRecordID: CKRecord.ID { CKRecord.ID(recordName: rootRecordName, zoneID: zoneID) }
        var shareRecordID: CKRecord.ID { CKRecord.ID(recordName: shareRecordName, zoneID: zoneID) }
    }

    static func isOwner(shareIdentifier: String?) -> Bool? {
        guard let shareIdentifier else { return nil }
        return decodeLocator(shareIdentifier)?.isOwner
    }

    // MARK: - Inviting

    /// Prepares (or re-mints) an invitation link. `canEdit` sets the
    /// permission the link grants; only the owner may call this once a
    /// household is already shared.
    static func prepareInvitation(for household: Household, canEdit: Bool, context: ModelContext) async throws -> HouseholdShareInvitation {
        let container = CKContainer(identifier: SharedStore.cloudKitContainerID)

        if let rawIdentifier = household.cloudKitShareIdentifier, let locator = decodeLocator(rawIdentifier) {
            guard locator.isOwner else { throw HouseholdSharingError.onlyOwnerCanInvite }
            let database = container.privateCloudDatabase
            let record = try await fetchRecord(locator.rootRecordID, from: database)
            guard let share = try await fetchRecord(locator.shareRecordID, from: database) as? CKShare else {
                throw HouseholdSharingError.missingShareURL
            }
            // Carry the newest local state along with a fresh invitation, so
            // someone who joins right away sees up-to-date data.
            let backup = try MealPlanBackup.make(from: context)
            try await push(backup, into: record, database: database)
            return try await makeOneTimeInvitation(with: share, in: database, canEdit: canEdit, isOwner: true)
        }

        let zoneID = CKRecordZone.ID(zoneName: "Household-\(household.uuid.uuidString)", ownerName: CKCurrentUserDefaultName)
        let database = container.privateCloudDatabase
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])

        let rootID = CKRecord.ID(recordName: rootRecordName, zoneID: zoneID)
        let root = CKRecord(recordType: rootRecordType, recordID: rootID)
        let backup = try MealPlanBackup.make(from: context)
        try configure(root, with: backup)

        let share = CKShare(rootRecord: root)
        share[CKShare.SystemFieldKey.title] = household.name as CKRecordValue
        share[CKShare.SystemFieldKey.shareType] = "de.holgerkrupp.mealplan.household" as CKRecordValue

        let participant = CKShare.Participant.oneTimeURLParticipant()
        participant.permission = canEdit ? .readWrite : .readOnly
        share.addParticipant(participant)

        let result = try await database.modifyRecords(saving: [root, share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard let savedShare = try savedRecord(share.recordID, in: result.saveResults) as? CKShare,
              let url = savedShare.oneTimeURL(for: participant.participantID) else {
            throw HouseholdSharingError.missingShareURL
        }

        let locator = ShareLocator(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName, shareRecordName: savedShare.recordID.recordName, isOwner: true)
        let identifier = try encodeLocator(locator)
        household.cloudKitShareIdentifier = identifier
        try context.save()
        let hash = try contentHash(of: backup)
        setHashes(local: hash, cloud: hash, identifier: identifier)

        return HouseholdShareInvitation(url: url, participantCount: acceptedParticipantCount(in: savedShare), isOwner: true)
    }

    private static func makeOneTimeInvitation(with share: CKShare, in database: CKDatabase, canEdit: Bool, isOwner: Bool) async throws -> HouseholdShareInvitation {
        let participant = CKShare.Participant.oneTimeURLParticipant()
        participant.permission = canEdit ? .readWrite : .readOnly
        share.addParticipant(participant)
        let result = try await database.modifyRecords(saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        guard let savedShare = try savedRecord(share.recordID, in: result.saveResults) as? CKShare,
              let url = savedShare.oneTimeURL(for: participant.participantID) else {
            throw HouseholdSharingError.missingShareURL
        }
        return HouseholdShareInvitation(url: url, participantCount: acceptedParticipantCount(in: savedShare), isOwner: isOwner)
    }

    // MARK: - Accepting

    static func accept(_ metadata: CKShare.Metadata, context: ModelContext) async throws -> (household: Household, isGuest: Bool) {
        guard metadata.containerIdentifier == SharedStore.cloudKitContainerID else { throw HouseholdSharingError.invalidInvitation }
        let container = CKContainer(identifier: metadata.containerIdentifier)
        _ = try await container.accept([metadata])
        guard let rootID = metadata.hierarchicalRootRecordID else { throw HouseholdSharingError.missingRootRecord }

        let locator = ShareLocator(zoneName: rootID.zoneID.zoneName, ownerName: rootID.zoneID.ownerName, shareRecordName: metadata.share.recordID.recordName, isOwner: false)
        let identifier = try encodeLocator(locator)

        var lastError: Error = HouseholdSharingError.missingRootRecord
        for attempt in 0..<6 {
            do {
                let record = try await fetchRecord(rootID, from: container.sharedCloudDatabase)
                let backup = try readBackup(from: record)
                let targetUUID = backup.household.uuid
                let existing = try context.fetch(FetchDescriptor<Household>(predicate: #Predicate { $0.uuid == targetUUID })).first
                let household = try MealPlanBackupSync.apply(backup, to: existing, context: context, shareIdentifier: identifier)
                let hash = try contentHash(of: backup)
                setHashes(local: hash, cloud: hash, identifier: identifier)

                var isGuest = false
                if let share = try? await fetchRecord(locator.shareRecordID, from: container.sharedCloudDatabase) as? CKShare {
                    isGuest = share.currentUserParticipant?.permission == .readOnly
                    refreshMembers(from: share, household: household, context: context)
                }
                return (household, isGuest)
            } catch {
                lastError = error
                if attempt < 5 { try? await Task.sleep(for: .milliseconds(650)) }
            }
        }
        throw lastError
    }

    // MARK: - Ongoing sync

    /// Reconciles this device's household against the shared copy. Cheap when
    /// nothing changed: both sides are hashed and compared against the hashes
    /// recorded after the last successful sync, so an unmodified household
    /// costs one record fetch and no writes.
    static func synchronize(_ household: Household, context: ModelContext) async throws {
        guard let identifier = household.cloudKitShareIdentifier, let locator = decodeLocator(identifier) else { return }
        let container = CKContainer(identifier: SharedStore.cloudKitContainerID)
        let database = locator.isOwner ? container.privateCloudDatabase : container.sharedCloudDatabase
        let record = try await fetchRecord(locator.rootRecordID, from: database)
        let cloudBackup = try readBackup(from: record)
        let localBackup = try MealPlanBackup.make(from: context)

        let cloudHash = try contentHash(of: cloudBackup)
        let localHash = try contentHash(of: localBackup)
        let lastLocalHash = storedHash(kind: "local", identifier: identifier)
        let lastCloudHash = storedHash(kind: "cloud", identifier: identifier)
        let localChanged = localHash != lastLocalHash
        let cloudChanged = cloudHash != lastCloudHash

        switch (localChanged, cloudChanged) {
        case (false, false):
            break
        case (true, false):
            try await push(localBackup, into: record, database: database)
            setHashes(local: localHash, cloud: localHash, identifier: identifier)
        case (false, true):
            try MealPlanBackupSync.apply(cloudBackup, to: household, context: context, shareIdentifier: identifier)
            setHashes(local: cloudHash, cloud: cloudHash, identifier: identifier)
        case (true, true):
            let merged = MealPlanBackupSync.merging(localBackup, with: cloudBackup)
            try MealPlanBackupSync.apply(merged, to: household, context: context, shareIdentifier: identifier)
            try await push(merged, into: record, database: database)
            let mergedHash = try contentHash(of: merged)
            setHashes(local: mergedHash, cloud: mergedHash, identifier: identifier)
        }

        if let share = try? await fetchRecord(locator.shareRecordID, from: database) as? CKShare {
            refreshMembers(from: share, household: household, context: context)
        }
    }

    // MARK: - Members

    private static func refreshMembers(from share: CKShare, household: Household, context: ModelContext) {
        let formatter = PersonNameComponentsFormatter()
        for existing in household.members ?? [] { context.delete(existing) }
        for participant in share.participants {
            guard participant.acceptanceStatus == .accepted else { continue }
            guard participant !== share.currentUserParticipant else { continue }
            let name = participant.userIdentity.nameComponents
                .map { formatter.string(from: $0) }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? String(localized: "Family member")
            let role: MemberRole = participant.role == .owner ? .owner : (participant.permission == .readOnly ? .guest : .editor)
            let member = HouseholdMember(name: name, role: role, isCurrentUser: false)
            member.household = household
            context.insert(member)
        }
        try? context.save()
    }

    // MARK: - Payload

    private static func configure(_ record: CKRecord, with backup: MealPlanBackup) throws {
        let payloadURL = try writePayload(backup)
        defer { try? FileManager.default.removeItem(at: payloadURL.deletingLastPathComponent()) }
        record[householdIDKey] = backup.household.uuid.uuidString as CKRecordValue
        record[modifiedAtKey] = Date.now as CKRecordValue
        record[schemaVersionKey] = MealPlanBackup.currentVersion as CKRecordValue
        record[payloadKey] = CKAsset(fileURL: payloadURL)
    }

    private static func push(_ backup: MealPlanBackup, into record: CKRecord, database: CKDatabase) async throws {
        try configure(record, with: backup)
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
    }

    private static func writePayload(_ backup: MealPlanBackup) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Household.json")
        try MealPlanBackup.encode(backup).write(to: url, options: .atomic)
        return url
    }

    private static func readBackup(from record: CKRecord) throws -> MealPlanBackup {
        guard let asset = record[payloadKey] as? CKAsset, let url = asset.fileURL else { throw HouseholdSharingError.missingPayload }
        let backup = try MealPlanBackup.decode(try Data(contentsOf: url))
        guard backup.version <= MealPlanBackup.currentVersion else { throw HouseholdSharingError.unsupportedPayload }
        return backup
    }

    /// A stable hash of the parts of a backup that actually describe the
    /// household's data, ignoring bookkeeping fields (`exportedAt`, `origin`)
    /// that change on every export regardless of content — those would
    /// otherwise make every sync look like a change.
    private static func contentHash(of backup: MealPlanBackup) throws -> String {
        var canonical = backup
        canonical.exportedAt = .distantPast
        canonical.origin = nil
        canonical.householdCount = nil
        let data = try MealPlanBackup.encode(canonical)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func storedHash(kind: String, identifier: String) -> String? {
        UserDefaults.standard.string(forKey: "HouseholdShare.\(kind).\(identifier)")
    }

    private static func setHashes(local: String, cloud: String, identifier: String) {
        UserDefaults.standard.set(local, forKey: "HouseholdShare.local.\(identifier)")
        UserDefaults.standard.set(cloud, forKey: "HouseholdShare.cloud.\(identifier)")
    }

    // MARK: - CloudKit plumbing

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

    private static func encodeLocator(_ locator: ShareLocator) throws -> String {
        try JSONEncoder().encode(locator).base64EncodedString()
    }

    private static func decodeLocator(_ value: String) -> ShareLocator? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSONDecoder().decode(ShareLocator.self, from: data)
    }
}
