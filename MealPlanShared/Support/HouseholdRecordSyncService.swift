import CloudKit
import Foundation
import SwiftData

struct HouseholdShareLocator: Codable, Equatable, Sendable {
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
            zoneName: "MealPlanHousehold-\(householdID.uuidString)",
            ownerName: CKCurrentUserDefaultName,
            shareRecordName: nil,
            isOwner: true,
            isReadOnly: false
        )
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
    var fingerprints: [String: String] = [:]
    var groupFingerprints: [String: [String: String]] = [:]
    var systemFields: [String: Data] = [:]
    var tombstones: [HouseholdSyncTombstone] = []
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
    private var locator: HouseholdShareLocator?
    private var metadata = HouseholdSyncMetadata()
    private var saveObserver: NSObjectProtocol?
    private var scheduledScan: Task<Void, Never>?
    /// CKSyncEngine traps when explicit fetch/send operations overlap. Keep a
    /// single ordered chain for launch sync, save-driven sends, and pushes.
    private var cloudOperationTask: Task<Void, Never>?
    private var needsLocalScan = true
    private var isApplyingRemoteChanges = false
    private(set) var lastError: Error?

    private init() {}

    var isReadOnly: Bool { locator?.isReadOnly == true }

    func synchronize(household: Household, context: ModelContext) async throws {
        try activateIfNeeded(household: household, context: context)
        guard let locator else { return }
        if !locator.isReadOnly, needsLocalScan { try scanLocalChanges() }
        await performCloudOperation(fetch: true, send: !locator.isReadOnly)
        if let lastError { throw lastError }
    }

    func fetchChanges() async {
        guard locator != nil else { return }
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
        locator = nil
        needsLocalScan = true
    }

    func record(for id: CKRecord.ID) throws -> CKRecord? {
        guard id.zoneID == locator?.zoneID else { return nil }
        guard let snapshot = try snapshotsByName()[id.recordName] else { return nil }
        let systemRecord = metadata.systemFields[id.recordName].flatMap(decodeSystemFields)
        return try HouseholdRecordCodec.makeRecord(from: snapshot, zoneID: id.zoneID, systemRecord: systemRecord)
    }

    func handle(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            switch event {
            case .stateUpdate(let update):
                try storeState(update.stateSerialization)
            case .fetchedRecordZoneChanges(let changes):
                try applyFetchedChanges(changes)
            case .sentRecordZoneChanges(let changes):
                try handleSentChanges(changes, engine: syncEngine)
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
        locator = nextLocator
        metadata = loadMetadata(for: nextLocator)
        needsLocalScan = true

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
        if nextLocator.isOwner {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: nextLocator.zoneID))])
        }

        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.needsLocalScan = true
                self?.scheduleScan()
            }
        }
    }

    private func scheduleScan() {
        guard !isApplyingRemoteChanges, locator?.isReadOnly != true else { return }
        scheduledScan?.cancel()
        scheduledScan = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self else { return }
            do {
                try self.scanLocalChanges()
                await self.performCloudOperation(fetch: false, send: true)
            } catch {
                self.lastError = error
            }
        }
    }

    private func scanLocalChanges() throws {
        guard let household, let context, let engine, let locator, !locator.isReadOnly else { return }
        var snapshots = try HouseholdRecordCodec.records(for: household, context: context)
        var didTouch = false

        for snapshot in snapshots where metadata.fingerprints[snapshot.identity.recordName] != nil && metadata.fingerprints[snapshot.identity.recordName] != snapshot.fingerprint {
            let previousGroups = metadata.groupFingerprints[snapshot.identity.recordName] ?? [:]
            let changedGroups = Set(snapshot.groupFingerprints.compactMap { previousGroups[$0.key] == $0.value ? nil : $0.key })
            HouseholdRecordApplier.touch(snapshot.identity, at: .now, changedGroups: changedGroups, context: context)
            didTouch = true
        }
        if didTouch {
            isApplyingRemoteChanges = true
            try context.save()
            isApplyingRemoteChanges = false
            snapshots = try HouseholdRecordCodec.records(for: household, context: context)
        }

        let byName = keyedSnapshots(snapshots)
        for snapshot in snapshots where metadata.fingerprints[snapshot.identity.recordName] != snapshot.fingerprint {
            let id = CKRecord.ID(recordName: snapshot.identity.recordName, zoneID: locator.zoneID)
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
            metadata.fingerprints[snapshot.identity.recordName] = snapshot.fingerprint
            metadata.groupFingerprints[snapshot.identity.recordName] = snapshot.groupFingerprints
        }

        let liveNames = Set(byName.keys)
        let previouslyKnown = Set(metadata.fingerprints.keys).subtracting(metadata.tombstones.map { HouseholdRecordIdentity(type: .deletionMarker, uuid: $0.markerUUID).recordName })
        for deletedName in previouslyKnown.subtracting(liveNames) {
            guard let identity = identity(fromRecordName: deletedName), identity.type != .deletionMarker else { continue }
            let tombstone = HouseholdSyncTombstone(markerUUID: UUID(), deletedType: identity.type, deletedUUID: identity.uuid, deletedAt: .now)
            metadata.tombstones.append(tombstone)
            metadata.fingerprints.removeValue(forKey: deletedName)
            metadata.groupFingerprints.removeValue(forKey: deletedName)
            engine.state.add(pendingRecordZoneChanges: [
                .deleteRecord(CKRecord.ID(recordName: deletedName, zoneID: locator.zoneID)),
                .saveRecord(CKRecord.ID(recordName: HouseholdRecordIdentity(type: .deletionMarker, uuid: tombstone.markerUUID).recordName, zoneID: locator.zoneID))
            ])
        }

        persistMetadata()
        needsLocalScan = false
    }

    /// Runs every explicit engine operation behind the previous one. A task
    /// chain is enough here: the service is MainActor-isolated and completed
    /// tasks release their captured predecessor, so the chain stays bounded.
    private func performCloudOperation(fetch: Bool, send: Bool) async {
        let previous = cloudOperationTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self, let engine = self.engine, let locator = self.locator else { return }
            var operationError: Error?

            if fetch {
                do {
                    var options = CKSyncEngine.FetchChangesOptions(scope: .zoneIDs([locator.zoneID]))
                    options.prioritizedZoneIDs = [locator.zoneID]
                    try await engine.fetchChanges(options)
                } catch {
                    operationError = error
                }
            }

            // A first-time owner may not have a server zone to fetch yet. Still
            // run the send so pending zone creation can establish it.
            if send, !locator.isReadOnly {
                do {
                    try await engine.sendChanges(.init(scope: .zoneIDs([locator.zoneID])))
                } catch {
                    operationError = error
                }
            }

            self.lastError = operationError
        }
        cloudOperationTask = task
        await task.value
    }

    // MARK: - Remote change application

    private func applyFetchedChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) throws {
        guard let household, let context, let locator else { return }
        isApplyingRemoteChanges = true
        defer { isApplyingRemoteChanges = false }

        var local = keyedSnapshots(try HouseholdRecordCodec.records(for: household, context: context))
        for modification in changes.modifications.sorted(by: { priority($0.record) < priority($1.record) }) {
            let record = modification.record
            guard record.recordID.zoneID == locator.zoneID,
                  let identity = HouseholdRecordIdentity(recordType: record.recordType, recordName: record.recordID.recordName),
                  let payloadData = record[HouseholdRecordCodec.payloadKey] as? Data else { continue }

            metadata.systemFields[identity.recordName] = encodeSystemFields(record)
            if identity.type == .deletionMarker {
                if case .deletionMarker(let marker) = try HouseholdRecordCodec.decode(payloadData) {
                    HouseholdRecordApplier.delete(type: marker.deletedType, uuid: marker.deletedUUID, context: context)
                }
                metadata.fingerprints[identity.recordName] = fingerprint(payloadData)
                continue
            }

            let resolution = try HouseholdRecordConflictResolver.resolve(local: local[identity.recordName], server: record)
            let assetData = (record[HouseholdRecordCodec.assetKey] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
            try HouseholdRecordApplier.apply(
                payloadData: resolution.payloadData,
                identity: identity,
                modifiedAt: resolution.modifiedAt,
                assetData: assetData,
                household: household,
                context: context
            )
            if resolution.shouldUpload, !locator.isReadOnly {
                engine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            }
        }
        for deletion in changes.deletions where deletion.recordID.zoneID == locator.zoneID {
            if let identity = HouseholdRecordIdentity(recordType: deletion.recordType, recordName: deletion.recordID.recordName) {
                HouseholdRecordApplier.delete(type: identity.type, uuid: identity.uuid, context: context)
                metadata.fingerprints.removeValue(forKey: identity.recordName)
                metadata.groupFingerprints.removeValue(forKey: identity.recordName)
                metadata.systemFields.removeValue(forKey: identity.recordName)
            }
        }
        try context.save()
        local = keyedSnapshots(try HouseholdRecordCodec.records(for: household, context: context))
        for snapshot in local.values {
            metadata.fingerprints[snapshot.identity.recordName] = snapshot.fingerprint
            metadata.groupFingerprints[snapshot.identity.recordName] = snapshot.groupFingerprints
        }
        persistMetadata()
        lastError = nil
        NotificationCenter.default.post(name: .mealPlanDataDidChange, object: nil)
    }

    private func handleSentChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) throws {
        var didFail = false
        for record in changes.savedRecords {
            metadata.systemFields[record.recordID.recordName] = encodeSystemFields(record)
        }
        for failure in changes.failedRecordSaves {
            if failure.error.code == .serverRecordChanged, let server = failure.error.serverRecord {
                try applyServerConflict(server, engine: engine)
            } else {
                didFail = true
                lastError = failure.error
            }
        }
        if let failure = changes.failedRecordDeletes.values.first {
            didFail = true
            lastError = failure
        }
        if !didFail { lastError = nil }
        persistMetadata()
    }

    private func applyServerConflict(_ server: CKRecord, engine: CKSyncEngine) throws {
        guard let household, let context,
              let identity = HouseholdRecordIdentity(recordType: server.recordType, recordName: server.recordID.recordName) else { return }
        let local = try HouseholdRecordCodec.records(for: household, context: context).first { $0.identity == identity }
        let resolution = try HouseholdRecordConflictResolver.resolve(local: local, server: server)
        let assetData = (server[HouseholdRecordCodec.assetKey] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
        try HouseholdRecordApplier.apply(payloadData: resolution.payloadData, identity: identity, modifiedAt: resolution.modifiedAt, assetData: assetData, household: household, context: context)
        try context.save()
        metadata.systemFields[identity.recordName] = encodeSystemFields(server)
        if resolution.shouldUpload { engine.state.add(pendingRecordZoneChanges: [.saveRecord(server.recordID)]) }
    }

    // MARK: - Persistence and snapshots

    private func snapshotsByName() throws -> [String: LocalHouseholdRecord] {
        guard let household, let context else { return [:] }
        var records = try HouseholdRecordCodec.records(for: household, context: context)
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

    private func fingerprint(_ data: Data) -> String {
        data.base64EncodedString()
    }

    private var defaults: UserDefaults {
        UserDefaults(suiteName: SharedStore.appGroupID) ?? .standard
    }

    private func storageSuffix(for locator: HouseholdShareLocator) -> String {
        Data("\(locator.isOwner ? "private" : "shared")|\(locator.zoneName)|\(locator.ownerName)".utf8).base64EncodedString()
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
