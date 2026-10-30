import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// A very small SQLite wrapper. The kernel is the only writer, so a single
/// connection guarded by a lock keeps the persistence model simple.
public final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw SQLiteError(message: "Cannot open database at \(path): \(message)")
        }
        handle = db
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try execute("PRAGMA busy_timeout=5000;")
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    public func execute(_ sql: String, _ bindings: [Any?] = []) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            if step == SQLITE_ROW { continue }
            throw SQLiteError(message: "SQLite step failed (\(step)): \(lastErrorMessage)")
        }
    }

    public func query(_ sql: String, _ bindings: [Any?] = []) throws -> [[String: Any?]] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }

        var rows: [[String: Any?]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteError(message: "SQLite query failed (\(step)): \(lastErrorMessage)")
            }
            var row: [String: Any?] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    row[name] = sqlite3_column_int64(statement, index)
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(statement, index)
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, index) {
                        row[name] = String(cString: text)
                    } else {
                        row[name] = nil
                    }
                case SQLITE_NULL:
                    row[name] = nil
                default:
                    if let bytes = sqlite3_column_blob(statement, index) {
                        let count = Int(sqlite3_column_bytes(statement, index))
                        row[name] = Data(bytes: bytes, count: count)
                    } else {
                        row[name] = nil
                    }
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func userVersion() throws -> Int {
        let rows = try query("PRAGMA user_version;")
        guard let value = rows.first?["user_version"] else { return 0 }
        if let int = value as? Int64 { return Int(int) }
        if let int = value as? Int { return int }
        return 0
    }

    public func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version);")
    }

    /// Copies the database outside any transaction. Destination must not exist.
    public func vacuum(into destination: String) throws {
        let escaped = destination.replacingOccurrences(of: "'", with: "''")
        try execute("VACUUM INTO '\(escaped)';")
    }

    public func transaction(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try stepUnlocked("BEGIN IMMEDIATE;")
        do {
            try body()
            try stepUnlocked("COMMIT;")
        } catch {
            try? stepUnlocked("ROLLBACK;")
            throw error
        }
    }

    public func scalarInt(_ sql: String, _ bindings: [Any?] = []) throws -> Int {
        let rows = try query(sql, bindings)
        guard let first = rows.first, let value = first.values.first ?? nil else { return 0 }
        if let int = value as? Int64 { return Int(int) }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private func stepUnlocked(_ sql: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(message: "Cannot prepare statement: \(lastErrorMessage)")
        }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
            throw SQLiteError(message: "SQLite step failed (\(step)): \(lastErrorMessage)")
        }
    }

    private func prepare(_ sql: String, _ bindings: [Any?]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(message: "Cannot prepare statement: \(lastErrorMessage) (\(sql.prefix(120)))")
        }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case nil:
                sqlite3_bind_null(statement, index)
            case let value as String:
                sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case let value as Int:
                sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Int64:
                sqlite3_bind_int64(statement, index, value)
            case let value as Double:
                sqlite3_bind_double(statement, index, value)
            case let value as Bool:
                sqlite3_bind_int(statement, index, value ? 1 : 0)
            case let value as Data:
                sqlite3_bind_blob(statement, index, (value as NSData).bytes, Int32(value.count), SQLITE_TRANSIENT)
            default:
                sqlite3_bind_text(statement, index, String(describing: binding!), -1, SQLITE_TRANSIENT)
            }
        }
        return statement
    }

    private var lastErrorMessage: String {
        guard let handle else { return "no handle" }
        return String(cString: sqlite3_errmsg(handle))
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
