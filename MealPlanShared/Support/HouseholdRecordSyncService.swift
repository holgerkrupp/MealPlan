import CloudKit
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

private struct HouseholdSyncTombstone: Codable, Sendable {
    var markerUUID: UUID
    var deletedType: HouseholdRecordType
    var deletedUUID: UUID
    var deletedAt: Date
}

private struct HouseholdSyncMetadata: Codable, Sendable {
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

/// The sole CloudKit transport for the App Group SwiftData store. It scans
/// stable per-record fingerprints after saves, and lets CKSyncEngine own
/// subscriptions, change tokens, retries, and partial failures.
@MainActor
final class HouseholdRecordSyncService {
    static let shared = HouseholdRecordSyncService()

    private let container = CKContainer(identifier: SharedStore.cloudKitContainerID)
    private let delegate = HouseholdRecordSyncDelegate()
    private var engine: CKSyncEngine?
    private var household: Household?
    private var context: ModelContext?
    private var modelContainer: ModelContainer?
    private var snapshotActor: HouseholdSnapshotActor?
    private var locator: HouseholdShareLocator?
    private var metadata = HouseholdSyncMetadata()
    private var saveObserver: NSObjectProtocol?
    private var scheduledScan: Task<Void, Never>?
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
    /// Generation observed after the last local scan. A missing value from an
    /// older app is deliberately treated as dirty once, not as clean.
    private var lastObservedStoreGeneration: UInt64?
    private(set) var lastError: Error?

    /// CKSyncEngine is an Objective-C reference type whose public SDK
    /// annotations vary by OS release. The detached operation boundary is
    /// intentional and all access through this bridge is limited to the
    /// engine's async fetch/send methods.
    private final class CloudEngineBridge: @unchecked Sendable {
        let engine: CKSyncEngine

        init(_ engine: CKSyncEngine) {
            self.engine = engine
        }
    }

    private init() {}

    var isReadOnly: Bool { locator?.isReadOnly == true }

    func synchronize(household: Household, context: ModelContext) async throws {
        try activateIfNeeded(household: household, context: context)
        guard let locator else { return }
        observeExternalStoreGeneration()
        if !locator.isReadOnly, needsLocalScan { try await scanLocalChanges() }
        await performCloudOperation(fetch: true, send: !locator.isReadOnly)
        if let lastError { throw lastError }
    }

    func fetchChanges() async {
        guard locator != nil else { return }
        observeExternalStoreGeneration()
        // A fetch can arrive through launch/bootstrap without the explicit
        // synchronize() path. Capture local edits first so that this fetch
        // cannot make them look acknowledged.
        if locator?.isReadOnly != true, needsLocalScan {
            do { try await scanLocalChanges() }
            catch { lastError = error; return }
        }
        await performCloudOperation(fetch: true, send: false)
    }

    func stop() async {
        scheduledScan?.cancel()
        scheduledScan = nil
        cloudOperationTask?.cancel()
        cloudOperationTask = nil
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        saveObserver = nil
        await engine?.cancelOperations()
        engine = nil
        household = nil
        context = nil
        modelContainer = nil
        snapshotActor = nil
        locator = nil
        pendingSnapshots.removeAll(keepingCapacity: false)
        needsLocalScan = true
        didRestoreTombstoneOperations = false
        lastObservedStoreGeneration = nil
    }

    /// Forgets everything stored for syncing `locator`'s zone. Used once this
    /// device has lost access to a shared household: if it were ever invited
    /// back, the old fingerprints would read as local deletions and queue
    /// deletes for the owner's records.
    func discardState(for locator: HouseholdShareLocator) {
        defaults.removeObject(forKey: stateKey(for: locator))
        defaults.removeObject(forKey: metadataKey(for: locator))
    }

    func record(for id: CKRecord.ID) async throws -> CKRecord? {
        guard id.zoneID == locator?.zoneID else { return nil }
        let snapshot: LocalHouseholdRecord?
        if let pending = pendingSnapshots[id.recordName] {
            snapshot = pending
        } else {
            snapshot = try await snapshotsByName()[id.recordName]
        }
        guard let snapshot else { return nil }
        let systemRecord = metadata.systemFields[id.recordName].flatMap(decodeSystemFields)
        return try HouseholdRecordCodec.makeRecord(from: snapshot, zoneID: id.zoneID, systemRecord: systemRecord)
    }

    func handle(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            switch event {
            case .stateUpdate(let update):
                try storeState(update.stateSerialization)
            case .fetchedRecordZoneChanges(let changes):
                try await applyFetchedChanges(changes)
            case .sentRecordZoneChanges(let changes):
                try await handleSentChanges(changes, engine: syncEngine)
            case .sentDatabaseChanges(let changes):
                if let failure = changes.failedZoneSaves.first { lastError = failure.error }
            case .accountChange:
                metadata = HouseholdSyncMetadata()
                persistMetadata()
            case .fetchedDatabaseChanges, .willFetchChanges, .willFetchRecordZoneChanges,
                 .didFetchRecordZoneChanges, .didFetchChanges, .willSendChanges, .didSendChanges:
                break
            @unknown default:
                break
            }
        } catch {
            lastError = error
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
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            try? await HouseholdRecordSyncService.shared.record(for: id)
        }
    }

    // MARK: - Activation and local change capture

    private func activateIfNeeded(household: Household, context: ModelContext) throws {
        let nextLocator = HouseholdShareLocator.decode(household.cloudKitShareIdentifier) ?? .solo(householdID: household.uuid)
        if self.household?.uuid == household.uuid, locator == nextLocator, engine != nil { return }

        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        scheduledScan?.cancel()
        self.household = household
        self.context = context
        if modelContainer !== context.container {
            snapshotActor = nil
            modelContainer = context.container
        }
        locator = nextLocator
        metadata = loadMetadata(for: nextLocator)
        pendingSnapshots.removeAll(keepingCapacity: false)
        needsLocalScan = true
        didRestoreTombstoneOperations = false
        lastObservedStoreGeneration = nil

        let database = nextLocator.isOwner ? container.privateCloudDatabase : container.sharedCloudDatabase
        let state = loadState(for: nextLocator)
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: state, delegate: delegate)
        // We explicitly serialize operations below. Automatic operations can
        // otherwise race a save-driven `sendChanges` and trip CloudKit's
        // internal overlap assertion.
        configuration.automaticallySync = false
        configuration.subscriptionID = "MealPlan-\(nextLocator.isOwner ? "private" : "shared")"
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        HouseholdSyncDiagnostics.record(event: "activated", locator: nextLocator)
        if nextLocator.isOwner {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: nextLocator.zoneID))])
        }

        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.isApplyingRemoteChanges { HouseholdStoreGeneration.markDirty() }
                self.needsLocalScan = true
                self.scheduleScan()
            }
        }
    }

    /// Detects commits made by the Share Extension or another process using
    /// the App Group store. Only this main-app service reacts by scanning and
    /// sending through CKSyncEngine.
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
        guard !isApplyingRemoteChanges, locator?.isReadOnly != true else { return }
        scheduledScan?.cancel()
        scheduledScan = Task { @MainActor [weak self] in
            // Keep database serialization and photo hashing out of the burst
            // of layout work that normally follows an edit or tab switch.
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            do {
                try await self.scanLocalChanges()
                await self.performCloudOperation(fetch: false, send: true)
            } catch {
                self.lastError = error
            }
        }
    }

    private func scanLocalChanges() async throws {
        guard let household, let engine, let locator, !locator.isReadOnly else { return }
        var snapshots = try await snapshotRecords(for: household.uuid)
        // Photo hashes are deliberately expensive. Calculate every snapshot's
        // fingerprint once per scan and carry it through both passes.
        let initialSnapshots = snapshots
        var evaluated = await Task.detached(priority: .utility) {
            initialSnapshots.map { (snapshot: $0, fingerprint: $0.fingerprint) }
        }.value
        var changesToTouch: [(identity: HouseholdRecordIdentity, changedGroups: Set<String>)] = []

        for item in evaluated where metadata.serverFingerprints[item.snapshot.identity.recordName] != nil
            && metadata.serverFingerprints[item.snapshot.identity.recordName] != item.fingerprint {
            let snapshot = item.snapshot
            let previousGroups = metadata.serverGroupFingerprints[snapshot.identity.recordName] ?? [:]
            let changedGroups = Set(snapshot.groupFingerprints.compactMap { previousGroups[$0.key] == $0.value ? nil : $0.key })
            changesToTouch.append((snapshot.identity, changedGroups))
        }
        if !changesToTouch.isEmpty {
            // Advancing sync clocks can update hundreds of legacy records.
            // Save them through a private SwiftData executor so SQLite never
            // blocks the scrolling main context.
            try await touchRecords(changesToTouch, householdID: household.uuid)
            snapshots = try await snapshotRecords(for: household.uuid)
            let touchedSnapshots = snapshots
            evaluated = await Task.detached(priority: .utility) {
                touchedSnapshots.map { (snapshot: $0, fingerprint: $0.fingerprint) }
            }.value
        }

        let byName = keyedSnapshots(snapshots)
        for item in evaluated {
            let snapshot = item.snapshot
            let name = snapshot.identity.recordName
            let mustQueue = metadata.needsFullUpload
                || metadata.serverFingerprints[name] != item.fingerprint
                || metadata.pendingFingerprints[name] != item.fingerprint
            guard mustQueue else { continue }
            let id = CKRecord.ID(recordName: snapshot.identity.recordName, zoneID: locator.zoneID)
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
            pendingSnapshots[snapshot.identity.recordName] = snapshot
            metadata.pendingFingerprints[name] = item.fingerprint
            metadata.pendingGroupFingerprints[name] = snapshot.groupFingerprints
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
            engine.state.add(pendingRecordZoneChanges: [
                .deleteRecord(CKRecord.ID(recordName: deletedName, zoneID: locator.zoneID)),
                .saveRecord(CKRecord.ID(recordName: HouseholdRecordIdentity(type: .deletionMarker, uuid: tombstone.markerUUID).recordName, zoneID: locator.zoneID))
            ])
        }

        // Tombstones are part of the durable local intent. Restore their
        // operations once per activation to repair the window where the
        // process ended after metadata persistence but before CKSyncEngine
        // persisted its pending state. Do not add them on every scan.
        if !didRestoreTombstoneOperations {
            for tombstone in metadata.tombstones {
                let markerName = HouseholdRecordIdentity(type: .deletionMarker, uuid: tombstone.markerUUID).recordName
                engine.state.add(pendingRecordZoneChanges: [
                    .deleteRecord(CKRecord.ID(recordName: HouseholdRecordIdentity(type: tombstone.deletedType, uuid: tombstone.deletedUUID).recordName, zoneID: locator.zoneID)),
                    .saveRecord(CKRecord.ID(recordName: markerName, zoneID: locator.zoneID))
                ])
            }
            didRestoreTombstoneOperations = true
        }

        metadata.needsFullUpload = false
        persistMetadata()
        needsLocalScan = false
        lastObservedStoreGeneration = HouseholdStoreGeneration.value()
        HouseholdSyncDiagnostics.record(
            event: "scanned",
            locator: locator,
            pendingCount: metadata.pendingFingerprints.count
        )
    }

    /// Runs every explicit engine operation behind the previous one. The
    /// operation itself must cross a detached task boundary: CKSyncEngine
    /// rejects fetch/send calls that inherit a delegate callback's task
    /// lineage, even when the calls are otherwise serialized.
    private func performCloudOperation(fetch: Bool, send: Bool) async {
        let previous = cloudOperationTask
        guard let engine = self.engine, let locator = self.locator else { return }
        let bridge = CloudEngineBridge(engine)
        let zoneID = locator.zoneID
        let maySend = send && !locator.isReadOnly

        let detached = Task.detached(priority: .utility) {
            await previous?.value
            guard !Task.isCancelled else { return nil as Error? }
            var operationError: Error?

            if fetch {
                do {
                    var options = CKSyncEngine.FetchChangesOptions(scope: .zoneIDs([zoneID]))
                    options.prioritizedZoneIDs = [zoneID]
                    try await bridge.engine.fetchChanges(options)
                } catch {
                    operationError = error
                }
            }

            // A first-time owner may not have a server zone to fetch yet. Still
            // run the send so pending zone creation can establish it.
            if maySend {
                do {
                    await Task.yield()
                    try await bridge.engine.sendChanges(.init(scope: .zoneIDs([zoneID])))
                } catch {
                    if operationError == nil { operationError = error }
                }
            }

            return operationError
        }
        let task = Task { @MainActor [weak self] in
            let error = await detached.value
            if let self { self.lastError = error }
        }
        cloudOperationTask = task
        await task.value
    }

    // MARK: - Remote change application

    private func applyFetchedChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) async throws {
        guard let household, let context, let locator else { return }
        isApplyingRemoteChanges = true
        defer { isApplyingRemoteChanges = false }

        var local = keyedSnapshots(try await snapshotRecords(for: household.uuid))
        let modifications = changes.modifications
            .filter { $0.record.recordID.zoneID == locator.zoneID }
            .sorted { priority($0.record) < priority($1.record) }
        let deletions = changes.deletions
            .filter { $0.recordID.zoneID == locator.zoneID }
            .sorted { deletionPriority(recordType: $0.recordType) < deletionPriority(recordType: $1.recordType) }
        let counts = Dictionary(grouping: modifications) { $0.record.recordType }
            .mapValues(\.count)
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: ",")
        SharedStore.logger.debug("Applying household fetch: modifications=\(modifications.count), deletions=\(deletions.count), types=\(counts, privacy: .public)")

        var uploadNames = Set<String>()
        var modifiedNames = Set<String>()
        var removedNames = Set<String>()
        var serverFingerprints: [String: String] = [:]
        var stagedSystemFields: [String: Data] = [:]
        var markerLocalWins: [String: Bool] = [:]

        do {
            try withoutUndoRegistration(in: context) {
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
                            HouseholdRecordApplier.delete(type: marker.deletedType, uuid: marker.deletedUUID, context: context)
                            removedNames.insert(target.recordName)
                        }
                        serverFingerprints[name] = recordFingerprint(payloadData, assetData: nil)
                        continue
                    }

                    let serverAsset = record[HouseholdRecordCodec.assetKey] as? CKAsset
                    let serverAssetData = serverAsset?.fileURL.flatMap { try? Data(contentsOf: $0) }
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
                    serverFingerprints[name] = recordFingerprint(payloadData, assetData: serverAssetData)
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
                    HouseholdRecordApplier.delete(type: identity.type, uuid: identity.uuid, context: context)
                    removedNames.insert(name)
                    serverFingerprints.removeValue(forKey: name)
                    stagedSystemFields.removeValue(forKey: name)
                }

                try context.save()
            }
        } catch {
            // Do not leave partially-applied relationship mutations in the
            // main context after a failed fetched batch.
            context.rollback()
            needsLocalScan = true
            throw error
        }

        local = keyedSnapshots(try await snapshotRecords(for: household.uuid))
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
            pendingSnapshots.removeValue(forKey: name)
        }
        if !locator.isReadOnly {
            for name in uploadNames {
                guard let snapshot = local[name] else { continue }
                let id = CKRecord.ID(recordName: name, zoneID: locator.zoneID)
                engine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                pendingSnapshots[name] = snapshot
                metadata.pendingFingerprints[name] = snapshot.fingerprint
                metadata.pendingGroupFingerprints[name] = snapshot.groupFingerprints
            }
        }
        for (name, fields) in stagedSystemFields {
            metadata.systemFields[name] = fields
        }
        persistMetadata()
        lastError = nil
        HouseholdSyncDiagnostics.record(
            event: "fetched",
            locator: locator,
            pendingCount: metadata.pendingFingerprints.count
        )
        NotificationCenter.default.post(name: .mealPlanDataDidChange, object: nil)
    }

    private func handleSentChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) async throws {
        var didFail = false
        for record in changes.savedRecords {
            metadata.systemFields[record.recordID.recordName] = encodeSystemFields(record)
            if let pending = metadata.pendingFingerprints.removeValue(forKey: record.recordID.recordName) {
                metadata.serverFingerprints[record.recordID.recordName] = pending
                metadata.serverGroupFingerprints[record.recordID.recordName] = metadata.pendingGroupFingerprints.removeValue(forKey: record.recordID.recordName)
            } else if let payloadData = record[HouseholdRecordCodec.payloadKey] as? Data {
                metadata.serverFingerprints[record.recordID.recordName] = recordFingerprint(
                    payloadData,
                    assetData: (record[HouseholdRecordCodec.assetKey] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
                )
            }
            pendingSnapshots.removeValue(forKey: record.recordID.recordName)
        }
        for failure in changes.failedRecordSaves {
            if failure.error.code == .serverRecordChanged, let server = failure.error.serverRecord {
                try await applyServerConflict(server, engine: engine)
            } else {
                didFail = true
                lastError = failure.error
            }
        }
        if let failure = changes.failedRecordDeletes.values.first {
            didFail = true
            lastError = failure
            needsLocalScan = true
        }
        if !didFail { lastError = nil }
        persistMetadata()
        if let locator {
            HouseholdSyncDiagnostics.record(
                event: didFail ? "sendFailed" : "sent",
                locator: locator,
                pendingCount: metadata.pendingFingerprints.count
            )
        }
    }

    private func applyServerConflict(_ server: CKRecord, engine: CKSyncEngine) async throws {
        guard let household, let context,
              let identity = HouseholdRecordIdentity(recordType: server.recordType, recordName: server.recordID.recordName) else { return }
        let local: LocalHouseholdRecord?
        if let pending = pendingSnapshots[identity.recordName] {
            local = pending
        } else {
            local = try await snapshotRecords(for: household.uuid).first { $0.identity == identity }
        }
        let serverAsset = server[HouseholdRecordCodec.assetKey] as? CKAsset
        let serverAssetData = serverAsset?.fileURL.flatMap { try? Data(contentsOf: $0) }
        let resolution = try HouseholdRecordConflictResolver.resolve(
            local: local,
            server: server,
            serverAssetData: serverAssetData,
            serverHasAsset: serverAsset != nil
        )
        do {
            try withoutUndoRegistration(in: context) {
                try HouseholdRecordApplier.apply(payloadData: resolution.payloadData, identity: identity, modifiedAt: resolution.modifiedAt, assetData: resolution.assetData, household: household, context: context)
                try context.save()
            }
        } catch {
            context.rollback()
            throw error
        }
        metadata.systemFields[identity.recordName] = encodeSystemFields(server)
        metadata.serverFingerprints[identity.recordName] = recordFingerprint(
            server[HouseholdRecordCodec.payloadKey] as? Data ?? Data(),
            assetData: (server[HouseholdRecordCodec.assetKey] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
        )
        if resolution.shouldUpload {
            let snapshot = try await snapshotRecords(for: household.uuid).first { $0.identity == identity }
            if let snapshot {
                pendingSnapshots[identity.recordName] = snapshot
                metadata.pendingFingerprints[identity.recordName] = snapshot.fingerprint
                metadata.pendingGroupFingerprints[identity.recordName] = snapshot.groupFingerprints
            }
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
        } else {
            metadata.pendingFingerprints.removeValue(forKey: identity.recordName)
            metadata.pendingGroupFingerprints.removeValue(forKey: identity.recordName)
        }
    }

    // MARK: - Persistence and snapshots

    private func snapshotRecords(for householdID: UUID) async throws -> [LocalHouseholdRecord] {
        guard let modelContainer else { return [] }
        if snapshotActor == nil {
            snapshotActor = HouseholdSnapshotActor(modelContainer: modelContainer)
        }
        guard let snapshotActor else { return [] }
        return try await snapshotActor.records(for: householdID)
    }

    private func touchRecords(
        _ changes: [(identity: HouseholdRecordIdentity, changedGroups: Set<String>)],
        householdID: UUID
    ) async throws {
        guard let modelContainer else { return }
        if snapshotActor == nil {
            snapshotActor = HouseholdSnapshotActor(modelContainer: modelContainer)
        }
        guard let snapshotActor else { return }
        try await snapshotActor.touch(changes, at: .now, householdID: householdID)
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
        return keyedSnapshots(records)
    }

    /// An old development store can contain duplicate UUID defaults from a
    /// lightweight schema update. The app has no shipped legacy population,
    /// but sync must still degrade safely instead of crashing while the local
    /// developer store is being replaced. Prefer the newest snapshot and use
    /// its stable fingerprint as a deterministic tie-breaker.
    private func keyedSnapshots(_ records: [LocalHouseholdRecord]) -> [String: LocalHouseholdRecord] {
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

    private var defaults: UserDefaults {
        UserDefaults(suiteName: SharedStore.appGroupID) ?? .standard
    }

    /// CloudKit's Development and Production databases are completely
    /// independent. Their sync tokens, pending changes, record change tags,
    /// and zone state must never share a cache key even when the household's
    /// zone ID is identical. In particular, a Production build installed over
    /// a Development build keeps this App Group UserDefaults suite.
    static func storageSuffix(for locator: HouseholdShareLocator, environment: CloudKitEnvironment) -> String {
        Data("\(environment.rawValue)|\(locator.isOwner ? "private" : "shared")|\(locator.zoneName)|\(locator.ownerName)".utf8).base64EncodedString()
    }

    private func storageSuffix(for locator: HouseholdShareLocator) -> String {
        Self.storageSuffix(for: locator, environment: BuildEnvironment.cloudKit)
    }

    private func stateKey(for locator: HouseholdShareLocator) -> String { "HouseholdRecordSync.state.\(storageSuffix(for: locator))" }
    private func metadataKey(for locator: HouseholdShareLocator) -> String { "HouseholdRecordSync.metadata.\(storageSuffix(for: locator))" }

    private func loadState(for locator: HouseholdShareLocator) -> CKSyncEngine.State.Serialization? {
        guard let data = defaults.data(forKey: stateKey(for: locator)) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func storeState(_ state: CKSyncEngine.State.Serialization) throws {
        guard let locator else { return }
        defaults.set(try JSONEncoder().encode(state), forKey: stateKey(for: locator))
    }

    private func loadMetadata(for locator: HouseholdShareLocator) -> HouseholdSyncMetadata {
        guard let data = defaults.data(forKey: metadataKey(for: locator)) else { return .init() }
        return (try? JSONDecoder().decode(HouseholdSyncMetadata.self, from: data)) ?? .init()
    }

    private func persistMetadata() {
        guard let locator, let data = try? JSONEncoder().encode(metadata) else { return }
        defaults.set(data, forKey: metadataKey(for: locator))
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

private final class HouseholdRecordSyncDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await HouseholdRecordSyncService.shared.handle(event, syncEngine: syncEngine)
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await HouseholdRecordSyncService.shared.nextBatch(context, syncEngine: syncEngine)
    }
}
