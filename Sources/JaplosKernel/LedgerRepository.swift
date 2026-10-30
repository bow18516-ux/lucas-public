import Foundation
import JaplosProtocol

/// CRUD for the "record tables": every row is an `id` plus a `record_json`
/// document, with a few indexed columns for ordering and filtering.
///
/// Column names come from call sites, never from a request, so interpolating
/// them into the statement is safe; values are always bound.
struct LedgerRepository {
    let database: SQLiteDatabase

    /// `SELECT <select> FROM <table> [WHERE <filter> = ?] ORDER BY <order> LIMIT ?`
    func rows(
        table: String,
        select: [String],
        orderBy: String = "updated_at DESC",
        limit: Int = 100,
        filter: (column: String, value: Any?)? = nil
    ) throws -> [[String: Any?]] {
        let columns = select.joined(separator: ", ")
        let boundedLimit = max(1, min(limit, 500))
        if let filter {
            return try database.query(
                "SELECT \(columns) FROM \(table) WHERE \(filter.column) = ? ORDER BY \(orderBy) LIMIT ?;",
                [filter.value, boundedLimit]
            )
        }
        return try database.query(
            "SELECT \(columns) FROM \(table) ORDER BY \(orderBy) LIMIT ?;",
            [boundedLimit]
        )
    }

    /// `INSERT ... ON CONFLICT(id) DO UPDATE SET <update columns>`.
    /// `update` lists the columns to overwrite; `id` itself is never updated.
    func upsert(table: String, conflict: String = "id", values: [String: Any?], update: [String]) throws {
        let columns = values.keys.sorted()
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let assignments = update.map { "\($0) = excluded.\($0)" }.joined(separator: ",\n            ")
        let sql = """
        INSERT INTO \(table)(\(columns.joined(separator: ", ")))
        VALUES (\(placeholders))
        ON CONFLICT(\(conflict)) DO UPDATE SET
            \(assignments);
        """
        try database.execute(sql, columns.map { values[$0] ?? nil })
    }

    func delete(table: String, id: String) throws {
        try database.execute("DELETE FROM \(table) WHERE id = ?;", [id])
    }

    func deleteAll(table: String) throws {
        try database.execute("DELETE FROM \(table);")
    }

    func count(table: String) throws -> Int {
        try database.scalarInt("SELECT COUNT(*) FROM \(table);")
    }

    /// JSON-encoded `record_json` value for a row.
    static func encode(_ record: JSONValue) throws -> String {
        String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
    }
}
