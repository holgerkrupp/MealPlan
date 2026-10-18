import CloudKit
import CollaborationCore
import CollaborationCloudKit
import Foundation
import OSLog
import CryptoKit

/// Durable adapter between MealPlan's existing record snapshots and the
/// package-owned CKSyncEngine pool. The journal stores the exact fields being
/// sent, while image assets remain in the App Group's existing asset files.
actor MealPlanCloudKitStateStore: CloudKitSyncEngineStateStore {
    nonisolated let containerIdentifier: String
    nonisolated let environment: CollaborationEnvironment
    nonisolated let accountPartitionIdentifier: String

    private struct Journal: Codable {
        var entries: [String: ArchivedChange] = [:]
        var historyCursor: Data?
    }

    struct ArchivedChange: Codable {
        enum Operation: String, Codable { case save, delete }
        var operation: Operation
        var recordName: String
        var recordType: String?
        var zoneName: String
        var zoneOwnerName: String
        var fields: [String: Field]
        var systemFields: Data?
    }

    enum Field: Codable {
        case string(String)
        case data(Data)
        case date(Date)
        case number(Double, isInteger: Bool)
        case asset(URL)
    }

    private let defaults: UserDefaults
    private let fileManager = FileManager.default
    private var activeLocator: HouseholdShareLocator
    private let logger = Logger(subsystem: "de.holgerkrupp.mealplan", category: "collaboration-state")

    init(
        containerIdentifier: String,
        environment: CollaborationEnvironment,
        accountPartitionIdentifier: String,
        activeLocator: HouseholdShareLocator
    ) {
        self.containerIdentifier = containerIdentifier
        self.environment = environment
        self.accountPartitionIdentifier = accountPartitionIdentifier
        self.activeLocator = activeLocator
        self.defaults = UserDefaults(suiteName: SharedStore.appGroupID) ?? .standard
    }

    func setActiveLocator(_ locator: HouseholdShareLocator) {
        activeLocator = locator
    }

    /// Complete any defaults-to-file migration before the sync engine can
    /// make unrelated App Group preference writes.
    func prepareStorage() throws {
        _ = try loadJournal(for: .private)
        _ = try loadJournal(for: .shared)
        for scope in [CollaborationDatabaseScope.private, .shared] {
            let url = try fileURL(kind: "state", scope: scope)
            if fileManager.fileExists(atPath: url.path) {
                defaults.removeObject(forKey: stateKey(for: scope))
            } else if let data = defaults.data(forKey: stateKey(for: scope)) {
                try writeVerified(data, to: url)
                defaults.removeObject(forKey: stateKey(for: scope))
            }
        }
        // The legacy engine used a zone-scoped key. It belongs only to the
        // active private/shared database, so never copy it across scopes.
        _ = try migrateLegacyStateForActiveScope()
    }

    private func migrateLegacyStateForActiveScope() throws -> Bool {
        // This synchronous helper shares the same verified migration path as
        // loadState without introducing an async boundary into preparation.
        guard let data = defaults.data(forKey: legacyStateKey) else { return false }
        let url = try fileURL(kind: "state", scope: activeScope)
        if fileManager.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == data else { return false }
        } else {
            try writeVerified(data, to: url)
        }
        defaults.removeObject(forKey: legacyStateKey)
        logger.info("Migrated legacy household engine state (bytes=\(data.count, privacy: .public), scope=\(self.activeScope.rawValue, privacy: .public)).")
        return true
    }

    func loadState(for scope: CollaborationDatabaseScope) async throws -> Data? {
        let url = try fileURL(kind: "state", scope: scope)
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            defaults.removeObject(forKey: stateKey(for: scope))
            if scope == activeScope { defaults.removeObject(forKey: legacyStateKey) }
            return data
        }

        let legacy: (String, Data)?
        if let data = defaults.data(forKey: stateKey(for: scope)) {
            legacy = (stateKey(for: scope), data)
        } else if scope == activeScope, let data = defaults.data(forKey: legacyStateKey) {
            // The old engine serialized one state per household zone. Reuse
            // it for the matching database on first package use.
            legacy = (legacyStateKey, data)
        } else {
            legacy = nil
        }
        guard let (legacyKey, data) = legacy else { return nil }
        try writeVerified(data, to: url)
        defaults.removeObject(forKey: legacyKey)
        logger.info("Migrated CloudKit engine state to file storage (bytes=\(data.count, privacy: .public), scope=\(scope.rawValue, privacy: .public)).")
        return data
    }

    func saveState(_ data: Data, for scope: CollaborationDatabaseScope) async throws {
        try writeVerified(data, to: fileURL(kind: "state", scope: scope))
        // Remove legacy copies only after the new durable copy is verified.
        defaults.removeObject(forKey: stateKey(for: scope))
        if scope == activeScope { defaults.removeObject(forKey: legacyStateKey) }
        logger.info("Persisted CloudKit engine state (bytes=\(data.count, privacy: .public), scope=\(scope.rawValue, privacy: .public)).")
    }

    func reportStatePersistenceFailure(_ failure: CollaborationFailure, for scope: CollaborationDatabaseScope) async {
        logger.error("Could not persist \(scope.rawValue, privacy: .public) CloudKit engine state (\(failure.rawValue, privacy: .public)).")
    }

    func stageLocalChanges(
        _ changes: [CloudKitRecordChange],
        advancingTo historyCursor: Data?,
        in scope: CollaborationDatabaseScope
    ) async throws {
        var journal = try loadJournal(for: scope)
        for change in changes {
            let archived: ArchivedChange
            switch change {
            case .save(let record): archived = try ArchivedChange(record: record)
            case .delete(let recordID): archived = ArchivedChange(recordID: recordID)
            }
            journal.entries[Self.entryKey(recordName: archived.recordName, zoneName: archived.zoneName, ownerName: archived.zoneOwnerName)] = archived
        }
        if let historyCursor { journal.historyCursor = historyCursor }
        try saveJournal(journal, for: scope)
    }

    func pendingLocalChanges(in scope: CollaborationDatabaseScope) async throws -> [CloudKitRecordChange] {
        try loadJournal(for: scope).entries.values
            .sorted { $0.recordName < $1.recordName }
            .map(\.cloudKitChange)
    }

    func acknowledgeSentChanges(
        savedRecords: [CKRecord],
        deletedRecordIDs: [CKRecord.ID],
        in scope: CollaborationDatabaseScope
    ) throws {
        var journal = try loadJournal(for: scope)
        for record in savedRecords {
            let key = Self.entryKey(
                recordName: record.recordID.recordName,
                zoneName: record.recordID.zoneID.zoneName,
                ownerName: record.recordID.zoneID.ownerName
            )
            if journal.entries[key]?.matchesSavedRecord(record) == true {
                journal.entries.removeValue(forKey: key)
            }
        }
        for recordID in deletedRecordIDs {
            let key = Self.entryKey(
                recordName: recordID.recordName,
                zoneName: recordID.zoneID.zoneName,
                ownerName: recordID.zoneID.ownerName
            )
            if journal.entries[key]?.operation == .delete {
                journal.entries.removeValue(forKey: key)
            }
        }
        try saveJournal(journal, for: scope)
    }

    func discardDatabaseState(for scope: CollaborationDatabaseScope) throws {
        let stateURL = try fileURL(kind: "state", scope: scope)
        let journalURL = try fileURL(kind: "journal", scope: scope)
        if fileManager.fileExists(atPath: stateURL.path) { try fileManager.removeItem(at: stateURL) }
        if fileManager.fileExists(atPath: journalURL.path) { try fileManager.removeItem(at: journalURL) }
        defaults.removeObject(forKey: stateKey(for: scope))
        defaults.removeObject(forKey: journalKey(for: scope))
        if scope == activeScope { defaults.removeObject(forKey: legacyStateKey) }
    }

    private var activeScope: CollaborationDatabaseScope {
        activeLocator.isOwner ? .private : .shared
    }

    private var legacyStateKey: String {
        let environmentValue: CloudKitEnvironment = switch environment {
        case .development: .development
        case .production: .production
        case .unknown: .unknown
        }
        return "HouseholdRecordSync.state.\(HouseholdRecordSyncService.storageSuffix(for: activeLocator, environment: environmentValue))"
    }

    private func stateKey(for scope: CollaborationDatabaseScope) -> String {
        "HouseholdRecordSync.package.state.\(environment.rawValue).\(accountPartitionIdentifier).\(scope.rawValue)"
    }

    private func journalKey(for scope: CollaborationDatabaseScope) -> String {
        "HouseholdRecordSync.package.journal.\(environment.rawValue).\(accountPartitionIdentifier).\(scope.rawValue)"
    }

    private func loadJournal(for scope: CollaborationDatabaseScope) throws -> Journal {
        let url = try fileURL(kind: "journal", scope: scope)
        if fileManager.fileExists(atPath: url.path) {
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
            defaults.removeObject(forKey: journalKey(for: scope))
            return journal
        }
        guard let data = defaults.data(forKey: journalKey(for: scope)) else { return Journal() }
        // A corrupt old journal may contain the only copy of unsent changes.
        // Keep it in defaults and fail closed until it can be recovered.
        let journal = try JSONDecoder().decode(Journal.self, from: data)
        try writeVerified(data, to: url)
        defaults.removeObject(forKey: journalKey(for: scope))
        logger.info("Migrated household change journal to file storage (bytes=\(data.count, privacy: .public), entries=\(journal.entries.count, privacy: .public), scope=\(scope.rawValue, privacy: .public)).")
        return journal
    }

    private func saveJournal(_ journal: Journal, for scope: CollaborationDatabaseScope) throws {
        let data = try JSONEncoder().encode(journal)
        try writeVerified(data, to: fileURL(kind: "journal", scope: scope))
        defaults.removeObject(forKey: journalKey(for: scope))
        logger.info("Persisted household change journal (bytes=\(data.count, privacy: .public), entries=\(journal.entries.count, privacy: .public), scope=\(scope.rawValue, privacy: .public)).")
    }

    private func fileURL(kind: String, scope: CollaborationDatabaseScope) throws -> URL {
        guard let root = fileManager.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID) else {
            throw MealPlanCloudKitStateStoreError.appGroupUnavailable
        }
        let material = "\(environment.rawValue)|\(accountPartitionIdentifier)|\(scope.rawValue)"
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = root.appending(path: "HouseholdSyncState", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileExtension = kind == "state" ? "bin" : "json"
        return directory.appending(path: "\(kind)-v1-\(digest).\(fileExtension)")
    }

    private func writeVerified(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let stored = try Data(contentsOf: url)
        guard stored == data else { throw MealPlanCloudKitStateStoreError.verificationFailed }
    }

    private static func entryKey(recordName: String, zoneName: String, ownerName: String) -> String {
        "\(ownerName)|\(zoneName)|\(recordName)"
    }
}

extension MealPlanCloudKitStateStore.ArchivedChange {
    /// A record with the same ID can be restaged while an older version is in
    /// flight. Keep the newer journal entry until those exact bytes are saved.
    func matchesSavedRecord(_ record: CKRecord) -> Bool {
        guard operation == .save, recordType == record.recordType,
              case .data(let pendingPayload)? = fields[HouseholdRecordCodec.payloadKey],
              let savedPayload = record[HouseholdRecordCodec.payloadKey] as? Data,
              pendingPayload == savedPayload,
              case .date(let pendingDate)? = fields[HouseholdRecordCodec.modifiedAtKey],
              let savedDate = record[HouseholdRecordCodec.modifiedAtKey] as? Date,
              // CloudKit may round a date field when returning the saved row.
              abs(pendingDate.timeIntervalSinceReferenceDate - savedDate.timeIntervalSinceReferenceDate) < 0.01
        else { return false }

        let pendingAssetURL: URL?
        if case .asset(let url)? = fields[HouseholdRecordCodec.assetKey] {
            pendingAssetURL = url
        } else {
            pendingAssetURL = nil
        }
        let savedAssetURL = (record[HouseholdRecordCodec.assetKey] as? CKAsset)?.fileURL
        if pendingAssetURL == nil && savedAssetURL == nil { return true }
        guard let pendingAssetURL, let savedAssetURL,
              let pendingData = try? Data(contentsOf: pendingAssetURL),
              let savedData = try? Data(contentsOf: savedAssetURL) else { return false }
        return pendingData == savedData
    }

    init(recordID: CKRecord.ID) {
        self.init(
            operation: .delete,
            recordName: recordID.recordName,
            recordType: nil,
            zoneName: recordID.zoneID.zoneName,
            zoneOwnerName: recordID.zoneID.ownerName,
            fields: [:],
            systemFields: nil
        )
    }

    init(record: CKRecord) throws {
        var archivedFields: [String: MealPlanCloudKitStateStore.Field] = [:]
        for key in record.allKeys() {
            guard let value = record[key] else { continue }
            if let value = value as? String {
                archivedFields[key] = .string(value)
            } else if let value = value as? Data {
                archivedFields[key] = .data(value)
            } else if let value = value as? Date {
                archivedFields[key] = .date(value)
            } else if let value = value as? CKAsset, let fileURL = value.fileURL {
                archivedFields[key] = .asset(fileURL)
            } else if let value = value as? NSNumber {
                let type = String(cString: value.objCType)
                archivedFields[key] = .number(value.doubleValue, isInteger: !["f", "d"].contains(type))
            } else {
                throw MealPlanCloudKitStateStoreError.unsupportedRecordField(key)
            }
        }

        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        self.init(
            operation: .save,
            recordName: record.recordID.recordName,
            recordType: record.recordType,
            zoneName: record.recordID.zoneID.zoneName,
            zoneOwnerName: record.recordID.zoneID.ownerName,
            fields: archivedFields,
            systemFields: archiver.encodedData
        )
    }

    var cloudKitChange: CloudKitRecordChange {
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        guard operation == .save, let recordType else { return .delete(recordID) }

        let systemRecord = systemFields.flatMap { data -> CKRecord? in
            guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
            defer { unarchiver.finishDecoding() }
            return CKRecord(coder: unarchiver)
        }
        let record = systemRecord ?? CKRecord(recordType: recordType, recordID: recordID)
        for (key, field) in fields {
            switch field {
            case .string(let value): record[key] = value as CKRecordValue
            case .data(let value): record[key] = value as CKRecordValue
            case .date(let value): record[key] = value as CKRecordValue
            case .number(let value, let isInteger):
                record[key] = (isInteger ? NSNumber(value: Int64(value)) : NSNumber(value: value)) as CKRecordValue
            case .asset(let url): record[key] = CKAsset(fileURL: url)
            }
        }
        return .save(record)
    }
}

enum MealPlanCloudKitStateStoreError: Error {
    case unsupportedRecordField(String)
    case appGroupUnavailable
    case verificationFailed
}
