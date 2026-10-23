import CloudKit
import CryptoKit
import Darwin
import Foundation
import SwiftData

/// Owner-only recovery metadata in the private database's default zone.
///
/// The index contains a compact description and an exact legacy zone locator,
/// never a second copy of meals or recipes. Keeping the original zone alive is
/// what preserves record UUIDs and accepted share participants during the
/// retention window, even when the device that requested deletion is gone.
@MainActor
enum HouseholdRecoveryIndex {
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    private static let recordType = "MPHouseholdRecoveryIndex"
    private static let recordPrefix = "MPHouseholdRecovery-"

    static func markRecentlyDeleted(_ candidate: HouseholdRecoveryCandidate, at date: Date = .now) async throws -> HouseholdRecoveryCandidate {
        guard candidate.locator.isOwner else { throw HouseholdRecoveryError.notOwner }
        let database = CKContainer(identifier: SharedStore.cloudKitContainerID).privateCloudDatabase
        let recordID = indexRecordID(for: candidate)
        let record = (try? await fetch(recordID, from: database)) ?? CKRecord(recordType: recordType, recordID: recordID)
        let retentionUntil = date.addingTimeInterval(retention)

        record["householdID"] = candidate.householdID.uuidString as CKRecordValue
        record["householdName"] = candidate.name as CKRecordValue
        record["zoneName"] = candidate.locator.zoneName as CKRecordValue
        record["ownerName"] = candidate.locator.ownerName as CKRecordValue
        record["shareRecordName"] = candidate.locator.shareRecordName as CKRecordValue?
        record["deletedAt"] = date as CKRecordValue
        record["retentionUntil"] = retentionUntil as CKRecordValue
        record["dishCount"] = NSNumber(value: candidate.dishCount)
        record["entryCount"] = NSNumber(value: candidate.entryCount)
        record["memberCount"] = NSNumber(value: candidate.memberCount)
        record["entryStart"] = candidate.entryStart as CKRecordValue?
        record["entryEnd"] = candidate.entryEnd as CKRecordValue?
        record["dateCreated"] = candidate.dateCreated as CKRecordValue
        record["lastModifiedAt"] = candidate.lastModifiedAt as CKRecordValue
        record["isShared"] = NSNumber(value: candidate.isShared)
        record["cloudEnvironment"] = BuildEnvironment.cloudKit.rawValue as CKRecordValue

        let modification = try await database.modifyRecords(
            saving: [record],
            deleting: [],
            savePolicy: .changedKeys,
            atomically: false
        )
        guard let saveResult = modification.saveResults[recordID] else {
            throw HouseholdSharingError.cloudKitDidNotReturnRecord
        }
        _ = try saveResult.get()

        var recovered = candidate
        recovered.source = .recentlyDeleted
        recovered.deletedAt = date
        recovered.retentionUntil = retentionUntil
        recovered.isActiveOnThisDevice = false
        return recovered
    }

    /// Reads durable recovery entries from iCloud rather than the active
    /// SwiftData store, so another device can restore an accidental deletion.
    static func recentlyDeletedHouseholds() async throws -> [HouseholdRecoveryCandidate] {
        let database = CKContainer(identifier: SharedStore.cloudKitContainerID).privateCloudDatabase
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        var records: [CKRecord] = []

        var page = try await database.records(
            matching: query,
            inZoneWith: nil,
            desiredKeys: nil,
            resultsLimit: 100
        )
        while true {
            for (_, result) in page.matchResults {
                records.append(try result.get())
            }
            guard let cursor = page.queryCursor else { break }
            page = try await database.records(
                continuingMatchFrom: cursor,
                desiredKeys: nil,
                resultsLimit: 100
            )
        }

        return records.compactMap(candidate(from:)).sorted {
            ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast)
        }
    }

    /// Permanently removes the original owner zone only after its 30-day
    /// recovery period. Callers still require a separate explicit confirmation
    /// in the UI; this guard keeps an accidental early purge impossible.
    static func purge(_ candidate: HouseholdRecoveryCandidate) async throws {
        guard candidate.source == .recentlyDeleted, candidate.locator.isOwner else {
            throw HouseholdRecoveryError.notOwner
        }
        guard candidate.isPurgeEligible else { throw HouseholdRecoveryError.retentionNotReached }

        let database = CKContainer(identifier: SharedStore.cloudKitContainerID).privateCloudDatabase
        _ = try await database.modifyRecordZones(saving: [], deleting: [candidate.locator.zoneID])
        _ = try await database.modifyRecords(
            saving: [],
            deleting: [indexRecordID(for: candidate)],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )
    }

    /// Removes only the private recovery pointer. Used if the local reset did
    /// not complete after its index entry was written; it never touches the
    /// household zone itself.
    static func removeRecoveryEntry(for candidate: HouseholdRecoveryCandidate) async throws {
        let database = CKContainer(identifier: SharedStore.cloudKitContainerID).privateCloudDatabase
        _ = try await database.modifyRecords(
            saving: [],
            deleting: [indexRecordID(for: candidate)],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )
    }

    private static func indexRecordID(for candidate: HouseholdRecoveryCandidate) -> CKRecord.ID {
        // A household can have old zones with the same UUID. The zone name is
        // part of the deterministic key while the record name remains safe
        // for CloudKit's default zone.
        let suffix = Data("\(candidate.locator.ownerName)|\(candidate.locator.zoneName)".utf8)
            .base64EncodedString()
            .replacing("/", with: "_")
            .replacing("+", with: "-")
            .replacing("=", with: "")
        return CKRecord.ID(recordName: "\(recordPrefix)\(candidate.householdID.uuidString)-\(suffix)")
    }

    private static func candidate(from record: CKRecord) -> HouseholdRecoveryCandidate? {
        guard record.recordType == recordType,
              let householdID = (record["householdID"] as? String).flatMap(UUID.init(uuidString:)),
              let name = record["householdName"] as? String,
              let zoneName = record["zoneName"] as? String,
              let ownerName = record["ownerName"] as? String,
              let deletedAt = record["deletedAt"] as? Date,
              let retentionUntil = record["retentionUntil"] as? Date,
              let dateCreated = record["dateCreated"] as? Date,
              let lastModifiedAt = record["lastModifiedAt"] as? Date else { return nil }

        let shareRecordName = record["shareRecordName"] as? String
        let isShared = (record["isShared"] as? NSNumber)?.boolValue ?? (shareRecordName != nil)
        let locator = HouseholdShareLocator(
            zoneName: zoneName,
            ownerName: ownerName,
            shareRecordName: shareRecordName,
            isOwner: true,
            isReadOnly: false
        )
        return HouseholdRecoveryCandidate(
            householdID: householdID,
            name: name,
            locator: locator,
            source: .recentlyDeleted,
            role: .owner,
            dishCount: (record["dishCount"] as? NSNumber)?.intValue ?? 0,
            entryCount: (record["entryCount"] as? NSNumber)?.intValue ?? 0,
            memberCount: (record["memberCount"] as? NSNumber)?.intValue ?? 0,
            entryStart: record["entryStart"] as? Date,
            entryEnd: record["entryEnd"] as? Date,
            dateCreated: dateCreated,
            lastModifiedAt: lastModifiedAt,
            isShared: isShared,
            isActiveOnThisDevice: false,
            deletedAt: deletedAt,
            retentionUntil: retentionUntil
        )
    }

    private static func fetch(_ id: CKRecord.ID, from database: CKDatabase) async throws -> CKRecord {
        let records = try await database.records(for: [id])
        guard let result = records[id] else { throw HouseholdSharingError.cloudKitDidNotReturnRecord }
        return try result.get()
    }

    private static func allRecords(in zoneID: CKRecordZone.ID, from database: CKDatabase) async throws -> [CKRecord] {
        var token: CKServerChangeToken?
        var records: [CKRecord] = []
        var moreComing = true
        while moreComing {
            let page = try await database.recordZoneChanges(
                inZoneWith: zoneID,
                since: token,
                desiredKeys: nil,
                resultsLimit: 100
            )
            for result in page.modificationResultsByID.values {
                records.append(try result.get().record)
            }
            token = page.changeToken
            moreComing = page.moreComing
        }
        return records
    }
}

struct HouseholdRecoveryResult: Sendable {
    var safetyBackupURL: URL
    var restoredHouseholdID: UUID
    var didRestartSync: Bool
}

/// A local, timestamped recovery checkpoint. The backup itself remains the
/// ordinary portable MealPlan format; its tiny sidecar only preserves the
/// local CloudKit locator so this recovery screen can reattach the device to
/// the same zone after a crash or interrupted restore.
struct HouseholdSafetyBackup: Identifiable {
    var url: URL
    var backup: MealPlanBackup
    var shareIdentifier: String?

    /// A detached archive restores under a fresh household UUID, so restoring
    /// local data cannot write into the old or revoked CloudKit zone.
    var isDetachedArchive: Bool { url.lastPathComponent.contains("-archive-") }
    var detachedHouseholdUUID: UUID? {
        isDetachedArchive ? HouseholdRecoveryService.detachedHouseholdUUID(for: url) : nil
    }

    var id: URL { url }
}

/// The app-owned state needed while replacing the local household store.
/// Keeping this boundary in shared code lets extensions compile the recovery
/// models without depending on the main app's concrete `AppState` type.
@MainActor
protocol HouseholdRecoveryAppState: AnyObject {
    var currentHousehold: Household? { get }

    func bootstrap(context: ModelContext, planningThrough latestPlanningDate: Date?)
}

/// Coordinates the only local replacement used by household recovery. Remote
/// data is always downloaded into a staging store before the current device is
/// touched; the original portable backup is retained and automatically put
/// back if replacing this device fails.
@MainActor
enum HouseholdRecoveryService {
    static func restore(
        _ candidate: HouseholdRecoveryCandidate,
        appState: any HouseholdRecoveryAppState,
        context: ModelContext,
        progress: @escaping @MainActor (HouseholdCloudDownloadProgress) -> Void = { _ in }
    ) async throws -> HouseholdRecoveryResult {
        // Fetch and validate first. An unavailable or malformed remote zone
        // leaves the live device and its sync engine completely untouched.
        let recoveredBackup = try await HouseholdCloudBootstrapService.preparedBackup(for: candidate, progress: progress)
        let originalBackup = try MealPlanBackup.make(from: context)
        let originalLocator = appState.currentHousehold?.cloudKitShareIdentifier
        let safetyBackupURL = try writeSafetyBackup(originalBackup, shareIdentifier: originalLocator)

        await HouseholdRecordSyncService.shared.stop()
        do {
            try MealPlanBackupRestore.replaceEverything(with: recoveredBackup, context: context)
            guard let restored = try context.fetch(FetchDescriptor<Household>()).first(where: { $0.uuid == candidate.householdID }) else {
                throw HouseholdRecoveryError.validationFailed
            }
            restored.cloudKitShareIdentifier = try HouseholdShareLocator.encode(candidate.locator)
            try context.save()
            try validate(restored, matching: candidate, context: context)
            appState.bootstrap(context: context, planningThrough: nil)

            let didRestartSync = await restartSync(for: restored, context: context)
            if candidate.source == .recentlyDeleted {
                // A successful restore must leave the deletion lifecycle before
                // the household is presented as active again. If this fails,
                // the surrounding rollback keeps the still-indexed zone safe.
                try await HouseholdRecoveryIndex.removeRecoveryEntry(for: candidate)
            }
            HouseholdSyncDiagnostics.record(event: "householdRecoveryRestored", locator: candidate.locator)
            SharedStore.reloadWidgets()
            return .init(
                safetyBackupURL: safetyBackupURL,
                restoredHouseholdID: restored.uuid,
                didRestartSync: didRestartSync
            )
        } catch let recoveryError {
            // No failure path intentionally leaves a half-replaced local
            // store. This also restores the previous locator, which ordinary
            // exported backups omit so cross-environment imports stay safe.
            await HouseholdRecordSyncService.shared.stop()
            do {
                try MealPlanBackupRestore.replaceEverything(with: originalBackup, context: context)
                if let original = try context.fetch(FetchDescriptor<Household>()).first {
                    original.cloudKitShareIdentifier = originalLocator
                    try context.save()
                    appState.bootstrap(context: context, planningThrough: nil)
                    _ = await restartSync(for: original, context: context)
                } else {
                    appState.bootstrap(context: context, planningThrough: nil)
                }
            } catch let rollbackError {
                // The safety backup is already on disk, even if a damaged
                // local SQLite store prevented the automatic rollback.
                throw rollbackError
            }
            throw recoveryError
        }
    }

    /// Owner deletion is a reversible lifecycle: after a successful remote
    /// index write, this device starts fresh but the original CloudKit zone and
    /// CKShare stay untouched for 30 days. Participants cannot call this path.
    static func moveToRecentlyDeleted(
        household: Household,
        appState: any HouseholdRecoveryAppState,
        context: ModelContext
    ) async throws -> HouseholdRecoveryResult {
        let locator = HouseholdShareLocator.decode(household.cloudKitShareIdentifier) ?? .solo(householdID: household.uuid)
        guard locator.isOwner else { throw HouseholdRecoveryError.notOwner }

        // Ensure the remote zone represents the latest local state before the
        // index records its counts and locator.
        try await HouseholdRecordSyncService.shared.synchronize(household: household, context: context)
        let candidate = try await HouseholdCloudBootstrapService.recoverableHousehold(
            at: locator,
            activeHouseholdID: household.uuid
        )
        let originalBackup = try MealPlanBackup.make(from: context)
        let safetyBackupURL = try writeSafetyBackup(originalBackup, shareIdentifier: household.cloudKitShareIdentifier)
        _ = try await HouseholdRecoveryIndex.markRecentlyDeleted(candidate)

        await HouseholdRecordSyncService.shared.stop()
        do {
            try MealPlanBackupRestore.replaceEverything(with: emptyBackup(), context: context)
            appState.bootstrap(context: context, planningThrough: nil)
            guard let fresh = appState.currentHousehold else { throw HouseholdRecoveryError.validationFailed }
            let didRestartSync = await restartSync(for: fresh, context: context)
            HouseholdSyncDiagnostics.record(event: "householdMovedToRecentlyDeleted", locator: locator)
            SharedStore.reloadWidgets()
            return .init(safetyBackupURL: safetyBackupURL, restoredHouseholdID: fresh.uuid, didRestartSync: didRestartSync)
        } catch let moveError {
            await HouseholdRecordSyncService.shared.stop()
            do {
                try MealPlanBackupRestore.replaceEverything(with: originalBackup, context: context)
                if let original = try context.fetch(FetchDescriptor<Household>()).first {
                    original.cloudKitShareIdentifier = household.cloudKitShareIdentifier
                    try context.save()
                    appState.bootstrap(context: context, planningThrough: nil)
                    _ = await restartSync(for: original, context: context)
                }
            } catch let rollbackError {
                throw rollbackError
            }
            // The iCloud household was never removed, and the device is back
            // on it, so do not leave a misleading Recently Deleted entry.
            try? await HouseholdRecoveryIndex.removeRecoveryEntry(for: candidate)
            throw moveError
        }
    }

    private static func restartSync(for household: Household, context: ModelContext) async -> Bool {
        do {
            try await HouseholdRecordSyncService.shared.synchronize(household: household, context: context)
            return true
        } catch {
            // The exact local replacement is still valid offline. Normal
            // launch/save retry behaviour will reconnect when iCloud returns.
            HouseholdSyncDiagnostics.record(event: "householdRecoverySyncRestartFailed", locator: HouseholdShareLocator.decode(household.cloudKitShareIdentifier) ?? .solo(householdID: household.uuid))
            return false
        }
    }

    private static func validate(
        _ household: Household,
        matching candidate: HouseholdRecoveryCandidate,
        context: ModelContext
    ) throws {
        guard household.uuid == candidate.householdID,
              household.name == candidate.name,
              (try context.fetchCount(FetchDescriptor<Dish>())) == candidate.dishCount,
              (try context.fetchCount(FetchDescriptor<MealPlanEntry>())) == candidate.entryCount else {
            throw HouseholdRecoveryError.validationFailed
        }
    }

    private static func validate(
        _ household: Household,
        matching backup: MealPlanBackup,
        context: ModelContext,
        expectedHouseholdUUID: UUID? = nil
    ) throws {
        guard household.uuid == (expectedHouseholdUUID ?? backup.household.uuid),
              household.name == backup.household.name,
              (try context.fetchCount(FetchDescriptor<Dish>())) == backup.contents.dishes,
              (try context.fetchCount(FetchDescriptor<MealPlanEntry>())) == backup.contents.plannedMeals else {
            throw HouseholdRecoveryError.validationFailed
        }
    }

    private static func emptyBackup() -> MealPlanBackup {
        MealPlanBackup(household: .init(
            uuid: UUID(),
            name: String(localized: "Family"),
            unitSystemRaw: UnitSystem.metric.rawValue,
            roundsDisplayedAmounts: true,
            calendarStyleRaw: CalendarStyle.week.rawValue,
            localeIdentifier: Locale.current.identifier,
            dateCreated: .now
        ))
    }

    static func safetyBackups(at folder: URL? = nil) -> [HouseholdSafetyBackup] {
        let folder = folder ?? safetyBackupFolder
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension == BackupFileType.fileExtension,
                  url.lastPathComponent.contains("-recovery-") || url.lastPathComponent.contains("-archive-") else { return nil }
            guard let backup = try? MealPlanBackup.decode(Data(contentsOf: url)) else { return nil }
            let descriptor = descriptor(at: descriptorURL(for: url))
            return HouseholdSafetyBackup(url: url, backup: backup, shareIdentifier: descriptor?.shareIdentifier)
        }.sorted { lhs, rhs in
            let left = (try? lhs.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let right = (try? rhs.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return left > right
        }
    }

    /// Restores a checkpoint written by this feature. It follows the same
    /// stop/replace/validate/restart sequence as cloud recovery, but it does
    /// not contact iCloud and carries the local zone locator back with it.
    static func restoreSafetyBackup(
        _ checkpoint: HouseholdSafetyBackup,
        appState: any HouseholdRecoveryAppState,
        context: ModelContext
    ) async throws -> HouseholdRecoveryResult {
        let currentBackup = try MealPlanBackup.make(from: context)
        let currentLocator = appState.currentHousehold?.cloudKitShareIdentifier
        let safetyBackupURL = try writeSafetyBackup(currentBackup, shareIdentifier: currentLocator)

        await HouseholdRecordSyncService.shared.stop()
        do {
            let restoredUUID = checkpoint.detachedHouseholdUUID
            try MealPlanBackupRestore.replaceEverything(
                with: checkpoint.backup,
                context: context,
                householdUUID: restoredUUID
            )
            guard let restored = try context.fetch(FetchDescriptor<Household>()).first else {
                throw HouseholdRecoveryError.validationFailed
            }
            restored.cloudKitShareIdentifier = checkpoint.isDetachedArchive ? nil : checkpoint.shareIdentifier
            if checkpoint.isDetachedArchive {
                // Detached archives may originate from a participant's copy
                // of an owner's inherited household unlock. The new identity
                // must be reconciled against this Apple Account's entitlement.
                restored.unlockedByPurchase = false
            }
            try context.save()
            try validate(
                restored,
                matching: checkpoint.backup,
                context: context,
                expectedHouseholdUUID: restoredUUID ?? checkpoint.backup.household.uuid
            )
            appState.bootstrap(context: context, planningThrough: nil)
            let didRestartSync = await restartSync(for: restored, context: context)
            SharedStore.reloadWidgets()
            return .init(safetyBackupURL: safetyBackupURL, restoredHouseholdID: restored.uuid, didRestartSync: didRestartSync)
        } catch let recoveryError {
            await HouseholdRecordSyncService.shared.stop()
            do {
                try MealPlanBackupRestore.replaceEverything(with: currentBackup, context: context)
                if let original = try context.fetch(FetchDescriptor<Household>()).first {
                    original.cloudKitShareIdentifier = currentLocator
                    try context.save()
                    appState.bootstrap(context: context, planningThrough: nil)
                    _ = await restartSync(for: original, context: context)
                }
            } catch let rollbackError {
                throw rollbackError
            }
            throw recoveryError
        }
    }

    /// Store a timestamped ordinary `.mealplanbackup` beside the App Group
    /// database. It is deliberately not a transient share-sheet file, so it
    /// survives a crash halfway through a device recovery.
    private static var safetyBackupFolder: URL {
        SharedStore.storeURL
            .deletingLastPathComponent()
            .appending(path: "Household Recovery Backups", directoryHint: .isDirectory)
    }

    private struct SafetyBackupDescriptor: Codable {
        var shareIdentifier: String?
    }

    private static func descriptorURL(for backupURL: URL) -> URL {
        backupURL.deletingPathExtension().appendingPathExtension("recovery.json")
    }

    private static func descriptor(at url: URL) -> SafetyBackupDescriptor? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SafetyBackupDescriptor.self, from: data)
    }

    private static func writeSafetyBackup(_ backup: MealPlanBackup, shareIdentifier: String?) throws -> URL {
        let folder = safetyBackupFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = "\(MealPlanBackup.baseFilename(for: backup.exportedAt))-recovery-\(UUID().uuidString).\(BackupFileType.fileExtension)"
        let url = folder.appending(path: filename)
        try writeAtomicallyAndVerify(backup, to: url)
        let descriptorData = try JSONEncoder().encode(SafetyBackupDescriptor(shareIdentifier: shareIdentifier))
        try descriptorData.write(to: descriptorURL(for: url), options: .atomic)
        try synchronizeDirectory(folder)
        return url
    }

    /// Captures the whole SwiftData graph before any join/revocation code can
    /// delete a household root. Each root gets a complete archive whose
    /// household settings come from that root, while all content rows from
    /// the store remain included. This keeps every root's preferences
    /// recoverable when several roots are folded into one household. The
    /// deterministic operation key makes a repeated preflight/retry update
    /// the same archives instead of producing an unbounded series of copies.
    /// The filename marks the checkpoint as detached so it remains
    /// discoverable even if the process stops before a sidecar or UI refresh.
    @discardableResult
    static func archiveBeforeReplacement(
        context: ModelContext,
        operationID: String,
        preferredHouseholdID: UUID? = nil,
        folder: URL? = nil
    ) throws -> URL {
        let rows = try MealPlanBackup.StoreRows(fetchedFrom: context)
        let orderedHouseholds = rows.households.sorted {
            if let preferredHouseholdID {
                let lhsPreferred = $0.uuid == preferredHouseholdID
                let rhsPreferred = $1.uuid == preferredHouseholdID
                if lhsPreferred != rhsPreferred { return lhsPreferred }
            }
            return ($0.dateCreated, $0.uuid.uuidString) < ($1.dateCreated, $1.uuid.uuidString)
        }
        let settingsRoots: [Household?] = orderedHouseholds.isEmpty ? [nil] : orderedHouseholds.map(Optional.some)
        let directory = folder ?? safetyBackupFolder
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var archiveURLs: [URL] = []
        for settingsRoot in settingsRoots {
            let backup = MealPlanBackup.make(
                from: rows,
                includePhotos: true,
                preferredHouseholdID: settingsRoot?.uuid
            )
            let rootToken = settingsRoot?.uuid.uuidString ?? "store"
            let token = SHA256.hash(data: Data("\(operationID)|settings-root:\(rootToken)".utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            let url = directory.appending(path: "MealPlan-archive-\(token).\(BackupFileType.fileExtension)")
            try writeAtomicallyAndVerify(backup, to: url)
            archiveURLs.append(url)
        }
        try synchronizeDirectory(directory)
        guard let firstArchive = archiveURLs.first else { throw HouseholdRecoveryError.validationFailed }
        return firstArchive
    }

    private static func writeAtomicallyAndVerify(_ backup: MealPlanBackup, to url: URL) throws {
        let data = try MealPlanBackup.encode(backup)
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()

        let persisted = try Data(contentsOf: url)
        let decoded = try MealPlanBackup.decode(persisted)
        guard decoded.household.uuid == backup.household.uuid,
              decoded.contents == backup.contents,
              decoded.includesPhotos,
              try MealPlanBackup.encode(decoded) == persisted else {
            throw HouseholdRecoveryError.validationFailed
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let syncResult = Darwin.fsync(descriptor)
        let closeResult = Darwin.close(descriptor)
        guard syncResult == 0, closeResult == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A stable restore identity makes replay after termination idempotent:
    /// the same archive cannot create a fresh CloudKit zone on every retry.
    nonisolated static func detachedHouseholdUUID(for archiveURL: URL) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(archiveURL.lastPathComponent.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
