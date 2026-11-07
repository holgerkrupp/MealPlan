import Foundation
import OSLog
import SQLite3
import Testing
@testable import MealPlan

@Suite(.serialized)
struct StoreUUIDRepairTests {
    private let logger = Logger(subsystem: "MealPlanTests", category: "uuid-repair")

    @Test func healthyPreflightDoesNotAcquireWriteTransaction() throws {
        let (url, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let outcome = StoreUUIDRepair.repairMissingUUIDs(at: url, logger: logger)

        #expect(outcome == .healthy)
        #expect(!outcome.didAcquireWriteTransaction)
    }

    @Test func repairsLegacyNullUUIDsAndRepeatedLaunchIsReadOnly() throws {
        let (url, directory) = try makeStore(nullRows: 3)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = StoreUUIDRepair.repairMissingUUIDs(at: url, logger: logger)
        let second = StoreUUIDRepair.repairMissingUUIDs(at: url, logger: logger)

        #expect(first == .repaired(rows: 3))
        #expect(first.didAcquireWriteTransaction)
        #expect(second == .healthy)
        #expect(!second.didAcquireWriteTransaction)
        #expect(try uuidCount(in: url, where: "IS NULL") == 0)
        #expect(try uuidCount(in: url, where: "IS NOT NULL") == 3)
    }

    @Test func concurrentWriterDoesNotMakeHealthyPreflightWaitForWriteLock() throws {
        let (url, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try open(url)
        defer { sqlite3_close(writer) }
        #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

        let started = ContinuousClock.now
        let outcome = StoreUUIDRepair.repairMissingUUIDs(at: url, logger: logger)
        let duration = started.duration(to: .now)

        #expect(outcome == .healthy)
        #expect(!outcome.didAcquireWriteTransaction)
        #expect(duration < .seconds(1))
        #expect(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
    }

    @Test func interruptedWriteCanBeRetriedWithoutLosingLegacyRows() throws {
        let (url, directory) = try makeStore(nullRows: 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try open(url)
        #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(writer, "UPDATE ZDish SET ZUUID = randomblob(16)", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(writer)

        let retry = StoreUUIDRepair.repairMissingUUIDs(at: url, logger: logger)
        #expect(retry == .repaired(rows: 2))
        #expect(try uuidCount(in: url, where: "IS NULL") == 0)
    }

    @Test func legacyStoreContentionIsBoundedAndRelaunchRepairsIt() throws {
        let (url, directory) = try makeStore(nullRows: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try open(url)
        #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

        let started = ContinuousClock.now
        let contended = StoreUUIDRepair.repairMissingUUIDs(at: url, logger: logger)
        let duration = started.duration(to: .now)
        #expect(duration < .seconds(2))
        guard case .contended = contended else {
            sqlite3_exec(writer, "ROLLBACK", nil, nil, nil)
            sqlite3_close(writer)
            Issue.record("Expected the UUID repair write transaction to report contention")
            return
        }

        #expect(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(writer)
        #expect(StoreUUIDRepair.repairMissingUUIDs(at: url, logger: logger) == .repaired(rows: 1))
        #expect(try uuidCount(in: url, where: "IS NULL") == 0)
    }

    private func makeStore(nullRows: Int = 0) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MealPlanUUIDRepair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "MealPlan.sqlite")
        let database = try open(url)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "CREATE TABLE ZDish (Z_PK INTEGER PRIMARY KEY, ZUUID BLOB)", nil, nil, nil) == SQLITE_OK)
        for _ in 0..<nullRows {
            #expect(sqlite3_exec(database, "INSERT INTO ZDish (ZUUID) VALUES (NULL)", nil, nil, nil) == SQLITE_OK)
        }
        return (url, directory)
    }

    private func open(_ url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw TestError.sqliteOpen(result)
        }
        sqlite3_busy_timeout(database, 100)
        return database
    }

    private func uuidCount(in url: URL, where condition: String) throws -> Int {
        let database = try open(url)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM ZDish WHERE ZUUID \(condition)", -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw TestError.sqliteOpen(result) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw TestError.sqliteOpen(sqlite3_errcode(database)) }
        return Int(sqlite3_column_int(statement, 0))
    }

    private enum TestError: Error {
        case sqliteOpen(Int32)
    }
}
