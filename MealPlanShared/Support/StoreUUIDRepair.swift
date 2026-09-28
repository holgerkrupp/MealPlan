import Foundation
import OSLog
import SQLite3

/// Repairs rows written by older schema versions before SwiftData materializes
/// them. SwiftData's generated accessor force-casts a non-optional UUID, so a
/// legacy row whose newly-added UUID column is NULL crashes before application
/// code gets a chance to assign a replacement.
enum StoreUUIDRepair {

    private struct Column {
        let name: String
        let declaredType: String
    }

    /// Fills NULL UUID columns in the SQLite store with fresh 128-bit values.
    /// The operation is deliberately schema-driven: SwiftData has used
    /// `ZUUID` for these stable identity attributes, but table names vary as
    /// models are added and should not be hard-coded here.
    @discardableResult
    static func repairMissingUUIDs(at url: URL, logger: Logger) -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if let database {
                logger.error("Could not open the store for UUID repair: \(String(cString: sqlite3_errmsg(database)))")
                sqlite3_close(database)
            }
            return 0
        }
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 10_000)
        guard execute("BEGIN IMMEDIATE TRANSACTION", on: database) else {
            logger.error("Could not lock the store for UUID repair: \(String(cString: sqlite3_errmsg(database)))")
            return 0
        }

        var repaired = 0
        do {
            for table in try tableNames(in: database) {
                guard let uuidColumn = try columns(in: table, database: database).first(where: {
                    $0.name.caseInsensitiveCompare("ZUUID") == .orderedSame
                }) else { continue }

                let tableSQL = quoteIdentifier(table)
                let columnSQL = quoteIdentifier(uuidColumn.name)
                let valueSQL = uuidValueExpression(for: uuidColumn.declaredType)
                let statement = "UPDATE \(tableSQL) SET \(columnSQL) = \(valueSQL) WHERE \(columnSQL) IS NULL"
                guard execute(statement, on: database) else {
                    throw RepairError.sqlite(String(cString: sqlite3_errmsg(database)))
                }
                repaired += Int(sqlite3_changes(database))
            }
            guard execute("COMMIT", on: database) else {
                throw RepairError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
        } catch {
            _ = execute("ROLLBACK", on: database)
            logger.error("UUID repair failed: \(String(describing: error))")
            return 0
        }

        if repaired > 0 {
            logger.warning("Repaired \(repaired) missing persisted UUID values")
        }
        return repaired
    }

    private enum RepairError: Error {
        case sqlite(String)
    }

    private static func tableNames(in database: OpaquePointer) throws -> [String] {
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }

        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) {
                names.append(String(cString: value))
            }
        }
        guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
            throw RepairError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return names
    }

    private static func columns(in table: String, database: OpaquePointer) throws -> [Column] {
        let sql = "PRAGMA table_info(\(quoteIdentifier(table)))"
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }

        var columns: [Column] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            let type = sqlite3_column_text(statement, 2).map(String.init(cString:)) ?? ""
            columns.append(Column(name: String(cString: name), declaredType: type))
        }
        guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
            throw RepairError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return columns
    }

    private static func prepare(_ sql: String, on database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw RepairError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    @discardableResult
    private static func execute(_ sql: String, on database: OpaquePointer) -> Bool {
        sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
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
