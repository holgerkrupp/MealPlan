import CloudKit
import CollaborationCore
import CollaborationCloudKit
import Foundation
import OSLog

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

    fileprivate struct ArchivedChange: Codable {
        enum Operation: String, Codable { case save, delete }
        var operation: Operation
        var recordName: String
        var recordType: String?
        var zoneName: String
        var zoneOwnerName: String
        var fields: [String: Field]
        var systemFields: Data?
    }

    fileprivate enum Field: Codable {
        case string(String)
        case data(Data)
        case date(Date)
        case number(Double, isInteger: Bool)
        case asset(URL)
    }

    private let defaults: UserDefaults
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

    func loadState(for scope: CollaborationDatabaseScope) async throws -> Data? {
        if let data = defaults.data(forKey: stateKey(for: scope)) { return data }
        guard scope == activeScope else { return nil }
        // The old engine serialized one state per household zone. Reuse that
        // token for the matching private/shared database on first package use;
        // keep the old key so a rollback build can still recover it.
        return defaults.data(forKey: legacyStateKey)
    }

    func saveState(_ data: Data, for scope: CollaborationDatabaseScope) async throws {
        defaults.set(data, forKey: stateKey(for: scope))
        if scope == activeScope {
            defaults.set(data, forKey: legacyStateKey)
        }
    }

    func reportStatePersistenceFailure(_ failure: CollaborationFailure, for scope: CollaborationDatabaseScope) async {
        logger.error("Could not persist \(scope.rawValue, privacy: .public) CloudKit engine state (\(failure.rawValue, privacy: .public)).")
    }

    func stageLocalChanges(
        _ changes: [CloudKitRecordChange],
        advancingTo historyCursor: Data?,
        in scope: CollaborationDatabaseScope
    ) async throws {
        var journal = loadJournal(for: scope)
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
        loadJournal(for: scope).entries.values
            .sorted { $0.recordName < $1.recordName }
            .map(\.cloudKitChange)
    }

    func acknowledgeSentChanges(
        savedRecords: [CKRecord],
        deletedRecordIDs: [CKRecord.ID],
        in scope: CollaborationDatabaseScope
    ) throws {
        var journal = loadJournal(for: scope)
        for record in savedRecords {
            journal.entries.removeValue(forKey: Self.entryKey(
                recordName: record.recordID.recordName,
                zoneName: record.recordID.zoneID.zoneName,
                ownerName: record.recordID.zoneID.ownerName
            ))
        }
        for recordID in deletedRecordIDs {
            journal.entries.removeValue(forKey: Self.entryKey(
                recordName: recordID.recordName,
                zoneName: recordID.zoneID.zoneName,
                ownerName: recordID.zoneID.ownerName
            ))
        }
        try saveJournal(journal, for: scope)
    }

    func discardDatabaseState(for scope: CollaborationDatabaseScope) {
        defaults.removeObject(forKey: stateKey(for: scope))
        defaults.removeObject(forKey: journalKey(for: scope))
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

    private func loadJournal(for scope: CollaborationDatabaseScope) -> Journal {
        guard let data = defaults.data(forKey: journalKey(for: scope)) else { return Journal() }
        return (try? JSONDecoder().decode(Journal.self, from: data)) ?? Journal()
    }

    private func saveJournal(_ journal: Journal, for scope: CollaborationDatabaseScope) throws {
        defaults.set(try JSONEncoder().encode(journal), forKey: journalKey(for: scope))
    }

    private static func entryKey(recordName: String, zoneName: String, ownerName: String) -> String {
        "\(ownerName)|\(zoneName)|\(recordName)"
    }
}

fileprivate extension MealPlanCloudKitStateStore.ArchivedChange {
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
}
