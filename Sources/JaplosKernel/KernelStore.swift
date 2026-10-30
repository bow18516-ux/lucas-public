import Foundation
import JaplosProtocol

public final class KernelStore {
    public static let modelConnectionPath = "agents.default.model.connection"
    public static let modelSecretAccount = "agents.default.model.connection"

    public let database: SQLiteDatabase
    public let path: String
    public let secrets: SecretStore

    public init(path: String) throws {
        self.path = path
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.database = try SQLiteDatabase(path: path)
        self.secrets = SecretStore(home: directory)
        try migrate()
        migratePlaintextModelSecret()
    }

    // MARK: - Schema

    private func migrate() throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS configurations (
            path TEXT PRIMARY KEY NOT NULL,
            scope TEXT NOT NULL,
            value_json TEXT NOT NULL,
            revision INTEGER NOT NULL,
            updated_at REAL NOT NULL,
            updated_by TEXT NOT NULL
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS turns (
            id TEXT PRIMARY KEY NOT NULL,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            tool_calls_json TEXT NOT NULL,
            tool_call_id TEXT,
            tool_name TEXT,
            created_at REAL NOT NULL,
            metadata_json TEXT,
            FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_turns_session_time ON turns(session_id, created_at);")
        try database.execute("""
        CREATE TABLE IF NOT EXISTS permission_grants (
            id TEXT PRIMARY KEY NOT NULL,
            principal TEXT NOT NULL,
            capability TEXT NOT NULL,
            resource_pattern TEXT NOT NULL,
            expires_at REAL,
            revoked_at REAL,
            constraints_json TEXT
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_grants_principal ON permission_grants(principal, capability);")
        try database.execute("""
        CREATE TABLE IF NOT EXISTS tool_invocations (
            id TEXT PRIMARY KEY NOT NULL,
            session_id TEXT,
            tool TEXT NOT NULL,
            ok INTEGER NOT NULL,
            duration_ms REAL NOT NULL,
            arguments_json TEXT NOT NULL,
            output_json TEXT NOT NULL,
            error TEXT,
            created_at REAL NOT NULL
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_tool_invocations_time ON tool_invocations(created_at);")
    }

    // MARK: - Configuration

    public func configurationList() throws -> [JSONValue] {
        try database.query("SELECT path, scope, value_json, revision, updated_at, updated_by FROM configurations ORDER BY path;")
            .compactMap { row in
                guard
                    let path = row["path"] as? String,
                    let scope = row["scope"] as? String,
                    let valueJSON = row["value_json"] as? String,
                    let revision = row["revision"] as? Int64,
                    let updatedAt = row["updated_at"] as? Double,
                    let updatedBy = row["updated_by"] as? String,
                    let valueData = valueJSON.data(using: .utf8),
                    let value = try? ProtocolCoding.decode(JSONValue.self, from: valueData)
                else { return nil }
                var redacted = value
                if path == Self.modelConnectionPath, var object = redacted.objectValue {
                    object["apiKey"] = .string("")
                    object["apiKeyConfigured"] = .bool(secrets.secret(for: Self.modelSecretAccount) != nil)
                    redacted = .object(object)
                }
                return .object([
                    "path": .string(path),
                    "scope": .string(scope),
                    "value": redacted,
                    "revision": .number(Double(revision)),
                    "updatedAt": .string(ISO8601.string(from: Date(timeIntervalSince1970: updatedAt))),
                    "updatedBy": .string(updatedBy),
                ])
            }
    }

    public func configurationValue(_ path: String) throws -> JSONValue? {
        let rows = try database.query("SELECT value_json FROM configurations WHERE path = ? LIMIT 1;", [path])
        guard
            let raw = rows.first?["value_json"] as? String,
            let data = raw.data(using: .utf8)
        else { return nil }
        return try? ProtocolCoding.decode(JSONValue.self, from: data)
    }

    public func setConfiguration(path: String, value: JSONValue, updatedBy: String) throws {
        var value = value
        if path == Self.modelConnectionPath, var object = value.objectValue {
            if let key = object["apiKey"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                try secrets.setSecret(key, for: Self.modelSecretAccount)
            }
            object["apiKey"] = .string("")
            value = .object(object)
        }
        let encoded = String(data: try ProtocolCoding.encode(value), encoding: .utf8) ?? "null"
        let now = Date().timeIntervalSince1970
        try database.execute("""
        INSERT INTO configurations(path, scope, value_json, revision, updated_at, updated_by)
        VALUES (?, 'user', ?, 1, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            value_json = excluded.value_json,
            revision = configurations.revision + 1,
            updated_at = excluded.updated_at,
            updated_by = excluded.updated_by;
        """, [path, encoded, now, updatedBy])
    }

    /// Configuration without secrets; useful for UI and display.
    public func modelConnection() throws -> ModelConnection? {
        guard
            let value = try configurationValue(Self.modelConnectionPath),
            let data = try? ProtocolCoding.encode(value)
        else { return nil }
        var connection = try? ProtocolCoding.decode(ModelConnection.self, from: data)
        connection?.apiKey = ""
        return connection
    }

    /// Configuration with the secret injected from the Keychain/file backend.
    public func resolvedModelConnection() throws -> ModelConnection? {
        guard var connection = try modelConnection() else { return nil }
        connection.apiKey = secrets.secret(for: Self.modelSecretAccount) ?? ""
        return connection
    }

    public func setModelConnection(_ connection: ModelConnection, updatedBy: String = Principal.localUser) throws {
        let key = connection.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            try secrets.setSecret(key, for: Self.modelSecretAccount)
        }
        try setConfiguration(path: Self.modelConnectionPath, value: .object([
            "baseURL": .string(connection.baseURL),
            "model": .string(connection.model),
            "temperature": .number(connection.temperature),
        ]), updatedBy: updatedBy)
    }

    /// Moves a legacy plaintext `apiKey` out of SQLite into the secret backend.
    private func migratePlaintextModelSecret() {
        guard
            let value = try? configurationValue(Self.modelConnectionPath),
            var object = value.objectValue,
            let key = object["apiKey"]?.stringValue,
            !key.isEmpty
        else { return }

        try? secrets.setSecret(key, for: Self.modelSecretAccount)
        object["apiKey"] = .string("")
        try? setConfiguration(path: Self.modelConnectionPath, value: .object(object), updatedBy: "migration")
        FileHandle.standardError.write(Data("lucasd: migrated plaintext model key to \(secrets.backend.rawValue) backend\n".utf8))
    }

    // MARK: - Sessions and turns

    public func createSession(title: String = "新对话") throws -> ChatSession {
        let session = ChatSession(title: title)
        try database.execute(
            "INSERT INTO sessions(id, title, created_at, updated_at) VALUES (?, ?, ?, ?);",
            [session.id, session.title, session.createdAt.timeIntervalSince1970, session.updatedAt.timeIntervalSince1970]
        )
        return session
    }

    public func listSessions(limit: Int = 50) throws -> [ChatSession] {
        try database.query(
            "SELECT id, title, created_at, updated_at FROM sessions ORDER BY updated_at DESC LIMIT ?;",
            [limit]
        ).compactMap { row in
            guard
                let id = row["id"] as? String,
                let title = row["title"] as? String,
                let createdAt = row["created_at"] as? Double,
                let updatedAt = row["updated_at"] as? Double
            else { return nil }
            return ChatSession(
                id: id,
                title: title,
                createdAt: Date(timeIntervalSince1970: createdAt),
                updatedAt: Date(timeIntervalSince1970: updatedAt)
            )
        }
    }

    public func session(_ id: String) throws -> ChatSession? {
        try database.query("SELECT id, title, created_at, updated_at FROM sessions WHERE id = ? LIMIT 1;", [id])
            .first.flatMap { row in
                guard
                    let id = row["id"] as? String,
                    let title = row["title"] as? String,
                    let createdAt = row["created_at"] as? Double,
                    let updatedAt = row["updated_at"] as? Double
                else { return nil }
                return ChatSession(
                    id: id,
                    title: title,
                    createdAt: Date(timeIntervalSince1970: createdAt),
                    updatedAt: Date(timeIntervalSince1970: updatedAt)
                )
            }
    }

    public func touchSession(_ id: String, title: String? = nil) throws {
        let now = Date().timeIntervalSince1970
        if let title {
            try database.execute("UPDATE sessions SET title = ?, updated_at = ? WHERE id = ?;", [title, now, id])
        } else {
            try database.execute("UPDATE sessions SET updated_at = ? WHERE id = ?;", [now, id])
        }
    }

    public func renameSession(_ id: String, title: String) throws {
        try touchSession(id, title: title)
    }

    public func appendTurn(_ turn: ChatTurn) throws {
        let toolCalls = String(data: try ProtocolCoding.encode(turn.toolCalls), encoding: .utf8) ?? "[]"
        let metadata: String?
        if let value = turn.metadata {
            metadata = String(data: try ProtocolCoding.encode(value), encoding: .utf8)
        } else {
            metadata = nil
        }
        try database.execute("""
        INSERT INTO turns(id, session_id, role, text, tool_calls_json, tool_call_id, tool_name, created_at, metadata_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            turn.id, turn.sessionID, turn.role.rawValue, turn.text, toolCalls,
            turn.toolCallID, turn.toolName, turn.createdAt.timeIntervalSince1970, metadata,
        ])
    }

    public func history(sessionID: String, limit: Int = 200) throws -> [ChatTurn] {
        let rows = try database.query("""
        SELECT id, session_id, role, text, tool_calls_json, tool_call_id, tool_name, created_at, metadata_json
        FROM turns WHERE session_id = ? ORDER BY created_at ASC, rowid ASC LIMIT ?;
        """, [sessionID, limit])

        return rows.compactMap { row in
            guard
                let id = row["id"] as? String,
                let sessionID = row["session_id"] as? String,
                let roleRaw = row["role"] as? String,
                let role = ChatRole(rawValue: roleRaw),
                let text = row["text"] as? String,
                let createdAt = row["created_at"] as? Double
            else { return nil }
            let calls: [ToolCall]
            if
                let raw = row["tool_calls_json"] as? String,
                let data = raw.data(using: .utf8),
                let decoded = try? ProtocolCoding.decode([ToolCall].self, from: data)
            {
                calls = decoded
            } else {
                calls = []
            }
            var metadata: JSONValue?
            if
                let raw = row["metadata_json"] as? String,
                let data = raw.data(using: .utf8)
            {
                metadata = try? ProtocolCoding.decode(JSONValue.self, from: data)
            }
            return ChatTurn(
                id: id,
                sessionID: sessionID,
                role: role,
                text: text,
                toolCalls: calls,
                toolCallID: row["tool_call_id"] as? String,
                toolName: row["tool_name"] as? String,
                createdAt: Date(timeIntervalSince1970: createdAt),
                metadata: metadata
            )
        }
    }

    // MARK: - Grants

    public func grants() throws -> [PermissionGrant] {
        try database.query("""
        SELECT id, principal, capability, resource_pattern, expires_at, revoked_at, constraints_json
        FROM permission_grants ORDER BY id;
        """).compactMap { row in
            guard
                let id = row["id"] as? String,
                let principal = row["principal"] as? String,
                let capability = row["capability"] as? String,
                let pattern = row["resource_pattern"] as? String
            else { return nil }
            return PermissionGrant(
                id: id,
                principal: principal,
                capability: capability,
                resourcePattern: pattern,
                expiresAt: (row["expires_at"] as? Double).map(Date.init(timeIntervalSince1970:)),
                revokedAt: (row["revoked_at"] as? Double).map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    public func insertGrant(_ grant: PermissionGrant) throws {
        try database.execute("""
        INSERT OR IGNORE INTO permission_grants(id, principal, capability, resource_pattern, expires_at, revoked_at, constraints_json)
        VALUES (?, ?, ?, ?, ?, ?, NULL);
        """, [
            grant.id, grant.principal, grant.capability, grant.resourcePattern,
            grant.expiresAt?.timeIntervalSince1970, grant.revokedAt?.timeIntervalSince1970,
        ])
    }

    public func matchingGrant(principal: String, capability: String, resource: String, at date: Date = Date()) throws -> PermissionGrant? {
        let grants = try grants().filter {
            $0.isActive(at: date)
                && $0.principal == principal
                && ($0.capability == capability || $0.capability == Capability.root)
                && GlobMatcher.matches(pattern: $0.resourcePattern, value: resource)
        }
        return grants.first
    }

    public func recordToolInvocation(
        sessionID: String?,
        tool: String,
        ok: Bool,
        durationMilliseconds: Double,
        arguments: JSONValue,
        output: JSONValue,
        error: String?
    ) throws {
        func encode(_ value: JSONValue) -> String {
            (try? JSONCoding.encodeToString(value)) ?? "null"
        }
        try database.execute("""
        INSERT INTO tool_invocations(id, session_id, tool, ok, duration_ms, arguments_json, output_json, error, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            UUID().uuidString, sessionID, tool, ok ? 1 : 0, durationMilliseconds,
            encode(arguments), encode(output), error, Date().timeIntervalSince1970,
        ])
    }

    public func statistics() throws -> (sessions: Int, turns: Int, tools: Int) {
        (
            try database.scalarInt("SELECT COUNT(*) FROM sessions;"),
            try database.scalarInt("SELECT COUNT(*) FROM turns;"),
            try database.scalarInt("SELECT COUNT(*) FROM tool_invocations;")
        )
    }
}

public enum JSONCoding {
    public static func encodeToString(_ value: JSONValue) throws -> String {
        String(data: try ProtocolCoding.encode(value), encoding: .utf8) ?? "null"
    }
}
