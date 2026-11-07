import Foundation
import OSLog
import SQLite3

/// Repairs rows written by older schema versions before SwiftData materializes
/// them. SwiftData's generated accessor force-casts a non-optional UUID, so a
/// legacy row whose newly-added UUID column is NULL crashes before application
/// code gets a chance to assign a replacement.
enum StoreUUIDRepair {

    enum Outcome: Equatable {
        case storeMissing
        case healthy
        case repaired(rows: Int)
        case contended(stage: String, code: Int32)
        case failed(stage: String, code: Int32)

        var didAcquireWriteTransaction: Bool {
            if case .repaired = self { return true }
            return false
        }
    }

    private struct Column {
        let name: String
        let declaredType: String
    }

    /// Uses a read-only preflight on every process launch. Healthy stores never
    /// take a SQLite write reservation. The short write transaction is entered
    /// only after the preflight finds NULL UUID values, and the rows are checked
    /// again after acquiring it to handle another process repairing first.
    @discardableResult
    static func repairMissingUUIDs(at url: URL, logger: Logger) -> Outcome {
        let startedAt = ContinuousClock.now
        guard FileManager.default.fileExists(atPath: url.path) else { return .storeMissing }

        let readOnly: OpaquePointer
        switch open(url: url, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, timeoutMilliseconds: 250) {
        case .success(let database): readOnly = database
        case .failure(let failure):
            log(failure, stage: "preflight.open", startedAt: startedAt, logger: logger)
            return failure.outcome(stage: "preflight.open")
        }
        let missing: [String: Column]
        do {
            missing = try missingUUIDColumns(in: readOnly)
        } catch {
            let code = sqlite3_errcode(readOnly)
            sqlite3_close(readOnly)
            let failure = SQLiteFailure(code: code, message: String(describing: error))
            log(failure, stage: "preflight", startedAt: startedAt, logger: logger)
            return failure.outcome(stage: "preflight")
        }
        sqlite3_close(readOnly)

        guard !missing.isEmpty else {
            let duration = startedAt.duration(to: .now)
            logger.debug("uuidRepair.preflight.healthy duration=\(duration, privacy: .public)")
            return .healthy
        }

        logger.notice("uuidRepair.start tables=\(missing.count, privacy: .public)")
        let writable: OpaquePointer
        switch open(url: url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, timeoutMilliseconds: 500) {
        case .success(let database): writable = database
        case .failure(let failure):
            log(failure, stage: "repair.open", startedAt: startedAt, logger: logger)
            return failure.outcome(stage: "repair.open")
        }
        defer { sqlite3_close(writable) }

        guard execute("BEGIN IMMEDIATE TRANSACTION", on: writable) else {
            let failure = SQLiteFailure(code: sqlite3_errcode(writable), message: String(cString: sqlite3_errmsg(writable)))
            log(failure, stage: "repair.begin", startedAt: startedAt, logger: logger)
            return failure.outcome(stage: "repair.begin")
        }

        do {
            // Another process may have completed repair between the read-only
            // check and BEGIN IMMEDIATE. Re-query under the lock before writes.
            let currentMissing = try missingUUIDColumns(in: writable)
            var repaired = 0
            for (table, column) in currentMissing {
                let tableSQL = quoteIdentifier(table)
                let columnSQL = quoteIdentifier(column.name)
                let valueSQL = uuidValueExpression(for: column.declaredType)
                let statement = "UPDATE \(tableSQL) SET \(columnSQL) = \(valueSQL) WHERE \(columnSQL) IS NULL"
                guard execute(statement, on: writable) else {
                    throw SQLiteFailure(code: sqlite3_errcode(writable), message: String(cString: sqlite3_errmsg(writable)))
                }
                repaired += Int(sqlite3_changes(writable))
            }
            guard execute("COMMIT", on: writable) else {
                throw SQLiteFailure(code: sqlite3_errcode(writable), message: String(cString: sqlite3_errmsg(writable)))
            }
            let duration = startedAt.duration(to: .now)
            logger.notice("uuidRepair.committed rows=\(repaired, privacy: .public) duration=\(duration, privacy: .public)")
            return .repaired(rows: repaired)
        } catch {
            _ = execute("ROLLBACK", on: writable)
            let failure = (error as? SQLiteFailure) ?? SQLiteFailure(
                code: sqlite3_errcode(writable), message: String(describing: error)
            )
            log(failure, stage: "repair.transaction", startedAt: startedAt, logger: logger)
            return failure.outcome(stage: "repair.transaction")
        }
    }

    private struct SQLiteFailure: Error {
        let code: Int32
        let message: String

        var isContention: Bool {
            code == SQLITE_BUSY || code == SQLITE_LOCKED || (code & 0xff) == SQLITE_BUSY || (code & 0xff) == SQLITE_LOCKED
        }

        func outcome(stage: String) -> Outcome {
            isContention ? .contended(stage: stage, code: code) : .failed(stage: stage, code: code)
        }
    }

    private enum OpenResult {
        case success(OpaquePointer)
        case failure(SQLiteFailure)
    }

    private static func open(url: URL, flags: Int32, timeoutMilliseconds: Int32) -> OpenResult {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let failure = SQLiteFailure(
                code: result,
                message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            )
            if let database { sqlite3_close(database) }
            return .failure(failure)
        }
        sqlite3_busy_timeout(database, timeoutMilliseconds)
        return .success(database)
    }

    private static func missingUUIDColumns(in database: OpaquePointer) throws -> [String: Column] {
        let names = try tableNames(in: database)
        var result: [String: Column] = [:]
        for table in names {
            guard let uuidColumn = try columns(in: table, database: database).first(where: {
                $0.name.caseInsensitiveCompare("ZUUID") == .orderedSame
            }) else { continue }
            let sql = "SELECT 1 FROM \(quoteIdentifier(table)) WHERE \(quoteIdentifier(uuidColumn.name)) IS NULL LIMIT 1"
            let statement = try prepare(sql, on: database)
            defer { sqlite3_finalize(statement) }
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { result[table] = uuidColumn }
            else if step != SQLITE_DONE {
                throw SQLiteFailure(code: step, message: String(cString: sqlite3_errmsg(database)))
            }
        }
        return result
    }

    private static func tableNames(in database: OpaquePointer) throws -> [String] {
        let statement = try prepare(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
            on: database
        )
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return names }
            guard step == SQLITE_ROW else {
                throw SQLiteFailure(code: step, message: String(cString: sqlite3_errmsg(database)))
            }
            if let value = sqlite3_column_text(statement, 0) { names.append(String(cString: value)) }
        }
    }

    private static func columns(in table: String, database: OpaquePointer) throws -> [Column] {
        let statement = try prepare("PRAGMA table_info(\(quoteIdentifier(table)))", on: database)
        defer { sqlite3_finalize(statement) }
        var columns: [Column] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return columns }
            guard step == SQLITE_ROW else {
                throw SQLiteFailure(code: step, message: String(cString: sqlite3_errmsg(database)))
            }
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            let type = sqlite3_column_text(statement, 2).map(String.init(cString:)) ?? ""
            columns.append(Column(name: String(cString: name), declaredType: type))
        }
    }

    private static func prepare(_ sql: String, on database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteFailure(code: sqlite3_errcode(database), message: String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    @discardableResult
    private static func execute(_ sql: String, on database: OpaquePointer) -> Bool {
        sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func log(_ failure: SQLiteFailure, stage: String, startedAt: ContinuousClock.Instant, logger: Logger) {
        let duration = startedAt.duration(to: .now)
        if failure.isContention {
            logger.warning("uuidRepair.contended stage=\(stage, privacy: .public) code=\(failure.code, privacy: .public) duration=\(duration, privacy: .public)")
        } else {
            logger.error("uuidRepair.failed stage=\(stage, privacy: .public) code=\(failure.code, privacy: .public) duration=\(duration, privacy: .public) error=\(failure.message, privacy: .public)")
        }
    }

    private static func quoteIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func uuidValueExpression(for declaredType: String) -> String {
        let type = declaredType.uppercased()
        guard type.contains("CHAR") || type.contains("CLOB") || type.contains("TEXT") else {
            return "randomblob(16)"
        }
        return "lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)), 2) || '-' || substr('89ab', abs(random()) % 4 + 1, 1) || substr(hex(randomblob(2)), 2) || '-' || hex(randomblob(6)))"
    }
}
