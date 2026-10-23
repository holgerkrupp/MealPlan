import CloudKit
import CollaborationCloudKit
import CollaborationCore
import CryptoKit
import Darwin
import Foundation
import OSLog
import SwiftData

struct HouseholdShareLocator: Codable, Equatable, Sendable {
    static let zonePrefix = "MealPlanHousehold-"

    var zoneName: String
    var ownerName: String
    var shareRecordName: String?
    var isOwner: Bool
    var isReadOnly: Bool

    var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
    }

    var shareRecordID: CKRecord.ID? {
        shareRecordName.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
    }

    static func solo(householdID: UUID) -> HouseholdShareLocator {
        .init(
            zoneName: "\(zonePrefix)\(householdID.uuidString)",
            ownerName: CKCurrentUserDefaultName,
            shareRecordName: nil,
            isOwner: true,
            isReadOnly: false
        )
    }

    static func householdID(from zoneID: CKRecordZone.ID) -> UUID? {
        guard zoneID.zoneName.hasPrefix(zonePrefix) else { return nil }
        return UUID(uuidString: String(zoneID.zoneName.dropFirst(zonePrefix.count)))
    }

    static func encode(_ locator: HouseholdShareLocator) throws -> String {
        try JSONEncoder().encode(locator).base64EncodedString()
    }

    static func decode(_ value: String?) -> HouseholdShareLocator? {
        guard let value, let data = Data(base64Encoded: value) else { return nil }
        return try? JSONDecoder().decode(HouseholdShareLocator.self, from: data)
    }
}

struct HouseholdSyncTombstone: Codable, Equatable, Sendable {
    var markerUUID: UUID
    var deletedType: HouseholdRecordType
    var deletedUUID: UUID
    var deletedAt: Date
}

struct HouseholdSyncMetadata: Codable, Equatable, Sendable {
    /// The last value confirmed by CloudKit. A local scan must always compare
    /// against this baseline, never against the value merely put into the
    /// engine's pending queue.
    var serverFingerprints: [String: String] = [:]
    var serverGroupFingerprints: [String: [String: String]] = [:]
    /// Values queued for CloudKit but not acknowledged yet. These are
    /// persisted because the engine's state serialization and UserDefaults
    /// metadata do not commit atomically.
    var pendingFingerprints: [String: String] = [:]
    var pendingGroupFingerprints: [String: [String: String]] = [:]
    var systemFields: [String: Data] = [:]
    var tombstones: [HouseholdSyncTombstone] = []
    var needsFullUpload = false

    private enum CodingKeys: String, CodingKey {
        case serverFingerprints, serverGroupFingerprints
        case pendingFingerprints, pendingGroupFingerprints
        case systemFields, tombstones, needsFullUpload
        // Names used by builds before queued and acknowledged state was split.
        case fingerprints, groupFingerprints
    }

    init() {}

    /// A pending save already represents the current local value. Compare
    /// against that value first; comparing against both baselines with `||`
    /// queued every unchanged record again after each successful send.
    func shouldQueue(_ name: String, fingerprint: String) -> Bool {
        if needsFullUpload { return true }
        if let pending = pendingFingerprints[name] { return pending != fingerprint }
        return serverFingerprints[name] != fingerprint
    }

    func shouldTouch(_ name: String, fingerprint: String) -> Bool {
        guard let server = serverFingerprints[name], server != fingerprint else { return false }
        return pendingFingerprints[name] != fingerprint
    }

    /// An older upload may finish after a newer edit was staged for the same
    /// record ID. Only acknowledge the bytes the server actually saved.
    /// Return true when the current local record must be queued again.
    mutating func acknowledgeSavedRecord(_ name: String, fingerprint: String) -> Bool {
        let pending = pendingFingerprints.removeValue(forKey: name)
        let pendingGroups = pendingGroupFingerprints.removeValue(forKey: name)
        serverFingerprints[name] = fingerprint
        if pending == fingerprint {
            if let pendingGroups { serverGroupFingerprints[name] = pendingGroups }
            return false
        }
        return pending != nil
    }

    /// The package journal is the durable list of uploads still to send. An
    /// older process may have acknowledged a journal entry but ended before
    /// writing this metadata. Clear those stale pending markers so the next
    /// local scan compares the record with the actual server baseline.
    mutating func prunePendingMissingFromJournal(_ journalNames: Set<String>) -> Int {
        let stale = Set(pendingFingerprints.keys).subtracting(journalNames)
        for name in stale {
            pendingFingerprints.removeValue(forKey: name)
            pendingGroupFingerprints.removeValue(forKey: name)
        }
        return stale.count
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let server = try values.decodeIfPresent([String: String].self, forKey: .serverFingerprints) {
            serverFingerprints = server
            serverGroupFingerprints = try values.decodeIfPresent([String: [String: String]].self, forKey: .serverGroupFingerprints) ?? [:]
            pendingFingerprints = try values.decodeIfPresent([String: String].self, forKey: .pendingFingerprints) ?? [:]
            pendingGroupFingerprints = try values.decodeIfPresent([String: [String: String]].self, forKey: .pendingGroupFingerprints) ?? [:]
            needsFullUpload = try values.decodeIfPresent(Bool.self, forKey: .needsFullUpload) ?? false
        } else {
            // A legacy fingerprint was only "observed", not necessarily
            // acknowledged. Re-uploading the current local snapshot once is
            // the conservative migration for user-created records.
            serverFingerprints = try values.decodeIfPresent([String: String].self, forKey: .fingerprints) ?? [:]
            serverGroupFingerprints = try values.decodeIfPresent([String: [String: String]].self, forKey: .groupFingerprints) ?? [:]
            needsFullUpload = true
        }
        systemFields = try values.decodeIfPresent([String: Data].self, forKey: .systemFields) ?? [:]
        tombstones = try values.decodeIfPresent([HouseholdSyncTombstone].self, forKey: .tombstones) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(serverFingerprints, forKey: .serverFingerprints)
        try values.encode(serverGroupFingerprints, forKey: .serverGroupFingerprints)
        try values.encode(pendingFingerprints, forKey: .pendingFingerprints)
        try values.encode(pendingGroupFingerprints, forKey: .pendingGroupFingerprints)
        try values.encode(systemFields, forKey: .systemFields)
        try values.encode(tombstones, forKey: .tombstones)
        try values.encode(needsFullUpload, forKey: .needsFullUpload)
    }
}

enum HouseholdSyncMetadataMigrationStage: String, Codable, Sendable {
    case decodeLegacy
    case readExistingFile
    case decodeExistingFile
    case compareCopies
    case stageWrite
    case verifyReadback
}

enum HouseholdSyncMetadataMigrationResolution {
    case empty
    case existing(HouseholdSyncMetadata, retireLegacy: Bool)
    case migrate(HouseholdSyncMetadata, Data)

    static func resolve(legacyData: Data?, fileData: Data?) throws -> Self {
        let legacy: HouseholdSyncMetadata?
        if let legacyData {
            do { legacy = try JSONDecoder().decode(HouseholdSyncMetadata.self, from: legacyData) }
            catch {
                throw HouseholdRecordSyncError.migrationVerificationFailed(
                    stage: .decodeLegacy,
                    bytes: legacyData.count,
                    sha256: digest(legacyData)
                )
            }
        } else {
            legacy = nil
        }

        let file: HouseholdSyncMetadata?
        if let fileData {
            do { file = try JSONDecoder().decode(HouseholdSyncMetadata.self, from: fileData) }
            catch {
                throw HouseholdRecordSyncError.migrationVerificationFailed(
                    stage: .decodeExistingFile,
                    bytes: fileData.count,
                    sha256: digest(fileData)
                )
            }
        } else {
            file = nil
        }

        switch (legacy, legacyData, file, fileData) {
        case (nil, nil, nil, nil):
            return .empty
        case (let existing?, let data?, nil, nil):
            return .migrate(existing, data)
        case (nil, nil, let existing?, _):
            return .existing(existing, retireLegacy: false)
        case (let old?, _, let current?, _):
            guard old == current else {
                throw HouseholdRecordSyncError.metadataCopiesDiverged(
                    legacyBytes: legacyData?.count ?? 0,
                    fileBytes: fileData?.count ?? 0,
                    legacyHash: digest(legacyData ?? Data()),
                    fileHash: digest(fileData ?? Data()),
                    legacyPending: old.pendingFingerprints.count,
                    filePending: current.pendingFingerprints.count,
                    legacyTombstones: old.tombstones.count,
                    fileTombstones: current.tombstones.count
                )
            }
            return .existing(current, retireLegacy: true)
        default:
            throw HouseholdRecordSyncError.migrationVerificationFailed(stage: .compareCopies, bytes: 0, sha256: "unavailable")
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum HouseholdRemoteFetchOutcome: Sendable {
    case newData
    case noData
    case failed
}

/// The sole CloudKit transport for the App Group SwiftData store. It scans
/// stable per-record fingerprints after saves, and lets CKSyncEngine own
/// subscriptions, change tokens, retries, and partial failures.
@MainActor
final class HouseholdRecordSyncService {
    static let shared = HouseholdRecordSyncService()

    private let container = CKContainer(identifier: SharedStore.cloudKitContainerID)
    private let delegate = HouseholdRecordSyncDelegate()
    private var syncEnginePool: CloudKitSyncEnginePool?
    private var packageStateStore: MealPlanCloudKitStateStore?
    #if os(macOS)
    // A Mac can launch two copies against the same App Group store. On iOS,
    // only the main app owns sync; holding this lock through suspension causes
    // 0xdead10cc kills.
    private var syncOwnerFD: Int32?
    #endif
    private var stateStoreAccountPartitionIdentifier: String?
    private var household: Household?
    private var context: ModelContext?
    private var modelContainer: ModelContainer?
    private var snapshotActor: HouseholdSnapshotActor?
    private var snapshotActorCreationTask: Task<HouseholdSnapshotActor, Never>?
    private var locator: HouseholdShareLocator?
    private var metadata = HouseholdSyncMetadata()
    private var saveObserver: NSObjectProtocol?
    private var scheduledScan: Task<Void, Never>?
    /// CloudKit pushes can be delayed even while the iPhone is open. A modest
    /// foreground fetch cadence bounds visible plan latency in that case.
    private var foregroundPollTask: Task<Void, Never>?
    /// Only one snapshot/fingerprint pass may run at once. A second caller
    /// joins the pass instead of reading the same large store concurrently.
    private var localScanTask: Task<Void, Error>?
    /// CKSyncEngine traps when explicit fetch/send operations overlap. Keep a
    /// single ordered chain for launch sync, save-driven sends, and pushes.
    private var cloudOperationTask: Task<Void, Never>?
    /// CKSyncEngine requests pending records one at a time. Keep the snapshots
    /// prepared by the scan so that callback is O(1), not a full household
    /// rebuild (including every externally stored photo) per record.
    private var pendingSnapshots: [String: LocalHouseholdRecord] = [:]
    private var needsLocalScan = true
    private var didRestoreTombstoneOperations = false
    private var isApplyingRemoteChanges = false
    private var isWaitingToApplyRemoteChanges = false
    /// The scene lifecycle closes admission for new unbounded scans as soon
    /// as the UI leaves the foreground. Already-entered persistence units are
    /// allowed to finish so cancellation never tears through a save.
    private var admitsForegroundWork = true
    private var appliedRemoteRecordCount = 0
    private var cancelAtPersistenceBoundary = false
    /// Generation observed after the last local scan. A missing value from an
    /// older app is deliberately treated as dirty once, not as clean.
    private var lastObservedStoreGeneration: UInt64?
    private(set) var lastError: Error?
    private let logger = Logger(subsystem: "de.holgerkrupp.mealplan", category: "household-record-sync")
    private let metadataWriter = HouseholdMetadataWriter()

    private init() {}

    var isReadOnly: Bool { locator?.isReadOnly == true }

    /// A push has already applied zone changes. Only an actual CKShare needs
    /// the scene's follow-up participant/role refresh.
    var hasActiveShare: Bool { locator?.shareRecordID != nil }

    func synchronize(household: Household, context: ModelContext) async throws {
        guard admitsForegroundWork else { return }
        try await activateIfNeeded(household: household, context: context)
        #if os(iOS)
        startForegroundPolling()
        #endif
        guard let locator else { return }
        observeExternalStoreGeneration()
        if !locator.isReadOnly, needsLocalScan { try await scanLocalChanges() }
        await performCloudOperation(fetch: true, send: !locator.isReadOnly)
        if let lastError { throw lastError }
    }

    func prepareTransport(household: Household, context: ModelContext) async throws -> CloudKitSyncEnginePool {
        try await activateIfNeeded(household: household, context: context)
        guard let syncEnginePool else { throw HouseholdRecordSyncError.stateStoreUnavailable }
        return syncEnginePool
    }

    func setForegroundWorkAdmission(_ admitted: Bool) {
        logger.info("scene.lifecycle foregroundWork=\(admitted, privacy: .public)")
        admitsForegroundWork = admitted
        if admitted {
            cancelAtPersistenceBoundary = false
            #if os(iOS)
            startForegroundPolling()
            #endif
            if needsLocalScan { scheduleScan() }
            return
        }
        foregroundPollTask?.cancel()
        foregroundPollTask = nil
        scheduledScan?.cancel()
        scheduledScan = nil
        // A scan interrupted between persistence units remains dirty and is
        // retried after the next foreground activation.
        needsLocalScan = true
    }

    /// Requests an expiring background fetch to stop before its next database
    /// transaction. An entered transaction is allowed to save or roll back.
    func requestCancellationAtPersistenceBoundary() {
        cancelAtPersistenceBoundary = true
    }

    func prepareRemoteFetch() {
        cancelAtPersistenceBoundary = false
        // A package-owned shared-database fetch runs outside
        // performCloudOperation. Clear its prior result so the caller can use
        // lastError to distinguish this fetch's delegate apply outcome.
        lastError = nil
    }

    func fetchChanges(shouldScanLocalChanges: Bool = true) async -> HouseholdRemoteFetchOutcome {
        guard let locator else { return .noData }
        if shouldScanLocalChanges { observeExternalStoreGeneration() }
        // A fetch can arrive through launch/bootstrap without the explicit
        // synchronize() path. Capture local edits first so that this fetch
        // cannot make them look acknowledged.
        if shouldScanLocalChanges, admitsForegroundWork, !locator.isReadOnly, needsLocalScan {
            do { try await scanLocalChanges() }
            catch { lastError = error; return .failed }
        }
        let previousAppliedCount = appliedRemoteRecordCount
        await performCloudOperation(fetch: true, send: false)
        if lastError != nil { return .failed }
        return appliedRemoteRecordCount == previousAppliedCount ? .noData : .newData
    }

    func stop() async {
        scheduledScan?.cancel()
        scheduledScan = nil
        foregroundPollTask?.cancel()
        foregroundPollTask = nil
        localScanTask?.cancel()
        try? await localScanTask?.value
        localScanTask = nil
        cloudOperationTask?.cancel()
        cloudOperationTask = nil
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        saveObserver = nil
        await syncEnginePool?.shutdown()
        syncEnginePool = nil
        #if os(macOS)
        if let syncOwnerFD {
            flock(syncOwnerFD, LOCK_UN)
            close(syncOwnerFD)
            self.syncOwnerFD = nil
        }
        #endif
        household = nil
        context = nil
        modelContainer = nil
        snapshotActor = nil
        snapshotActorCreationTask = nil
        locator = nil
        pendingSnapshots.removeAll(keepingCapacity: false)
        needsLocalScan = true
        didRestoreTombstoneOperations = false
        lastObservedStoreGeneration = nil
    }

    private func startForegroundPolling() {
        guard admitsForegroundWork, foregroundPollTask == nil else { return }
        foregroundPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                if let service = self, service.admitsForegroundWork, service.locator != nil {
                    _ = await service.fetchChanges(shouldScanLocalChanges: false)
                }
            }
        }
    }

    /// Forgets everything stored for syncing `locator`'s zone. Used once this
    /// device has lost access to a shared household: if it were ever invited
    /// back, the old fingerprints would read as local deletions and queue
    /// deletes for the owner's records.
    func discardState(for locator: HouseholdShareLocator) async throws {
        let metadataURL = try metadataFileURL(for: locator)
        let legacyMetadataURL = try legacyMetadataFileURL(for: locator)
        let metadataRecoveryURL = HouseholdMetadataWriter.recoveryDirectory(for: metadataURL)
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            try FileManager.default.removeItem(at: metadataURL)
        }
        if FileManager.default.fileExists(atPath: metadataRecoveryURL.path) {
            try FileManager.default.removeItem(at: metadataRecoveryURL)
        }
        if FileManager.default.fileExists(atPath: legacyMetadataURL.path) {
            try FileManager.default.removeItem(at: legacyMetadataURL)
        }
        if !locator.isOwner, let packageStateStore {
            try await packageStateStore.discardDatabaseState(for: .shared)
        }
        defaults.removeObject(forKey: stateKey(for: locator))
        defaults.removeObject(forKey: legacyMetadataKey(for: locator))
    }

    func record(
        for id: CKRecord.ID,
        fallbackSnapshots: [String: LocalHouseholdRecord]? = nil
    ) async throws -> CKRecord? {
        guard id.zoneID == locator?.zoneID else { return nil }
        if let identity = HouseholdRecordIdentity(recordType: HouseholdRecordType.deletionMarker.rawValue, recordName: id.recordName),
           let household {
            guard let tombstone = metadata.tombstones.first(where: { $0.markerUUID == identity.uuid }) else { return nil }
            let payload = HouseholdRecordPayload.deletionMarker(.init(
                deletedType: tombstone.deletedType,
                deletedUUID: tombstone.deletedUUID,
                deletedAt: tombstone.deletedAt
            ))
            let snapshot = LocalHouseholdRecord(
                identity: identity,
                householdID: household.uuid,
                modifiedAt: tombstone.deletedAt,
                payloadData: try HouseholdRecordCodec.encode(payload)
            )
            let systemRecord = metadata.systemFields[id.recordName].flatMap(decodeSystemFields)
            return try await makeCloudRecord(from: snapshot, zoneID: id.zoneID, systemRecord: systemRecord)
        }
        let snapshot: LocalHouseholdRecord?
        if let pending = pendingSnapshots[id.recordName] {
            snapshot = pending
        } else if let fallbackSnapshots {
            snapshot = fallbackSnapshots[id.recordName]
        } else {
            snapshot = try await snapshotsByName()[id.recordName]
        }
        guard let snapshot else { return nil }
        let systemRecord = metadata.systemFields[id.recordName].flatMap(decodeSystemFields)
        return try await makeCloudRecord(from: snapshot, zoneID: id.zoneID, systemRecord: systemRecord)
    }

    private func makeCloudRecord(
        from snapshot: LocalHouseholdRecord,
        zoneID: CKRecordZone.ID,
        systemRecord: CKRecord?
    ) async throws -> CKRecord {
        var uploadSnapshot = snapshot
        if uploadSnapshot.identity.type == .dishImage, uploadSnapshot.assetData == nil,
           let snapshotActor = await backgroundSnapshotActor() {
            uploadSnapshot.assetData = try await snapshotActor.imageData(
                for: uploadSnapshot.identity.uuid,
                matching: uploadSnapshot.assetDigest
            )
        }
        return try HouseholdRecordCodec.makeRecord(
            from: uploadSnapshot,
            zoneID: zoneID,
            systemRecord: systemRecord
        )
    }

    func handle(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            switch event {
            case .stateUpdate:
                // The package's database-scoped state store persists engine
                // serializations before forwarding events to this delegate.
                break
            case .fetchedRecordZoneChanges(let changes):
                try await applyFetchedChanges(changes)
            case .sentRecordZoneChanges(let changes):
                try await packageStateStore?.acknowledgeSentChanges(
                    savedRecords: changes.savedRecords,
                    deletedRecordIDs: changes.deletedRecordIDs,
                    in: activeScope
                )
                try await handleSentChanges(changes)
            case .sentDatabaseChanges(let changes):
                if let failure = changes.failedZoneSaves.first { lastError = failure.error }
            case .accountChange:
                metadata = HouseholdSyncMetadata()
                try await persistMetadata()
            case .fetchedDatabaseChanges, .willFetchChanges, .willFetchRecordZoneChanges,
                 .didFetchRecordZoneChanges, .didFetchChanges, .willSendChanges, .didSendChanges:
                break
            @unknown default:
                break
            }
        } catch {
            lastError = error
            let failure = error as NSError
            logger.error("CloudKit delegate failed (domain=\(failure.domain, privacy: .public), code=\(failure.code, privacy: .public)).")
        }
    }

    func nextBatch(_ sendContext: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard locator?.isReadOnly != true, let zoneID = locator?.zoneID else { return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { change in
            guard sendContext.options.scope.contains(change) else { return false }
            switch change {
            case .saveRecord(let id), .deleteRecord(let id): return id.zoneID == zoneID
            @unknown default: return false
            }
        }
        let unresolvedNames = Set(pending.compactMap { change -> String? in
            guard case .saveRecord(let id) = change,
                  pendingSnapshots[id.recordName] == nil,
                  HouseholdRecordIdentity(
                      recordType: HouseholdRecordType.deletionMarker.rawValue,
                      recordName: id.recordName
                  ) == nil
            else { return nil }
            return id.recordName
        })
        let fallbackSnapshots: [String: LocalHouseholdRecord]?
        if unresolvedNames.isEmpty {
            fallbackSnapshots = nil
        } else {
            do {
                // A durable journal can outlive the in-memory scan cache.
                // Rebuild once for this batch, rather than once per record.
                let all = try await snapshotsByName()
                fallbackSnapshots = all.filter { unresolvedNames.contains($0.key) }
            } catch {
                lastError = error
                return nil
            }
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            try? await HouseholdRecordSyncService.shared.record(
                for: id,
                fallbackSnapshots: fallbackSnapshots
            )
        }
    }

    // MARK: - Activation and local change capture

    private func activateIfNeeded(household: Household, context: ModelContext) async throws {
        let nextLocator = HouseholdShareLocator.decode(household.cloudKitShareIdentifier) ?? .solo(householdID: household.uuid)
        if self.household?.uuid == household.uuid, locator == nextLocator, syncEnginePool != nil { return }

        try acquireSyncOwnership()

        if self.household != nil {
            localScanTask?.cancel()
            try? await localScanTask?.value
            localScanTask = nil
            cloudOperationTask?.cancel()
            await cloudOperationTask?.value
            await syncEnginePool?.shutdown()
        }

        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        scheduledScan?.cancel()
        self.household = household
        self.context = context
        if modelContainer !== context.container {
            snapshotActor = nil
            snapshotActorCreationTask = nil
            modelContainer = context.container
        }
        locator = nextLocator
        metadata = .init()
        pendingSnapshots.removeAll(keepingCapacity: false)
        needsLocalScan = true
        didRestoreTombstoneOperations = false
        lastObservedStoreGeneration = nil

        let accountPartition = try await accountPartitionIdentifier()
        if stateStoreAccountPartitionIdentifier != accountPartition {
            packageStateStore = MealPlanCloudKitStateStore(
                containerIdentifier: SharedStore.cloudKitContainerID,
                environment: collaborationEnvironment,
                accountPartitionIdentifier: accountPartition,
                activeLocator: nextLocator
            )
            stateStoreAccountPartitionIdentifier = accountPartition
            syncEnginePool = nil
        } else {
            await packageStateStore?.setActiveLocator(nextLocator)
        }
        stateStoreAccountPartitionIdentifier = accountPartition
        guard let packageStateStore else {
            throw HouseholdRecordSyncError.stateStoreUnavailable
        }
        try await packageStateStore.prepareStorage()
        let migrationJournalCount = try await packageStateStore.pendingLocalChanges(in: activeScope).filter {
            $0.recordID.zoneID == nextLocator.zoneID
        }.count
        let metadataURL = try metadataFileURL(for: nextLocator)
        let legacyMetadataURL = try legacyMetadataFileURL(for: nextLocator)
        do {
            metadata = try await metadataWriter.load(
                legacyKey: legacyMetadataKey(for: nextLocator),
                legacyFileURL: legacyMetadataURL,
                activeFileURL: metadataURL,
                journalEntryCount: migrationJournalCount
            )
        } catch {
            lastError = error
            let failure = error as? HouseholdRecordSyncError
            let namespace = "\(accountPartition)|\(Self.storageSuffix(for: nextLocator, environment: BuildEnvironment.cloudKit))"
            let namespaceHash = Self.digest(Data(namespace.utf8))
            let binarySHA = await metadataWriter.executableSHA256() ?? "unavailable"
            let eventDetail = "\(failure?.supportDiagnostic ?? "stage=unknown"); journalEntries=\(migrationJournalCount); buildArtifactSHA256=\(binarySHA)"
            logger.error("metadata.migration.failed environment=\(BuildEnvironment.cloudKit.rawValue, privacy: .public) namespace=\(namespaceHash, privacy: .public) build=\(Self.buildIdentifier, privacy: .public) \(eventDetail, privacy: .public)")
            HouseholdSyncDiagnostics.record(
                event: "metadataMigrationFailed",
                locator: nextLocator,
                pendingCount: migrationJournalCount,
                detail: "environment=\(BuildEnvironment.cloudKit.rawValue); namespace=\(namespaceHash); build=\(Self.buildIdentifier); \(eventDetail)"
            )
            throw error
        }
        let pool = try await CloudKitSyncEnginePool.shared(
            containerIdentifier: SharedStore.cloudKitContainerID,
            environment: collaborationEnvironment,
            accountPartitionIdentifier: accountPartition,
            container: container,
            stateStore: packageStateStore,
            delegate: delegate,
            automaticallySync: false,
            subscriptionIDPrefix: "MealPlan"
        )
        self.syncEnginePool = pool
        try await pool.start()
        let journalNames = Set(try await packageStateStore.pendingLocalChanges(in: activeScope)
            .filter { $0.recordID.zoneID == nextLocator.zoneID }
            .map { $0.recordID.recordName })
        let stalePending = metadata.prunePendingMissingFromJournal(journalNames)
        if stalePending > 0 {
            try await persistMetadata()
            logger.info("Reconciled stale pending uploads (count=\(stalePending, privacy: .public)).")
        }
        HouseholdSyncDiagnostics.record(event: "activated", locator: nextLocator)
        if nextLocator.isOwner {
            try await pool.enqueue([.saveZone(CKRecordZone(zoneID: nextLocator.zoneID))], in: .private)
        }

        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: nil) { [weak self] _ in
            // The UI context posts synchronously during its save. Capture
            // its origin now: checking inside
            // the Task below is too late, after the apply flag has reset.
            let wasRemoteApply = MainActor.assumeIsolated { self?.isApplyingRemoteChanges == true }
            guard !wasRemoteApply else { return }
            Task { @MainActor in
                guard let self else { return }
                HouseholdStoreGeneration.markDirty()
                self.needsLocalScan = true
                self.scheduleScan()
            }
        }
    }

    /// Detects commits made by the Share Extension or another process using
    /// the App Group store. Only this main-app service scans and queues them
    /// through the package-owned CloudKit engine pool.
    private func observeExternalStoreGeneration() {
        let current = HouseholdStoreGeneration.value()
        guard let lastObservedStoreGeneration else {
            self.lastObservedStoreGeneration = current
            needsLocalScan = true
            return
        }
        guard current != lastObservedStoreGeneration else { return }
        self.lastObservedStoreGeneration = current
        needsLocalScan = true
        scheduleScan()
    }

    private func scheduleScan() {
        guard admitsForegroundWork, !isApplyingRemoteChanges, !isWaitingToApplyRemoteChanges,
              locator?.isReadOnly != true else { return }
        scheduledScan?.cancel()
        scheduledScan = Task { @MainActor [weak self] in
            // Coalesce a burst of saves without making another device wait
            // five seconds before CloudKit even sees a plan edit.
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self, self.admitsForegroundWork else { return }
            do {
                try await self.scanLocalChanges()
                guard !Task.isCancelled, self.admitsForegroundWork else { return }
                await self.performCloudOperation(fetch: false, send: true)
            } catch {
                if !(error is CancellationError) { self.lastError = error }
            }
        }
    }

    private func scanLocalChanges() async throws {
        while admitsForegroundWork, needsLocalScan, !isApplyingRemoteChanges, !isWaitingToApplyRemoteChanges {
            if let localScanTask {
                try await localScanTask.value
                // The owner clears the task after completion. Recheck that
                // slot before attempting another scan: multiple callers can
                // wake from the same task at once.
                if self.localScanTask != nil { await Task.yield() }
                continue
            }
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                try await self.performLocalScan()
            }
            localScanTask = task
            do {
                try await task.value
            } catch {
                localScanTask = nil
                throw error
            }
            localScanTask = nil
        }
    }

    private func performLocalScan() async throws {
        guard admitsForegroundWork, let household, let syncEnginePool, let locator, !locator.isReadOnly else { return }
        let startedGeneration = HouseholdStoreGeneration.value()
        let startedAt = ContinuousClock.now
        logger.info("scan.start")
        defer {
            let duration = startedAt.duration(to: .now)
            logger.info("scan.end duration=\(duration, privacy: .public)")
        }
        let previousMetadata = metadata
        let previousTombstoneRestoreState = didRestoreTombstoneOperations
        var snapshots = Self.canonicalSnapshots(try await snapshotRecords(for: household.uuid))
        // Photo hashes are deliberately expensive. Calculate every snapshot's
        // fingerprint once per scan and carry it through both passes.
        let initialSnapshots = snapshots
        var evaluated = await Task.detached(priority: .utility) {
            initialSnapshots.map { (snapshot: $0, fingerprint: $0.fingerprint) }
        }.value
        var changesToTouch: [(identity: HouseholdRecordIdentity, changedGroups: Set<String>)] = []

        for item in evaluated where metadata.shouldTouch(item.snapshot.identity.recordName, fingerprint: item.fingerprint) {
            let snapshot = item.snapshot
            // A record already queued for upload will differ from the server
            // until CloudKit acknowledges it. Touching that same difference
            // on every scan changes modifiedAt again and creates an endless
            // stream of uploads. Compare with the pending local value first.
            let previousGroups = metadata.pendingGroupFingerprints[snapshot.identity.recordName]
                ?? metadata.serverGroupFingerprints[snapshot.identity.recordName] ?? [:]
            let changedGroups = Set(snapshot.groupFingerprints.compactMap { previousGroups[$0.key] == $0.value ? nil : $0.key })
            if !snapshot.groupFingerprints.isEmpty, changedGroups.isEmpty { continue }
            changesToTouch.append((snapshot.identity, changedGroups))
        }
        if !changesToTouch.isEmpty {
            let touchTypes = Dictionary(grouping: changesToTouch, by: { $0.identity.type.rawValue })
                .map { "\($0.key):\($0.value.count)" }.sorted().joined(separator: ",")
            logger.info("scan.touch.types \(touchTypes, privacy: .public)")
            // Advancing sync clocks can update hundreds of legacy records.
            // Save them through a private SwiftData executor so SQLite never
            // blocks the scrolling main context.
            try await touchRecords(changesToTouch, householdID: household.uuid)
            snapshots = Self.canonicalSnapshots(try await snapshotRecords(for: household.uuid))
            let touchedSnapshots = snapshots
            evaluated = await Task.detached(priority: .utility) {
                touchedSnapshots.map { (snapshot: $0, fingerprint: $0.fingerprint) }
            }.value
        }

        let byName = Self.keyedSnapshots(snapshots)
        var cloudChanges: [CloudKitRecordChange] = []
        for item in evaluated {
            let snapshot = item.snapshot
            let name = snapshot.identity.recordName
            guard metadata.shouldQueue(name, fingerprint: item.fingerprint) else { continue }
            let id = CKRecord.ID(recordName: snapshot.identity.recordName, zoneID: locator.zoneID)
            pendingSnapshots[snapshot.identity.recordName] = snapshot
            metadata.pendingFingerprints[name] = item.fingerprint
            metadata.pendingGroupFingerprints[name] = snapshot.groupFingerprints
            let systemRecord = metadata.systemFields[name].flatMap(decodeSystemFields)
            cloudChanges.append(.save(try await makeCloudRecord(from: snapshot, zoneID: id.zoneID, systemRecord: systemRecord)))
        }

        let liveNames = Set(byName.keys)
        let existingTombstones = Set(metadata.tombstones.map { "\($0.deletedType.rawValue)-\($0.deletedUUID.uuidString)" })
        let previouslyKnown = Set(metadata.serverFingerprints.keys)
            .union(metadata.pendingFingerprints.keys)
            .subtracting(metadata.tombstones.map { HouseholdRecordIdentity(type: .deletionMarker, uuid: $0.markerUUID).recordName })
        for deletedName in previouslyKnown.subtracting(liveNames) {
            guard let identity = identity(fromRecordName: deletedName), identity.type != .deletionMarker else { continue }
            guard !existingTombstones.contains(identity.recordName) else { continue }
            let tombstone = HouseholdSyncTombstone(markerUUID: UUID(), deletedType: identity.type, deletedUUID: identity.uuid, deletedAt: .now)
            metadata.tombstones.append(tombstone)
            metadata.serverFingerprints.removeValue(forKey: deletedName)
            metadata.serverGroupFingerprints.removeValue(forKey: deletedName)
            metadata.pendingFingerprints.removeValue(forKey: deletedName)
            metadata.pendingGroupFingerprints.removeValue(forKey: deletedName)
            pendingSnapshots.removeValue(forKey: deletedName)
            cloudChanges.append(.delete(CKRecord.ID(recordName: deletedName, zoneID: locator.zoneID)))
            let markerID = CKRecord.ID(recordName: HouseholdRecordIdentity(type: .deletionMarker, uuid: tombstone.markerUUID).recordName, zoneID: locator.zoneID)
            if let markerRecord = try await record(for: markerID) { cloudChanges.append(.save(markerRecord)) }
        }

        // The package journal now survives the crash window before metadata
        // persistence. Only a legacy marker that has never been acknowledged
        // needs one-time restoration. Replaying every historical tombstone
        // queued two unnecessary operations per deletion on every launch.
        if !didRestoreTombstoneOperations {
            let alreadyQueued = Set(cloudChanges.map { $0.recordID.recordName })
            for tombstone in metadata.tombstones {
                let markerName = HouseholdRecordIdentity(type: .deletionMarker, uuid: tombstone.markerUUID).recordName
                guard metadata.serverFingerprints[markerName] == nil else { continue }
                let deletedName = HouseholdRecordIdentity(type: tombstone.deletedType, uuid: tombstone.deletedUUID).recordName
                if !alreadyQueued.contains(deletedName) {
                    cloudChanges.append(.delete(CKRecord.ID(recordName: deletedName, zoneID: locator.zoneID)))
                }
                if !alreadyQueued.contains(markerName) {
                    let markerID = CKRecord.ID(recordName: markerName, zoneID: locator.zoneID)
                    if let markerRecord = try await record(for: markerID) { cloudChanges.append(.save(markerRecord)) }
                }
            }
            didRestoreTombstoneOperations = true
        }

        do {
            if !cloudChanges.isEmpty {
                let counts = Dictionary(grouping: cloudChanges) { change -> String in
                    switch change {
                    case .save(let record): record.recordType
                    case .delete(let id): identity(fromRecordName: id.recordName)?.type.rawValue ?? "delete"
                    }
                }.map { "\($0.key):\($0.value.count)" }.sorted().joined(separator: ",")
                logger.info("Queued household changes (types=\(counts, privacy: .public)).")
                try await syncEnginePool.enqueue(cloudChanges, in: activeScope)
            }
        } catch {
            // The package journal did not accept this batch. Keep the old
            // acknowledged/pending baseline so a later scan retries it.
            metadata = previousMetadata
            didRestoreTombstoneOperations = previousTombstoneRestoreState
            pendingSnapshots.removeAll()
            needsLocalScan = true
            throw error
        }
        // The journal is durable first. If persistence fails or the process
        // ends here, replaying a record is safe; losing an edit is not.
        let shouldPersistMetadata = metadata.needsFullUpload || !cloudChanges.isEmpty
        metadata.needsFullUpload = false
        if shouldPersistMetadata { try await persistMetadata() }
        let finishedGeneration = HouseholdStoreGeneration.value()
        needsLocalScan = !admitsForegroundWork || finishedGeneration != startedGeneration
        lastObservedStoreGeneration = finishedGeneration
        if needsLocalScan { scheduleScan() }
        HouseholdSyncDiagnostics.record(
            event: "scanned",
            locator: locator,
            pendingCount: metadata.pendingFingerprints.count
        )
    }

    /// Runs each explicit operation behind the previous one. Package engine
    /// calls use the same detached boundary as the old owner so fetch/send
    /// requests cannot overlap delegate callbacks.
    private func performCloudOperation(fetch: Bool, send: Bool) async {
        let previous = cloudOperationTask
        // Reserve our place before the first suspension. Otherwise two push
        // handlers can await the same predecessor and enter CKSyncEngine at
        // the same time once it completes.
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            await self.runCloudOperation(fetch: fetch, send: send)
        }
        cloudOperationTask = task
        await task.value
    }

    private func runCloudOperation(fetch: Bool, send: Bool) async {
        guard let syncEnginePool, let locator = self.locator else { return }
        lastError = nil
        let zoneID = locator.zoneID
        let maySend = send && !locator.isReadOnly
        let scope = activeScope
        let stateStore = packageStateStore
        let startedAt = ContinuousClock.now
        if fetch { logger.info("sync.fetch.start") }
        if maySend { logger.info("sync.send.start") }

        let detached = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return nil as Error? }
            var operationError: Error?

            if fetch {
                do {
                    try await syncEnginePool.fetchChanges(in: scope, zoneIDs: [zoneID])
                } catch {
                    operationError = error
                }
            }

            // A first-time owner may not have a server zone to fetch yet. Still
            // run the send so pending zone creation can establish it.
            if maySend {
                // A conflict can restage a newer version while its older
                // save is still in flight. CKSyncEngine may remove that ID
                // from its pending state when the old save completes, while
                // the durable journal correctly keeps the newer version.
                // Replay the journal after each pass until it drains.
                for _ in 0..<3 {
                    do {
                        try await syncEnginePool.restorePendingChanges(in: scope)
                        await Task.yield()
                        try await syncEnginePool.sendChanges(in: scope, zoneIDs: [zoneID])
                    } catch {
                        if operationError == nil { operationError = error }
                        if !Self.isResolvedConflictSendError(error) { break }
                    }
                    do {
                        let pending = try await stateStore?.pendingLocalChanges(in: scope) ?? []
                        if !pending.contains(where: { $0.recordID.zoneID == zoneID }) { break }
                    } catch {
                        if operationError == nil { operationError = error }
                        break
                    }
                }
            }

            return operationError
        }
        let error = await detached.value
        // CKSyncEngine also throws the aggregate partial failure after it
        // has delivered per-record conflicts to our delegate. Those
        // conflicts have already been merged and requeued with the server
        // change tags; showing the aggregate as an alert is misleading.
        if let error {
            let failure = error as NSError
            let codes = Self.partialFailureCodes(error)
            if Self.isResolvedConflictSendError(error) {
                logger.info("CloudKit delivered recoverable record conflicts (count=\(codes.count, privacy: .public)).")
            } else {
                logger.error("CloudKit operation failed (domain=\(failure.domain, privacy: .public), code=\(failure.code, privacy: .public), itemCodes=\(codes.description, privacy: .public)).")
                lastError = error
            }
        }
        let duration = startedAt.duration(to: .now)
        if fetch { logger.info("sync.fetch.end duration=\(duration, privacy: .public)") }
        if maySend { logger.info("sync.send.end duration=\(duration, privacy: .public)") }
    }

    // MARK: - Remote change application

    private func applyFetchedChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) async throws {
        guard let household, let context, let locator else { return }
        // A launch/save scan may still be building its baseline when a push
        // arrives. Let it finish before the incoming records mutate the same
        // metadata and SwiftData store.
        isWaitingToApplyRemoteChanges = true
        while let localScanTask { try? await localScanTask.value; await Task.yield() }
        isWaitingToApplyRemoteChanges = false
        isApplyingRemoteChanges = true
        defer {
            isApplyingRemoteChanges = false
            if needsLocalScan { scheduleScan() }
        }

        var local = Self.keyedSnapshots(try await snapshotRecords(for: household.uuid))
        let modifications = changes.modifications
            .filter { $0.record.recordID.zoneID == locator.zoneID }
            .sorted { priority($0.record) < priority($1.record) }
        let deletions = changes.deletions
            .filter { $0.recordID.zoneID == locator.zoneID }
            .sorted { deletionPriority(recordType: $0.recordType) < deletionPriority(recordType: $1.recordType) }
        try Task.checkCancellation()
        guard !cancelAtPersistenceBoundary else { throw CancellationError() }
        let counts = Dictionary(grouping: modifications) { $0.record.recordType }
            .mapValues(\.count)
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: ",")
        SharedStore.logger.debug("Applying household fetch: modifications=\(modifications.count), deletions=\(deletions.count), types=\(counts, privacy: .public)")
        let transactionStartedAt = ContinuousClock.now
        logger.info("db.transaction.start records=\(modifications.count + deletions.count, privacy: .public)")

        var uploadNames = Set<String>()
        var modifiedNames = Set<String>()
        var removedNames = Set<String>()
        var serverFingerprints: [String: String] = [:]
        var stagedSystemFields: [String: Data] = [:]
        var markerLocalWins: [String: Bool] = [:]
        var outgoingChanges: [CloudKitRecordChange] = []

        do {
            try Task.checkCancellation()
            guard !cancelAtPersistenceBoundary else { throw CancellationError() }
            try nonUndoableStoreTransaction(in: context) {
                try HouseholdRecordApplier.withBatchLookup(
                    in: context,
                    expectedRecordCount: modifications.count + deletions.count
                ) {
                    for modification in modifications {
                        let record = modification.record
                        guard let identity = HouseholdRecordIdentity(recordType: record.recordType, recordName: record.recordID.recordName),
                              let payloadData = record[HouseholdRecordCodec.payloadKey] as? Data else { continue }

                        let name = identity.recordName
                        stagedSystemFields[name] = encodeSystemFields(record)
                        if identity.type == .deletionMarker {
                            guard case .deletionMarker(let marker) = try HouseholdRecordCodec.decode(payloadData) else { continue }
                            let target = HouseholdRecordIdentity(type: marker.deletedType, uuid: marker.deletedUUID)
                            let localTarget = local[target.recordName]
                            let localWins = HouseholdRecordConflictResolver.shouldPreserveLocalForDeletion(
                                local: localTarget,
                                deletedAt: marker.deletedAt
                            )
                            markerLocalWins[target.recordName] = localWins
                            if localWins {
                                uploadNames.insert(target.recordName)
                            } else {
                                try HouseholdRecordApplier.delete(type: marker.deletedType, uuid: marker.deletedUUID, context: context)
                                removedNames.insert(target.recordName)
                            }
                            serverFingerprints[name] = recordFingerprint(payloadData, assetData: nil)
                            continue
                        }

                        let serverAsset = record[HouseholdRecordCodec.assetKey] as? CKAsset
                        let serverAssetData = try Self.readAssetData(serverAsset)
                        let incomingFingerprint = recordFingerprint(payloadData, assetData: serverAssetData)
                        if let current = local[name],
                           current.fingerprint == incomingFingerprint,
                           current.modifiedAt == HouseholdRecordCodec.modifiedAt(of: record) {
                            serverFingerprints[name] = incomingFingerprint
                            continue
                        }
                        let resolution = try HouseholdRecordConflictResolver.resolve(
                            local: local[name],
                            server: record,
                            serverAssetData: serverAssetData,
                            serverHasAsset: serverAsset != nil
                        )
                        try HouseholdRecordApplier.apply(
                            payloadData: resolution.payloadData,
                            identity: identity,
                            modifiedAt: resolution.modifiedAt,
                            assetData: resolution.assetData,
                            household: household,
                            context: context
                        )
                        modifiedNames.insert(name)
                        if resolution.shouldUpload, !locator.isReadOnly {
                            uploadNames.insert(name)
                        }
                        serverFingerprints[name] = incomingFingerprint
                    }

                    for deletion in deletions {
                        guard let identity = HouseholdRecordIdentity(recordType: deletion.recordType, recordName: deletion.recordID.recordName) else { continue }
                        let name = identity.recordName
                        if markerLocalWins[name] == true {
                            uploadNames.insert(name)
                            continue
                        }
                        let isDirty = HouseholdRecordConflictResolver.shouldPreserveLocalForRawDeletion(
                            local: local[name],
                            acknowledgedFingerprint: metadata.serverFingerprints[name],
                            isPending: metadata.pendingFingerprints[name] != nil
                        )
                        if isDirty {
                            // A raw CK deletion has no conflict timestamp. A
                            // local-only or pending record is safer preserved and
                            // re-sent than silently erased.
                            if !locator.isReadOnly {
                                uploadNames.insert(name)
                            }
                            continue
                        }
                        try HouseholdRecordApplier.delete(type: identity.type, uuid: identity.uuid, context: context)
                        removedNames.insert(name)
                        serverFingerprints.removeValue(forKey: name)
                        stagedSystemFields.removeValue(forKey: name)
                    }

                    try context.save()
                }
            }
        } catch {
            // Do not leave partially-applied relationship mutations in the
            // main context after a failed fetched batch. The helper rolls
            // back before restoring the attached UI UndoManager.
            needsLocalScan = true
            throw error
        }

        appliedRemoteRecordCount += modifications.count + deletions.count
        let transactionDuration = transactionStartedAt.duration(to: .now)
        logger.info("db.transaction.end records=\(modifications.count + deletions.count, privacy: .public) duration=\(transactionDuration, privacy: .public)")

        local = Self.keyedSnapshots(try await snapshotRecords(for: household.uuid))
        let metadataBeforeQueue = metadata
        for (name, value) in serverFingerprints {
            metadata.serverFingerprints[name] = value
            if !uploadNames.contains(name), let snapshot = local[name] {
                metadata.serverGroupFingerprints[name] = snapshot.groupFingerprints
            }
        }
        for name in modifiedNames where !uploadNames.contains(name) {
            if let snapshot = local[name] {
                metadata.serverFingerprints[name] = snapshot.fingerprint
                metadata.serverGroupFingerprints[name] = snapshot.groupFingerprints
            }
        }
        for name in removedNames where !uploadNames.contains(name) {
            metadata.serverFingerprints.removeValue(forKey: name)
            metadata.serverGroupFingerprints.removeValue(forKey: name)
            metadata.pendingFingerprints.removeValue(forKey: name)
            metadata.pendingGroupFingerprints.removeValue(forKey: name)
            metadata.systemFields.removeValue(forKey: name)
            pendingSnapshots.removeValue(forKey: name)
        }
        if !locator.isReadOnly {
            for name in uploadNames {
                guard let snapshot = local[name] else { continue }
                let id = CKRecord.ID(recordName: name, zoneID: locator.zoneID)
                pendingSnapshots[name] = snapshot
                metadata.pendingFingerprints[name] = snapshot.fingerprint
                metadata.pendingGroupFingerprints[name] = snapshot.groupFingerprints
                let systemRecord = metadata.systemFields[name].flatMap(decodeSystemFields)
                outgoingChanges.append(.save(try await makeCloudRecord(from: snapshot, zoneID: id.zoneID, systemRecord: systemRecord)))
            }
        }
        for (name, fields) in stagedSystemFields {
            metadata.systemFields[name] = fields
        }
        do {
            if !outgoingChanges.isEmpty {
                try await syncEnginePool?.enqueue(outgoingChanges, in: activeScope)
            }
        } catch {
            metadata = metadataBeforeQueue
            needsLocalScan = true
            throw error
        }
        try await persistMetadata()
        HouseholdSyncDiagnostics.record(
            event: "fetched",
            locator: locator,
            pendingCount: metadata.pendingFingerprints.count
        )
        NotificationCenter.default.post(name: .mealPlanDataDidChange, object: nil)
    }

    private func handleSentChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) async throws {
        var didFail = false
        var needsRescanAfterAcknowledgement = false
        for record in changes.savedRecords {
            let name = record.recordID.recordName
            metadata.systemFields[name] = encodeSystemFields(record)
            if let payloadData = record[HouseholdRecordCodec.payloadKey] as? Data {
                let savedFingerprint = recordFingerprint(
                    payloadData,
                    assetData: try Self.readAssetData(record[HouseholdRecordCodec.assetKey] as? CKAsset)
                )
                if metadata.acknowledgeSavedRecord(name, fingerprint: savedFingerprint) {
                    needsRescanAfterAcknowledgement = true
                }
            } else if metadata.pendingFingerprints.removeValue(forKey: name) != nil {
                metadata.pendingGroupFingerprints.removeValue(forKey: name)
                needsRescanAfterAcknowledgement = true
            }
            pendingSnapshots.removeValue(forKey: name)
        }
        if needsRescanAfterAcknowledgement {
            needsLocalScan = true
            scheduleScan()
        }
        for recordID in changes.deletedRecordIDs {
            metadata.systemFields.removeValue(forKey: recordID.recordName)
            metadata.serverFingerprints.removeValue(forKey: recordID.recordName)
            metadata.serverGroupFingerprints.removeValue(forKey: recordID.recordName)
            metadata.pendingFingerprints.removeValue(forKey: recordID.recordName)
            metadata.pendingGroupFingerprints.removeValue(forKey: recordID.recordName)
            pendingSnapshots.removeValue(forKey: recordID.recordName)
        }
        let conflicts = changes.failedRecordSaves.compactMap { failure -> CKRecord? in
            guard failure.error.code == .serverRecordChanged else { return nil }
            return failure.error.serverRecord
        }
        if !conflicts.isEmpty {
            try await applyServerConflicts(conflicts)
            needsLocalScan = true
            scheduleScan()
        }
        for failure in changes.failedRecordSaves where failure.error.code != .serverRecordChanged || failure.error.serverRecord == nil {
            didFail = true
            lastError = failure.error
        }
        if let failure = changes.failedRecordDeletes.values.first {
            didFail = true
            lastError = failure
            needsLocalScan = true
        }
        try await persistMetadata()
        if let locator {
            HouseholdSyncDiagnostics.record(
                event: didFail ? "sendFailed" : "sent",
                locator: locator,
                pendingCount: metadata.pendingFingerprints.count
            )
        }
    }

    private func applyServerConflicts(_ servers: [CKRecord]) async throws {
        guard let household, let context else { return }
        let local: [String: LocalHouseholdRecord]
        do { local = Self.keyedSnapshots(try await snapshotRecords(for: household.uuid)) }
        catch {
            logConflictFailure(error, stage: "localSnapshot")
            throw error
        }
        var resolved: [(identity: HouseholdRecordIdentity, server: CKRecord, resolution: HouseholdRecordResolution, assetData: Data?)] = []
        for server in servers.sorted(by: { priority($0) < priority($1) }) {
            guard let identity = HouseholdRecordIdentity(recordType: server.recordType, recordName: server.recordID.recordName) else { continue }
            let asset = server[HouseholdRecordCodec.assetKey] as? CKAsset
            let assetData = try Self.readAssetData(asset)
            let resolution: HouseholdRecordResolution
            do {
                resolution = try HouseholdRecordConflictResolver.resolve(
                    local: pendingSnapshots[identity.recordName] ?? local[identity.recordName],
                    server: server,
                    serverAssetData: assetData,
                    serverHasAsset: asset != nil
                )
            } catch {
                logConflictFailure(error, stage: "resolve", recordType: server.recordType)
                throw error
            }
            resolved.append((identity, server, resolution, assetData))
        }
        do {
            try nonUndoableStoreTransaction(in: context) {
                try HouseholdRecordApplier.withBatchLookup(in: context, expectedRecordCount: resolved.count) {
                    for item in resolved {
                        do {
                            try HouseholdRecordApplier.apply(
                                payloadData: item.resolution.payloadData,
                                identity: item.identity,
                                modifiedAt: item.resolution.modifiedAt,
                                assetData: item.resolution.assetData,
                                household: household,
                                context: context
                            )
                        } catch {
                            logConflictFailure(error, stage: "apply", recordType: item.server.recordType)
                            throw error
                        }
                    }
                    try context.save()
                }
            }
        } catch {
            logConflictFailure(error, stage: "transaction")
            throw error
        }
        let current: [String: LocalHouseholdRecord]
        do { current = Self.keyedSnapshots(try await snapshotRecords(for: household.uuid)) }
        catch {
            logConflictFailure(error, stage: "updatedSnapshot")
            throw error
        }
        var outgoing: [CloudKitRecordChange] = []
        for item in resolved {
            let name = item.identity.recordName
            metadata.systemFields[name] = encodeSystemFields(item.server)
            metadata.serverFingerprints[name] = recordFingerprint(
                item.server[HouseholdRecordCodec.payloadKey] as? Data ?? Data(),
                assetData: item.assetData
            )
            if item.resolution.shouldUpload, let snapshot = current[name] {
                pendingSnapshots[name] = snapshot
                metadata.pendingFingerprints[name] = snapshot.fingerprint
                metadata.pendingGroupFingerprints[name] = snapshot.groupFingerprints
                do {
                    outgoing.append(.save(try await makeCloudRecord(
                        from: snapshot,
                        zoneID: item.server.recordID.zoneID,
                        systemRecord: item.server
                    )))
                } catch {
                    logConflictFailure(error, stage: "encode", recordType: item.server.recordType)
                    throw error
                }
            } else {
                metadata.pendingFingerprints.removeValue(forKey: name)
                metadata.pendingGroupFingerprints.removeValue(forKey: name)
            }
        }
        if !outgoing.isEmpty {
            do { try await syncEnginePool?.enqueue(outgoing, in: activeScope) }
            catch {
                logConflictFailure(error, stage: "enqueue")
                throw error
            }
        }
    }

    private func logConflictFailure(_ error: Error, stage: String, recordType: String = "batch") {
        let failure = error as NSError
        logger.error("CloudKit conflict failed (stage=\(stage, privacy: .public), recordType=\(recordType, privacy: .public), domain=\(failure.domain, privacy: .public), code=\(failure.code, privacy: .public)).")
    }

    // MARK: - Persistence and snapshots

    private func backgroundSnapshotActor() async -> HouseholdSnapshotActor? {
        if let snapshotActor { return snapshotActor }
        guard let modelContainer else { return nil }
        // Construct the SwiftData context away from the UI thread. Calls to
        // this actor are also made from detached tasks below; a call directly
        // from the main actor can execute there despite actor isolation.
        let creationTask: Task<HouseholdSnapshotActor, Never>
        if let snapshotActorCreationTask {
            creationTask = snapshotActorCreationTask
        } else {
            creationTask = Task.detached(priority: .utility) {
                HouseholdSnapshotActor(modelContainer: modelContainer)
            }
            snapshotActorCreationTask = creationTask
        }
        let actor = await creationTask.value
        guard self.modelContainer === modelContainer else { return nil }
        snapshotActor = actor
        snapshotActorCreationTask = nil
        return actor
    }

    private func snapshotRecords(for householdID: UUID) async throws -> [LocalHouseholdRecord] {
        guard let snapshotActor = await backgroundSnapshotActor() else { return [] }
        let startedAt = ContinuousClock.now
        let records = try await Task.detached(priority: .utility) {
            try await snapshotActor.records(for: householdID)
        }.value
        let duration = startedAt.duration(to: .now)
        let assetBytes = records.reduce(into: 0) { $0 += $1.assetBytesRead }
        logger.info("snapshot.complete records=\(records.count, privacy: .public) assetBytes=\(assetBytes, privacy: .public) duration=\(duration, privacy: .public)")
        return records
    }

    private func touchRecords(
        _ changes: [(identity: HouseholdRecordIdentity, changedGroups: Set<String>)],
        householdID: UUID
    ) async throws {
        guard let snapshotActor = await backgroundSnapshotActor() else { return }
        try await Task.detached(priority: .utility) {
            try await snapshotActor.touch(changes, at: .now, householdID: householdID)
        }.value
    }

    private func snapshotsByName() async throws -> [String: LocalHouseholdRecord] {
        guard let household else { return [:] }
        var records = try await snapshotRecords(for: household.uuid)
        for tombstone in metadata.tombstones {
            let identity = HouseholdRecordIdentity(type: .deletionMarker, uuid: tombstone.markerUUID)
            let payload = HouseholdRecordPayload.deletionMarker(.init(
                deletedType: tombstone.deletedType,
                deletedUUID: tombstone.deletedUUID,
                deletedAt: tombstone.deletedAt
            ))
            records.append(.init(identity: identity, householdID: household.uuid, modifiedAt: tombstone.deletedAt, payloadData: try HouseholdRecordCodec.encode(payload)))
        }
        return Self.keyedSnapshots(records)
    }

    /// An old development store can contain duplicate UUID defaults from a
    /// lightweight schema update. The app has no shipped legacy population,
    /// but sync must still degrade safely instead of crashing while the local
    /// developer store is being replaced. Prefer the newest snapshot and use
    /// its stable fingerprint as a deterministic tie-breaker.
    nonisolated static func canonicalSnapshots(_ records: [LocalHouseholdRecord]) -> [LocalHouseholdRecord] {
        let selected = keyedSnapshots(records)
        var seen = Set<String>()
        return records.compactMap { record in
            let name = record.identity.recordName
            guard seen.insert(name).inserted else { return nil }
            return selected[name]
        }
    }

    nonisolated private static func keyedSnapshots(_ records: [LocalHouseholdRecord]) -> [String: LocalHouseholdRecord] {
        records.reduce(into: [:]) { result, record in
            let name = record.identity.recordName
            guard let existing = result[name] else {
                result[name] = record
                return
            }
            if record.modifiedAt > existing.modifiedAt
                || (record.modifiedAt == existing.modifiedAt && record.fingerprint > existing.fingerprint) {
                result[name] = record
            }
        }
    }

    private func identity(fromRecordName name: String) -> HouseholdRecordIdentity? {
        for type in HouseholdRecordType.allCases {
            if let identity = HouseholdRecordIdentity(recordType: type.rawValue, recordName: name) { return identity }
        }
        return nil
    }

    private func priority(_ record: CKRecord) -> Int {
        HouseholdRecordType(rawValue: record.recordType)?.applyPriority ?? .max
    }

    private func deletionPriority(recordType: String) -> Int {
        switch HouseholdRecordType(rawValue: recordType) {
        case .dishIngredient, .dishImage, .cookedLogImage: 0
        case .dish, .cookedLog: 1
        default: 2
        }
    }

    private func recordFingerprint(_ payloadData: Data, assetData: Data?) -> String {
        LocalHouseholdRecord(
            identity: .init(type: .household, uuid: UUID()),
            householdID: UUID(),
            modifiedAt: .now,
            payloadData: payloadData,
            assetData: assetData
        ).fingerprint
    }

    nonisolated static func readAssetData(_ asset: CKAsset?) throws -> Data? {
        guard let asset else { return nil }
        guard let fileURL = asset.fileURL,
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else {
            throw HouseholdRecordSyncError.requiredAssetUnavailable
        }
        return data
    }

    private var activeScope: CollaborationDatabaseScope {
        locator?.isOwner == true ? .private : .shared
    }

    private var collaborationEnvironment: CollaborationEnvironment {
        switch BuildEnvironment.cloudKit {
        case .development: .development
        case .production: .production
        case .unknown: .unknown
        }
    }

    private func accountPartitionIdentifier() async throws -> String {
        let userRecordID = try await container.userRecordID()
        let material = "\(SharedStore.cloudKitContainerID)|\(userRecordID.recordName)"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private var defaults: UserDefaults {
        UserDefaults(suiteName: SharedStore.appGroupID) ?? .standard
    }

    private static var buildIdentifier: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "\(version)(\(build))"
    }

    nonisolated fileprivate static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// CloudKit's Development and Production databases are completely
    /// independent. Their sync tokens, pending changes, record change tags,
    /// and zone state must never share a cache key even when the household's
    /// zone ID is identical. In particular, a Production build installed over
    /// a Development build keeps this App Group UserDefaults suite.
    nonisolated static func storageSuffix(for locator: HouseholdShareLocator, environment: CloudKitEnvironment) -> String {
        Data("\(environment.rawValue)|\(locator.isOwner ? "private" : "shared")|\(locator.zoneName)|\(locator.ownerName)".utf8).base64EncodedString()
    }

    private func storageSuffix(for locator: HouseholdShareLocator) -> String {
        Self.storageSuffix(for: locator, environment: BuildEnvironment.cloudKit)
    }

    private func stateKey(for locator: HouseholdShareLocator) -> String { "HouseholdRecordSync.state.\(storageSuffix(for: locator))" }
    private func legacyMetadataKey(for locator: HouseholdShareLocator) -> String { "HouseholdRecordSync.metadata.\(storageSuffix(for: locator))" }

    private func metadataFileURL(for locator: HouseholdShareLocator) throws -> URL {
        guard let stateStoreAccountPartitionIdentifier else {
            throw HouseholdRecordSyncError.stateStoreUnavailable
        }
        return try metadataFileURL(
            storageSuffix: storageSuffix(for: locator),
            environment: BuildEnvironment.cloudKit.rawValue,
            accountPartitionIdentifier: stateStoreAccountPartitionIdentifier
        )
    }

    private func legacyMetadataFileURL(for locator: HouseholdShareLocator) throws -> URL {
        try legacyMetadataFileURL(storageSuffix: storageSuffix(for: locator), environment: BuildEnvironment.cloudKit.rawValue)
    }

    private func acquireSyncOwnership() throws {
        #if os(macOS)
        guard syncOwnerFD == nil else { return }
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID) else {
            throw HouseholdRecordSyncError.appGroupUnavailable
        }
        let path = root.appending(path: "HouseholdSyncState/sync-owner.lock")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(path.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw HouseholdRecordSyncError.syncLockUnavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw HouseholdRecordSyncError.anotherAppCopyIsSyncing
        }
        syncOwnerFD = fd
        #endif
    }

    private func legacyMetadataFileURL(storageSuffix: String, environment: String) throws -> URL {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID) else {
            throw HouseholdRecordSyncError.appGroupUnavailable
        }
        let directory = root.appending(path: "HouseholdSyncState", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let material = "\(environment)|\(storageSuffix)"
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "metadata-v1-\(digest).json")
    }

    private func metadataFileURL(
        storageSuffix: String,
        environment: String,
        accountPartitionIdentifier: String
    ) throws -> URL {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID) else {
            throw HouseholdRecordSyncError.appGroupUnavailable
        }
        let directory = root.appending(path: "HouseholdSyncState", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let material = "\(environment)|\(accountPartitionIdentifier)|\(storageSuffix)"
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "metadata-v2-\(digest).json")
    }

    private func persistMetadata() async throws {
        guard let locator else { throw HouseholdRecordSyncError.stateStoreUnavailable }
        let url = try metadataFileURL(for: locator)
        let snapshot = metadata
        let startedAt = ContinuousClock.now
        logger.info("state.persist.start")
        // Encoding and verifying the metadata of a large household can take
        // seconds. Keep that work off the UI actor; the writer actor also
        // preserves write order if callbacks arrive while one write is active.
        let byteCount = try await metadataWriter.write(snapshot, to: url)
        defaults.removeObject(forKey: legacyMetadataKey(for: locator))
        let duration = startedAt.duration(to: .now)
        logger.info("state.persist.end bytes=\(byteCount, privacy: .public) duration=\(duration, privacy: .public) fingerprints=\(snapshot.serverFingerprints.count, privacy: .public) pending=\(snapshot.pendingFingerprints.count, privacy: .public) tombstones=\(snapshot.tombstones.count, privacy: .public)")
    }

    nonisolated static func isResolvedConflictSendError(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        if error.code == .serverRecordChanged { return error.serverRecord != nil }
        guard error.code == .partialFailure,
              let failures = error.partialErrorsByItemID?.values,
              !failures.isEmpty else { return false }
        return failures.allSatisfy(isResolvedConflictSendError)
    }

    private static func partialFailureCodes(_ error: Error) -> [Int] {
        guard let error = error as? CKError,
              let failures = error.partialErrorsByItemID?.values else { return [] }
        return failures.map { ($0 as NSError).code }.sorted()
    }

    private func encodeSystemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }
}

enum HouseholdRecordSyncError: LocalizedError {
    case stateStoreUnavailable
    case appGroupUnavailable
    case migrationVerificationFailed(stage: HouseholdSyncMetadataMigrationStage, bytes: Int, sha256: String)
    case metadataCopiesDiverged(
        legacyBytes: Int,
        fileBytes: Int,
        legacyHash: String,
        fileHash: String,
        legacyPending: Int,
        filePending: Int,
        legacyTombstones: Int,
        fileTombstones: Int
    )
    case metadataMissingForPendingJournal(entries: Int)
    case syncLockUnavailable
    case anotherAppCopyIsSyncing
    case requiredAssetUnavailable

    var errorDescription: String? {
        switch self {
        case .anotherAppCopyIsSyncing:
            String(localized: "Another copy of MealPlan is syncing this household. Quit the other copy and reopen MealPlan.")
        case .requiredAssetUnavailable:
            String(localized: "A household image could not be downloaded completely. Your existing household data was kept. Retry the sync before continuing.")
        case .migrationVerificationFailed, .metadataCopiesDiverged, .metadataMissingForPendingJournal:
            String(localized: "MealPlan can’t verify saved iCloud sync information yet. Your household data has not been deleted. Retry or share diagnostics with MealPlan Support.")
        default: nil
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .migrationVerificationFailed, .metadataCopiesDiverged, .metadataMissingForPendingJournal:
            String(localized: "Keep MealPlan installed and retry. If the problem continues, open Household Recovery → Recovery Diagnostics and share the diagnostics with support.")
        default: nil
        }
    }

    var supportDiagnostic: String {
        switch self {
        case .migrationVerificationFailed(let stage, let bytes, let sha256):
            "stage=\(stage.rawValue); bytes=\(bytes); sha256=\(sha256)"
        case .metadataCopiesDiverged(let legacyBytes, let fileBytes, let legacyHash, let fileHash, let legacyPending, let filePending, let legacyTombstones, let fileTombstones):
            "stage=existingFileDivergence; legacyBytes=\(legacyBytes); fileBytes=\(fileBytes); legacySHA256=\(legacyHash); fileSHA256=\(fileHash); legacyPending=\(legacyPending); filePending=\(filePending); legacyTombstones=\(legacyTombstones); fileTombstones=\(fileTombstones)"
        case .metadataMissingForPendingJournal(let entries): "stage=metadataMissingForPendingJournal; journalEntries=\(entries)"
        case .stateStoreUnavailable: "stage=stateStoreUnavailable"
        case .requiredAssetUnavailable: "stage=requiredAssetUnavailable"
        case .appGroupUnavailable: "stage=appGroupUnavailable"
        case .syncLockUnavailable: "stage=syncLockUnavailable"
        case .anotherAppCopyIsSyncing: "stage=anotherAppCopyIsSyncing"
        }
    }
}

actor HouseholdMetadataWriter {
    private let defaults: UserDefaults

    init(suiteName: String = SharedStore.appGroupID) {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    nonisolated static func recoveryDirectory(for activeFileURL: URL) -> URL {
        let namespace = activeFileURL.deletingPathExtension().lastPathComponent
        return activeFileURL.deletingLastPathComponent()
            .appending(path: "Recovery/Metadata/\(namespace)", directoryHint: .isDirectory)
    }

    func load(
        legacyKey: String,
        legacyFileURL: URL,
        activeFileURL: URL,
        journalEntryCount: Int = 0
    ) throws -> HouseholdSyncMetadata {
        if FileManager.default.fileExists(atPath: activeFileURL.path) {
            let data: Data
            do { data = try Data(contentsOf: activeFileURL) }
            catch {
                throw HouseholdRecordSyncError.migrationVerificationFailed(
                    stage: .readExistingFile,
                    bytes: 0,
                    sha256: "unavailable"
                )
            }
            let activeMetadata: HouseholdSyncMetadata
            do { activeMetadata = try JSONDecoder().decode(HouseholdSyncMetadata.self, from: data) }
            catch {
                throw HouseholdRecordSyncError.migrationVerificationFailed(
                    stage: .decodeExistingFile,
                    bytes: data.count,
                    sha256: HouseholdRecordSyncService.digest(data)
                )
            }
            try retireEqualLegacyCopies(
                legacyKey: legacyKey,
                legacyFileURL: legacyFileURL,
                activeFileURL: activeFileURL,
                activeData: data,
                activeMetadata: activeMetadata
            )
            return activeMetadata
        }

        let legacyDefaultsData = defaults.data(forKey: legacyKey)
        let legacyFileData: Data?
        do {
            legacyFileData = FileManager.default.fileExists(atPath: legacyFileURL.path)
                ? try Data(contentsOf: legacyFileURL)
                : nil
        } catch {
            throw HouseholdRecordSyncError.migrationVerificationFailed(
                stage: .readExistingFile,
                bytes: 0,
                sha256: "unavailable"
            )
        }

        switch try HouseholdSyncMetadataMigrationResolution.resolve(legacyData: legacyDefaultsData, fileData: legacyFileData) {
        case .empty:
            guard journalEntryCount == 0 else {
                throw HouseholdRecordSyncError.metadataMissingForPendingJournal(entries: journalEntryCount)
            }
            return .init()
        case .existing(let metadata, let retireLegacy):
            let verified = try stage(metadata, to: activeFileURL)
            if retireLegacy { defaults.removeObject(forKey: legacyKey) }
            return verified
        case .migrate(let metadata, _):
            let verified = try stage(metadata, to: activeFileURL)
            defaults.removeObject(forKey: legacyKey)
            return verified
        }
    }

    func executableSHA256() -> String? {
        guard let executableURL = Bundle.main.executableURL,
              let file = try? FileHandle(forReadingFrom: executableURL)
        else { return nil }
        defer { try? file.close() }
        var hasher = SHA256()
        do {
            while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func stage(_ metadata: HouseholdSyncMetadata, to url: URL) throws -> HouseholdSyncMetadata {
        let data: Data
        do { data = try JSONEncoder().encode(metadata) }
        catch {
            throw HouseholdRecordSyncError.migrationVerificationFailed(stage: .stageWrite, bytes: 0, sha256: "unavailable")
        }
        do { try writeDurably(data, to: url) }
        catch {
            throw HouseholdRecordSyncError.migrationVerificationFailed(
                stage: .stageWrite,
                bytes: data.count,
                sha256: HouseholdRecordSyncService.digest(data)
            )
        }
        let stored: Data
        do { stored = try Data(contentsOf: url) }
        catch {
            throw HouseholdRecordSyncError.migrationVerificationFailed(
                stage: .verifyReadback,
                bytes: data.count,
                sha256: HouseholdRecordSyncService.digest(data)
            )
        }
        let verified: HouseholdSyncMetadata
        do { verified = try JSONDecoder().decode(HouseholdSyncMetadata.self, from: stored) }
        catch {
            throw HouseholdRecordSyncError.migrationVerificationFailed(
                stage: .verifyReadback,
                bytes: stored.count,
                sha256: HouseholdRecordSyncService.digest(stored)
            )
        }
        guard verified == metadata else {
            throw HouseholdRecordSyncError.migrationVerificationFailed(
                stage: .verifyReadback,
                bytes: stored.count,
                sha256: HouseholdRecordSyncService.digest(stored)
            )
        }
        return verified
    }

    private func retireEqualLegacyCopies(
        legacyKey: String,
        legacyFileURL: URL,
        activeFileURL: URL,
        activeData: Data,
        activeMetadata: HouseholdSyncMetadata
    ) throws {
        guard let legacyDefaultsData = defaults.data(forKey: legacyKey) else { return }

        // The active metadata file is the commit point for this namespace.
        // Preserve older or malformed defaults bytes durably before retiring
        // them so a restart can resume without losing the old evidence.
        do { try synchronizeFileAndDirectory(at: activeFileURL) }
        catch {
            throw HouseholdRecordSyncError.migrationVerificationFailed(
                stage: .verifyReadback,
                bytes: activeData.count,
                sha256: HouseholdRecordSyncService.digest(activeData)
            )
        }

        let legacyMetadata = try? JSONDecoder().decode(HouseholdSyncMetadata.self, from: legacyDefaultsData)
        if legacyMetadata != activeMetadata {
            try preserveLegacyMetadata(legacyDefaultsData, activeFileURL: activeFileURL)
        }
        defaults.removeObject(forKey: legacyKey)
    }

    private func writeDurably(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try synchronizeFileAndDirectory(at: url)
    }

    private func synchronizeFileAndDirectory(at url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        try file.synchronize()
        try file.close()

        try synchronizeDirectory(at: url.deletingLastPathComponent())
    }

    private func synchronizeDirectory(at url: URL) throws {
        let directoryFD = open(url.path, O_RDONLY)
        guard directoryFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let result = fsync(directoryFD)
        let syncError = errno
        close(directoryFD)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: syncError) ?? .EIO) }
    }

    private func preserveLegacyMetadata(_ data: Data, activeFileURL: URL) throws {
        let directory = Self.recoveryDirectory(for: activeFileURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let namespaceRoot = activeFileURL.deletingLastPathComponent()
        var parent = directory.deletingLastPathComponent()
        while parent.path != namespaceRoot.path {
            try synchronizeDirectory(at: parent)
            parent.deleteLastPathComponent()
        }
        try synchronizeDirectory(at: namespaceRoot)
        let material = "\(activeFileURL.lastPathComponent)|\(HouseholdRecordSyncService.digest(data))"
        let nameDigest = HouseholdRecordSyncService.digest(Data(material.utf8))
        let recoveryURL = directory.appending(path: "metadata-recovery-v1-\(nameDigest).json")
        if FileManager.default.fileExists(atPath: recoveryURL.path) {
            let existing = try Data(contentsOf: recoveryURL)
            guard existing == data else {
                throw HouseholdRecordSyncError.migrationVerificationFailed(
                    stage: .verifyReadback,
                    bytes: existing.count,
                    sha256: HouseholdRecordSyncService.digest(existing)
                )
            }
            try synchronizeFileAndDirectory(at: recoveryURL)
        } else {
            try writeDurably(data, to: recoveryURL)
        }
    }

    func write(_ metadata: HouseholdSyncMetadata, to url: URL) throws -> Int {
        let data = try JSONEncoder().encode(metadata)
        try writeDurably(data, to: url)
        let stored = try Data(contentsOf: url)
        let verified = try JSONDecoder().decode(HouseholdSyncMetadata.self, from: stored)
        guard stored == data, verified == metadata else {
            throw HouseholdRecordSyncError.migrationVerificationFailed(
                stage: .verifyReadback,
                bytes: stored.count,
                sha256: HouseholdRecordSyncService.digest(stored)
            )
        }
        return data.count
    }
}

private final class HouseholdRecordSyncDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await HouseholdRecordSyncService.shared.handle(event, syncEngine: syncEngine)
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await HouseholdRecordSyncService.shared.nextBatch(context, syncEngine: syncEngine)
    }
}
