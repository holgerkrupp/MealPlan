import CloudKit
import CollaborationCloudKit
import CollaborationCore
import CryptoKit
import Foundation
import Testing
@testable import MealPlan

struct MealPlanCloudKitStateStoreTests {
    @Test func stateDefaultsMigrationCanResumeAfterFileWriteFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = Data([0x10, 0x20, 0x30])
        let key = fixture.stateKey(scope: .private)
        fixture.defaults.set(state, forKey: key)

        let interrupted = fixture.makeStore { point in
            if point == .stateFileWrite { throw InjectedFault.fileWrite }
        }
        do {
            _ = try await interrupted.loadState(for: .private)
            Issue.record("Expected injected state-file write failure.")
        } catch InjectedFault.fileWrite {
            // The UserDefaults copy must remain the recovery source.
        }
        #expect(fixture.defaults.data(forKey: key) == state)
        #expect(!FileManager.default.fileExists(atPath: fixture.stateURL(scope: .private).path))

        let recovered = try await fixture.makeStore().loadState(for: .private)
        #expect(recovered == state)
        #expect(fixture.defaults.data(forKey: key) == nil)
        #expect(try Data(contentsOf: fixture.stateURL(scope: .private)) == state)
    }

    @Test func stateDefaultsRetirementFailureLeavesBothCopiesAndRetryCompletes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let state = Data([0x41, 0x52, 0x63, 0x74])
        let key = fixture.stateKey(scope: .private)
        fixture.defaults.set(state, forKey: key)

        let interrupted = fixture.makeStore { point in
            if point == .stateDefaultsRetirement { throw InjectedFault.defaultsRetirement }
        }
        do {
            _ = try await interrupted.loadState(for: .private)
            Issue.record("Expected injected defaults retirement failure.")
        } catch InjectedFault.defaultsRetirement {
            // The atomic file is durable, and the defaults copy was not retired.
        }
        #expect(fixture.defaults.data(forKey: key) == state)
        #expect(try Data(contentsOf: fixture.stateURL(scope: .private)) == state)

        let recovered = try await fixture.makeStore().loadState(for: .private)
        #expect(recovered == state)
        #expect(fixture.defaults.data(forKey: key) == nil)
        #expect(try Data(contentsOf: fixture.stateURL(scope: .private)) == state)
    }

    @Test func stateMigrationCanResumeAfterEachFileDurabilityBoundary() async throws {
        for interruptedBoundary in [
            MealPlanCloudKitStateStore.MigrationFaultPoint.afterFileSynchronization,
            .afterDirectorySynchronization,
        ] {
            let fixture = try Fixture()
            let state = Data([0x91, 0x82, 0x73, 0x64])
            let key = fixture.stateKey(scope: .private)
            fixture.defaults.set(state, forKey: key)

            let interrupted = fixture.makeStore { point in
                if point == interruptedBoundary { throw InjectedFault.durabilityBoundary }
            }
            do {
                _ = try await interrupted.loadState(for: .private)
                Issue.record("Expected an injected interruption at \(interruptedBoundary).")
            } catch InjectedFault.durabilityBoundary {
                // State remains recoverable from defaults if the rename is lost,
                // or from the synchronized file when the rename survives.
            }

            #expect(fixture.defaults.data(forKey: key) == state)
            let recovered = try await fixture.makeStore().loadState(for: .private)
            #expect(recovered == state)
            #expect(fixture.defaults.data(forKey: key) == nil)
            fixture.cleanUp()
        }
    }

    @Test func divergentStateCopiesRemainAvailableThroughRealLoadPath() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let fileCopy = Data([0x01, 0x02])
        let defaultsCopy = Data([0x01, 0x03])
        let key = fixture.stateKey(scope: .private)
        fixture.defaults.set(defaultsCopy, forKey: key)
        try FileManager.default.createDirectory(
            at: fixture.stateURL(scope: .private).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileCopy.write(to: fixture.stateURL(scope: .private), options: .atomic)

        do {
            _ = try await fixture.makeStore().loadState(for: .private)
            Issue.record("Expected divergent copies to stop the load.")
        } catch MealPlanCloudKitStateStoreError.stateCopiesDiverged {
            // Neither copy is modified or retired.
        }
        #expect(fixture.defaults.data(forKey: key) == defaultsCopy)
        #expect(try Data(contentsOf: fixture.stateURL(scope: .private)) == fileCopy)
    }

    @Test func journalMigrationRetainsCursorPendingSavesDeletesAndRecordFields() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let zoneID = fixture.locator.zoneID
        let assetURL = fixture.root.appending(path: "pending-photo.bin")
        let assetBytes = Data([0xA0, 0xB1, 0xC2, 0xD3])
        try assetBytes.write(to: assetURL)

        let saveID = CKRecord.ID(recordName: "MPDish-pending", zoneID: zoneID)
        let record = CKRecord(recordType: "MPDish", recordID: saveID)
        let payload = Data("snapshot payload".utf8)
        let modifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        record[HouseholdRecordCodec.payloadKey] = payload as CKRecordValue
        record[HouseholdRecordCodec.modifiedAtKey] = modifiedAt as CKRecordValue
        record["fingerprint"] = "dish-fingerprint-v1" as CKRecordValue
        record["text"] = "pending text" as CKRecordValue
        record["bytes"] = Data([0x11, 0x22]) as CKRecordValue
        record["count"] = NSNumber(value: 7)
        record[HouseholdRecordCodec.assetKey] = CKAsset(fileURL: assetURL)

        let deletionID = CKRecord.ID(recordName: "MPIngredient-deleted", zoneID: zoneID)
        let cursor = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let originalStore = fixture.makeStore()
        try await originalStore.stageLocalChanges(
            [.save(record), .delete(deletionID)],
            advancingTo: cursor,
            in: .private
        )

        let journalURL = fixture.journalURL(scope: .private)
        let journalKey = fixture.journalKey(scope: .private)
        let originalJournal = try Data(contentsOf: journalURL)
        fixture.defaults.set(originalJournal, forKey: journalKey)
        try FileManager.default.removeItem(at: journalURL)

        let failedWrite = fixture.makeStore { point in
            if point == .journalFileWrite { throw InjectedFault.fileWrite }
        }
        do {
            _ = try await failedWrite.pendingLocalChanges(in: .private)
            Issue.record("Expected injected journal-file write failure.")
        } catch InjectedFault.fileWrite {
            // The defaults copy still contains every queued operation and cursor.
        }
        #expect(fixture.defaults.data(forKey: journalKey) == originalJournal)
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))

        let interrupted = fixture.makeStore { point in
            if point == .journalDefaultsRetirement { throw InjectedFault.defaultsRetirement }
        }
        do {
            _ = try await interrupted.pendingLocalChanges(in: .private)
            Issue.record("Expected injected journal retirement failure.")
        } catch InjectedFault.defaultsRetirement {
            // The defaults journal and its verified file copy remain available.
        }
        #expect(fixture.defaults.data(forKey: journalKey) == originalJournal)
        #expect(try Data(contentsOf: journalURL) == originalJournal)

        let recoveredStore = fixture.makeStore()
        let recovered = try await recoveredStore.pendingLocalChanges(in: .private)
        #expect(fixture.defaults.data(forKey: journalKey) == nil)
        #expect(try Data(contentsOf: journalURL) == originalJournal)
        #expect(recovered.count == 2)

        let recoveredSave = try #require(recovered.compactMap { change -> CKRecord? in
            guard case .save(let record) = change else { return nil }
            return record
        }.first)
        #expect(recoveredSave.recordID == saveID)
        #expect(recoveredSave.recordType == "MPDish")
        #expect(recoveredSave[HouseholdRecordCodec.payloadKey] as? Data == payload)
        #expect(recoveredSave[HouseholdRecordCodec.modifiedAtKey] as? Date == modifiedAt)
        #expect(recoveredSave["fingerprint"] as? String == "dish-fingerprint-v1")
        #expect(recoveredSave["text"] as? String == "pending text")
        #expect(recoveredSave["bytes"] as? Data == Data([0x11, 0x22]))
        #expect((recoveredSave["count"] as? NSNumber)?.intValue == 7)
        let recoveredAssetURL = try #require((recoveredSave[HouseholdRecordCodec.assetKey] as? CKAsset)?.fileURL)
        #expect(try Data(contentsOf: recoveredAssetURL) == assetBytes)

        let recoveredDelete = try #require(recovered.first { change in
            if case .delete(let id) = change { return id == deletionID }
            return false
        })
        if case .delete(let id) = recoveredDelete {
            #expect(id == deletionID)
        } else {
            Issue.record("Expected the pending delete to survive journal migration.")
        }

        let journalObject = try #require(
            JSONSerialization.jsonObject(with: originalJournal) as? [String: Any]
        )
        #expect((journalObject["historyCursor"] as? String).flatMap { Data(base64Encoded: $0) } == cursor)
        let entries = try #require(journalObject["entries"] as? [String: Any])
        let savedEntry = try #require(entries.values.compactMap { $0 as? [String: Any] }.first {
            $0["recordName"] as? String == saveID.recordName
        })
        #expect((savedEntry["systemFields"] as? String).flatMap { Data(base64Encoded: $0) }?.isEmpty == false)
    }
}

private enum InjectedFault: Error, Sendable {
    case fileWrite
    case defaultsRetirement
    case durabilityBoundary
}

private struct Fixture {
    let suiteName: String
    let defaults: UserDefaults
    let root: URL
    let locator: HouseholdShareLocator
    let environment: CollaborationEnvironment = .production
    let accountPartitionIdentifier = "test-account-partition"

    init() throws {
        suiteName = "MealPlanCloudKitStateStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.fileReadUnknown)
        }
        self.defaults = defaults
        defaults.removePersistentDomain(forName: suiteName)
        root = FileManager.default.temporaryDirectory
            .appending(path: "MealPlanCloudKitStateStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        locator = .init(
            zoneName: "MealPlanHousehold-\(UUID().uuidString)",
            ownerName: CKCurrentUserDefaultName,
            shareRecordName: nil,
            isOwner: true,
            isReadOnly: false
        )
    }

    func makeStore(
        faultInjector: @escaping @Sendable (MealPlanCloudKitStateStore.MigrationFaultPoint) throws -> Void = { _ in }
    ) -> MealPlanCloudKitStateStore {
        MealPlanCloudKitStateStore(
            containerIdentifier: SharedStore.cloudKitContainerID,
            environment: environment,
            accountPartitionIdentifier: accountPartitionIdentifier,
            activeLocator: locator,
            defaultsSuiteName: suiteName,
            storageRootURL: root,
            migrationFaultInjector: faultInjector
        )
    }

    func stateKey(scope: CollaborationDatabaseScope) -> String {
        "HouseholdRecordSync.package.state.\(environment.rawValue).\(accountPartitionIdentifier).\(scope.rawValue)"
    }

    func journalKey(scope: CollaborationDatabaseScope) -> String {
        "HouseholdRecordSync.package.journal.\(environment.rawValue).\(accountPartitionIdentifier).\(scope.rawValue)"
    }

    func stateURL(scope: CollaborationDatabaseScope) -> URL {
        fileURL(kind: "state", scope: scope, extension: "bin")
    }

    func journalURL(scope: CollaborationDatabaseScope) -> URL {
        fileURL(kind: "journal", scope: scope, extension: "json")
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func fileURL(kind: String, scope: CollaborationDatabaseScope, extension fileExtension: String) -> URL {
        let material = "\(environment.rawValue)|\(accountPartitionIdentifier)|\(scope.rawValue)"
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: "HouseholdSyncState/\(kind)-v1-\(digest).\(fileExtension)")
    }
}
