import Foundation
import Testing
@testable import MealPlan

struct HouseholdMetadataMigrationTests {
    @Test func unrelatedEnvironmentMetadataCannotBlockActiveNamespace() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let unrelatedKey = "HouseholdRecordSync.metadata.Development-other-household"
        let corruptUnrelatedValue = Data("not metadata".utf8)
        defaults.set(corruptUnrelatedValue, forKey: unrelatedKey)
        let fileURL = try makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let loaded = try await HouseholdMetadataWriter(suiteName: suite).load(
            legacyKey: "HouseholdRecordSync.metadata.Production-active-household",
            legacyFileURL: fileURL.appendingPathExtension("legacy"),
            activeFileURL: fileURL
        )

        #expect(loaded == HouseholdSyncMetadata())
        #expect(defaults.data(forKey: unrelatedKey) == corruptUnrelatedValue)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func missingMetadataWithPendingJournalFailsClosed() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let activeFileURL = try makeFileURL()
        defer { try? FileManager.default.removeItem(at: activeFileURL.deletingLastPathComponent()) }

        do {
            _ = try await HouseholdMetadataWriter(suiteName: suite).load(
                legacyKey: "HouseholdRecordSync.metadata.active",
                legacyFileURL: activeFileURL.appendingPathExtension("legacy"),
                activeFileURL: activeFileURL,
                journalEntryCount: 2
            )
            Issue.record("Expected missing metadata with a pending journal to pause sync.")
        } catch let error as HouseholdRecordSyncError {
            guard case .metadataMissingForPendingJournal(entries: 2) = error else {
                Issue.record("Expected a missing metadata recovery error, got \(error).")
                return
            }
        }

        #expect(!FileManager.default.fileExists(atPath: activeFileURL.path))
    }

    @Test func legacyOnlyMigrationPreservesAllStateAndCanResumeAfterInterruption() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "HouseholdRecordSync.metadata.active"
        let fileURL = try makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let legacyFileURL = fileURL.appendingPathExtension("legacy")
        var expected = HouseholdSyncMetadata()
        expected.serverFingerprints = ["server": "acknowledged"]
        expected.serverGroupFingerprints = ["server": ["recipe": "group-hash"]]
        expected.pendingFingerprints = ["pending": "unsent"]
        expected.pendingGroupFingerprints = ["pending": ["ingredients": "pending-hash"]]
        expected.systemFields = ["pending": Data([1, 2, 3, 4])]
        expected.tombstones = [.init(
            markerUUID: UUID(),
            deletedType: .dish,
            deletedUUID: UUID(),
            deletedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )]
        expected.needsFullUpload = true
        let legacyData = try JSONEncoder().encode(expected)
        defaults.set(legacyData, forKey: key)

        let writer = HouseholdMetadataWriter(suiteName: suite)
        let migrated = try await writer.load(legacyKey: key, legacyFileURL: legacyFileURL, activeFileURL: fileURL)

        #expect(migrated == expected)
        #expect(defaults.data(forKey: key) == nil)
        #expect(try Data(contentsOf: fileURL) == legacyData)

        // A process killed after the atomic file write but before retiring the
        // defaults key can repeat safely when both decoded states agree.
        defaults.set(legacyData, forKey: key)
        let resumed = try await writer.load(legacyKey: key, legacyFileURL: legacyFileURL, activeFileURL: fileURL)
        #expect(resumed == expected)
        #expect(defaults.data(forKey: key) == nil)
    }

    @Test func equalStateWithDifferentJSONBytesCompletesMigration() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "HouseholdRecordSync.metadata.active"
        let fileURL = try makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let legacyFileURL = fileURL.appendingPathExtension("legacy")
        let legacy = Data(#"{"serverFingerprints":{"dish":"v1"},"pendingFingerprints":{}}"#.utf8)
        let file = Data(#"{"pendingFingerprints":{},"serverFingerprints":{"dish":"v1"}}"#.utf8)
        defaults.set(legacy, forKey: key)
        try file.write(to: legacyFileURL, options: .atomic)

        let resolved = try await HouseholdMetadataWriter(suiteName: suite).load(
            legacyKey: key,
            legacyFileURL: legacyFileURL,
            activeFileURL: fileURL
        )

        #expect(resolved.serverFingerprints == ["dish": "v1"])
        #expect(defaults.data(forKey: key) == nil)
        #expect(try Data(contentsOf: legacyFileURL) == file)
    }

    @Test func divergentCopiesRemainByteExactAndFailWithRecoverableError() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "HouseholdRecordSync.metadata.active"
        let fileURL = try makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let legacyFileURL = fileURL.appendingPathExtension("legacy")
        var legacyMetadata = HouseholdSyncMetadata()
        legacyMetadata.pendingFingerprints["dish"] = "unsent-old"
        var fileMetadata = HouseholdSyncMetadata()
        fileMetadata.pendingFingerprints["dish"] = "unsent-new"
        let legacy = try JSONEncoder().encode(legacyMetadata)
        let file = try JSONEncoder().encode(fileMetadata)
        defaults.set(legacy, forKey: key)
        try file.write(to: legacyFileURL, options: .atomic)

        do {
            _ = try await HouseholdMetadataWriter(suiteName: suite).load(
                legacyKey: key,
                legacyFileURL: legacyFileURL,
                activeFileURL: fileURL
            )
            Issue.record("Expected conflicting metadata copies to pause migration.")
        } catch let error as HouseholdRecordSyncError {
            guard case .metadataCopiesDiverged = error else {
                Issue.record("Expected a recoverable metadata divergence error, got \(error).")
                return
            }
        }

        #expect(defaults.data(forKey: key) == legacy)
        #expect(try Data(contentsOf: legacyFileURL) == file)
    }

    @Test func largeMetadataPreservesPendingUploadState() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "HouseholdRecordSync.metadata.large"
        let fileURL = try makeFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let legacyFileURL = fileURL.appendingPathExtension("legacy")
        var expected = HouseholdSyncMetadata()
        expected.pendingFingerprints["large-asset"] = "pending-save"
        expected.pendingGroupFingerprints["large-asset"] = ["photo": "digest"]
        expected.systemFields["large-asset"] = Data(repeating: 0xA5, count: 6 * 1024 * 1024)
        let legacy = try JSONEncoder().encode(expected)
        defaults.set(legacy, forKey: key)

        let actual = try await HouseholdMetadataWriter(suiteName: suite).load(
            legacyKey: key,
            legacyFileURL: legacyFileURL,
            activeFileURL: fileURL
        )

        #expect(actual == expected)
        #expect(actual.pendingFingerprints["large-asset"] == "pending-save")
        #expect(actual.pendingGroupFingerprints["large-asset"] == ["photo": "digest"])
        #expect(actual.systemFields["large-asset"]?.count == 6 * 1024 * 1024)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "MealPlanMetadataMigrationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw CocoaError(.fileReadUnknown)
        }
        return (defaults, suite)
    }

    private func makeFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MealPlanMetadataMigrationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "metadata.json")
    }
}
