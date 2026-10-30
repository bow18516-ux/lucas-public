import Foundation
import JaplosProtocol

public final class KernelStore {
    public static let modelConnectionPath = "agents.default.model.connection"
    public static let modelSecretAccount = "agents.default.model.connection"
    public static let speechVolcengineAppIDAccount = "speech.volcengine.appId"
    public static let speechVolcengineTokenAccount = "speech.volcengine.token"

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
        try database.execute("""
        CREATE TABLE IF NOT EXISTS configuration_history (
            scope TEXT NOT NULL,
            path TEXT NOT NULL,
            revision INTEGER NOT NULL,
            record_json TEXT NOT NULL,
            PRIMARY KEY(scope, path, revision)
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS custom_model_routes (
            route_id TEXT PRIMARY KEY NOT NULL,
            revision INTEGER NOT NULL,
            created_at REAL NOT NULL,
            created_by TEXT NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS speech_profiles (
            profile_id TEXT PRIMARY KEY NOT NULL,
            provider_id TEXT NOT NULL,
            is_default INTEGER NOT NULL,
            revision INTEGER NOT NULL,
            updated_at REAL NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS memories (
            id TEXT PRIMARY KEY NOT NULL,
            session_id TEXT,
            kind TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at REAL NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_memories_session_time ON memories(session_id, created_at);")
        try database.execute("""
        CREATE TABLE IF NOT EXISTS agent_tasks (
            id TEXT PRIMARY KEY NOT NULL,
            session_id TEXT,
            title TEXT NOT NULL,
            state TEXT NOT NULL,
            updated_at REAL NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_agent_tasks_updated ON agent_tasks(updated_at);")
        try database.execute("""
        CREATE TABLE IF NOT EXISTS alarms (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            fire_at REAL NOT NULL,
            enabled INTEGER NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_alarms_fire ON alarms(fire_at);")
        try database.execute("""
        CREATE TABLE IF NOT EXISTS mcp_events (
            id TEXT PRIMARY KEY NOT NULL,
            server_id TEXT NOT NULL,
            event TEXT NOT NULL,
            created_at REAL NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_mcp_events_time ON mcp_events(created_at);")
        try database.execute("""
        CREATE TABLE IF NOT EXISTS modules (
            id TEXT PRIMARY KEY NOT NULL,
            version TEXT NOT NULL,
            enabled INTEGER NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS runs (
            id TEXT PRIMARY KEY NOT NULL,
            agent_id TEXT NOT NULL,
            state TEXT NOT NULL,
            updated_at REAL NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_runs_state ON runs(state, updated_at DESC);")
        try database.execute("""
        CREATE TABLE IF NOT EXISTS knowledge_documents (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            updated_at REAL NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_knowledge_documents_updated ON knowledge_documents(updated_at DESC);")
        try database.execute("""
        CREATE TABLE IF NOT EXISTS subscriptions (
            id TEXT PRIMARY KEY NOT NULL,
            information_type TEXT NOT NULL,
            active INTEGER NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_subscriptions_type ON subscriptions(information_type, active);")

        try database.execute("""
        CREATE TABLE IF NOT EXISTS context_snapshots (
            id TEXT PRIMARY KEY NOT NULL,
            agent_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_context_snapshots_time ON context_snapshots(created_at DESC);")
        try database.execute("""
        CREATE TABLE IF NOT EXISTS cancellations (
            cancellation_id TEXT PRIMARY KEY NOT NULL,
            request_id TEXT NOT NULL,
            state TEXT NOT NULL,
            requested_at REAL NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_cancellations_requested ON cancellations(requested_at DESC);")
        try database.execute("""
        CREATE TABLE IF NOT EXISTS capability_delegations (
            id TEXT PRIMARY KEY NOT NULL,
            request_id TEXT NOT NULL,
            delegatee TEXT NOT NULL,
            expires_at REAL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_capability_delegations_expires ON capability_delegations(expires_at);")
        try database.execute("""
        CREATE TABLE IF NOT EXISTS information_revisions (
            revision_id TEXT PRIMARY KEY NOT NULL,
            information_id TEXT NOT NULL,
            type TEXT NOT NULL,
            namespace TEXT NOT NULL,
            owner TEXT NOT NULL,
            observed_at REAL NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_information_revisions_observed ON information_revisions(observed_at DESC);")
        try database.execute("""
        CREATE TABLE IF NOT EXISTS generated_tool_artifacts (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL,
            enabled INTEGER NOT NULL,
            built_at REAL NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_generated_tool_artifacts_built ON generated_tool_artifacts(built_at DESC);")

        try database.execute("""
        CREATE TABLE IF NOT EXISTS information_types (
            type_id TEXT NOT NULL,
            schema_version INTEGER NOT NULL,
            record_json TEXT NOT NULL,
            PRIMARY KEY(type_id, schema_version)
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS information_heads (
            information_id TEXT PRIMARY KEY NOT NULL,
            revision_id TEXT NOT NULL
        );
        """)
        try database.execute("""
        CREATE TABLE IF NOT EXISTS information_processors (
            id TEXT PRIMARY KEY NOT NULL,
            module_id TEXT NOT NULL,
            capability TEXT NOT NULL,
            priority INTEGER NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_information_processors_priority ON information_processors(priority DESC, module_id);")
        try database.execute("""
        CREATE TABLE IF NOT EXISTS deliveries (
            id TEXT PRIMARY KEY NOT NULL,
            subscription_id TEXT NOT NULL,
            revision_id TEXT NOT NULL,
            state TEXT NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_deliveries_subscription ON deliveries(subscription_id, state);")
        try database.execute("""
        CREATE TABLE IF NOT EXISTS situations (
            id TEXT PRIMARY KEY NOT NULL,
            updated_at REAL NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_situations_updated ON situations(updated_at DESC);")
        try database.execute("""
        CREATE TABLE IF NOT EXISTS self_healing_events (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            created_at REAL NOT NULL,
            record_json TEXT NOT NULL
        );
        """)
        try database.execute("CREATE INDEX IF NOT EXISTS idx_self_healing_events_time ON self_healing_events(created_at DESC);")

        try database.execute("""
        CREATE TABLE IF NOT EXISTS persistence_migrations (
            namespace TEXT NOT NULL,
            version INTEGER NOT NULL,
            applied_at REAL NOT NULL,
            PRIMARY KEY(namespace, version)
        );
        """)
        try recordPersistenceMigration(namespace: "lucas.store", version: 2)
        try recordPersistenceMigration(namespace: "lucas.store", version: 3)
        try recordPersistenceMigration(namespace: "lucas.store", version: 4)
        try recordPersistenceMigration(namespace: "lucas.store", version: 5)
    }

    private func recordPersistenceMigration(namespace: String, version: Int) throws {
        let rows = try database.query(
            "SELECT version FROM persistence_migrations WHERE namespace = ? AND version = ? LIMIT 1;",
            [namespace, version]
        )
        if rows.isEmpty {
            try database.execute(
                "INSERT INTO persistence_migrations(namespace, version, applied_at) VALUES (?, ?, ?);",
                [namespace, version, Date().timeIntervalSince1970]
            )
        }
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

        let revisionRows = try database.query(
            "SELECT revision FROM configurations WHERE path = ? LIMIT 1;",
            [path]
        )
        let revision = (revisionRows.first?["revision"] as? Int64) ?? 1
        let record = JSONValue.object([
            "path": .string(path),
            "revision": .number(Double(revision)),
            "scope": .string("user"),
            "updatedAt": .string(ISO8601.string(from: Date(timeIntervalSince1970: now))),
            "updatedBy": .string(updatedBy),
            "value": value,
        ])
        let recordJSON = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        try database.execute("""
        INSERT OR REPLACE INTO configuration_history(scope, path, revision, record_json)
        VALUES ('user', ?, ?, ?);
        """, [path, revision, recordJSON])
    }

    public func configurationHistory(path: String? = nil, limit: Int = 50) throws -> [JSONValue] {
        let rows: [[String: Any?]]
        if let path {
            rows = try database.query(
                """
                SELECT scope, path, revision, record_json FROM configuration_history
                WHERE path = ? ORDER BY revision DESC LIMIT ?;
                """,
                [path, limit]
            )
        } else {
            rows = try database.query(
                """
                SELECT scope, path, revision, record_json FROM configuration_history
                ORDER BY path ASC, revision DESC LIMIT ?;
                """,
                [limit]
            )
        }
        return rows.compactMap { row in
            guard
                let recordJSON = row["record_json"] as? String,
                let data = recordJSON.data(using: .utf8),
                let value = try? ProtocolCoding.decode(JSONValue.self, from: data)
            else { return nil }
            return value
        }
    }

    public func listCustomModelRoutes() throws -> [JSONValue] {
        try database.query(
            "SELECT route_id, revision, created_at, created_by, record_json FROM custom_model_routes ORDER BY created_at DESC;"
        ).compactMap { row in
            guard
                let routeID = row["route_id"] as? String,
                let revision = row["revision"] as? Int64,
                let createdAt = row["created_at"] as? Double,
                let createdBy = row["created_by"] as? String,
                let recordJSON = row["record_json"] as? String,
                let data = recordJSON.data(using: .utf8),
                let record = try? ProtocolCoding.decode(JSONValue.self, from: data)
            else { return nil }
            return .object([
                "routeID": .string(routeID),
                "revision": .number(Double(revision)),
                "createdAt": .string(ISO8601.string(from: Date(timeIntervalSince1970: createdAt))),
                "createdBy": .string(createdBy),
                "record": record,
            ])
        }
    }

    public func upsertCustomModelRoute(
        routeID: String,
        record: JSONValue,
        createdBy: String = Principal.localUser
    ) throws {
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        let now = Date().timeIntervalSince1970
        try database.execute("""
        INSERT INTO custom_model_routes(route_id, revision, created_at, created_by, record_json)
        VALUES (?, 1, ?, ?, ?)
        ON CONFLICT(route_id) DO UPDATE SET
            revision = custom_model_routes.revision + 1,
            record_json = excluded.record_json,
            created_by = excluded.created_by;
        """, [routeID, now, createdBy, encoded])
    }

    public func deleteCustomModelRoute(routeID: String) throws {
        try database.execute("DELETE FROM custom_model_routes WHERE route_id = ?;", [routeID])
    }

    public func listSpeechProfiles() throws -> [JSONValue] {
        try database.query(
            "SELECT profile_id, provider_id, is_default, revision, updated_at, record_json FROM speech_profiles ORDER BY is_default DESC, updated_at DESC;"
        ).compactMap { row in
            guard
                let profileID = row["profile_id"] as? String,
                let providerID = row["provider_id"] as? String,
                let isDefault = row["is_default"] as? Int64,
                let revision = row["revision"] as? Int64,
                let updatedAt = row["updated_at"] as? Double,
                let recordJSON = row["record_json"] as? String,
                let data = recordJSON.data(using: .utf8),
                let record = try? ProtocolCoding.decode(JSONValue.self, from: data)
            else { return nil }
            var sanitized = record
            if var object = sanitized.objectValue {
                object["volcengineToken"] = .string("")
                object["volcengineAppID"] = .string("")
                object["volcengineTokenConfigured"] = .bool(secrets.secret(for: Self.speechVolcengineTokenAccount) != nil)
                object["volcengineAppIDConfigured"] = .bool(secrets.secret(for: Self.speechVolcengineAppIDAccount) != nil)
                sanitized = .object(object)
            }
            return .object([
                "profileID": .string(profileID),
                "providerID": .string(providerID),
                "isDefault": .bool(isDefault != 0),
                "revision": .number(Double(revision)),
                "updatedAt": .string(ISO8601.string(from: Date(timeIntervalSince1970: updatedAt))),
                "record": sanitized,
            ])
        }
    }

    public func upsertSpeechProfile(
        profileID: String,
        providerID: String,
        isDefault: Bool,
        record: JSONValue
    ) throws {
        var sanitized = record
        if var object = sanitized.objectValue {
            if let appID = object["volcengineAppID"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !appID.isEmpty {
                try secrets.setSecret(appID, for: Self.speechVolcengineAppIDAccount)
            }
            if let token = object["volcengineToken"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty {
                try secrets.setSecret(token, for: Self.speechVolcengineTokenAccount)
            }
            // Never persist raw credentials in SQLite.
            object["volcengineToken"] = .string("")
            object["volcengineAppID"] = .string("")
            object["volcengineTokenConfigured"] = .bool(secrets.secret(for: Self.speechVolcengineTokenAccount) != nil)
            object["volcengineAppIDConfigured"] = .bool(secrets.secret(for: Self.speechVolcengineAppIDAccount) != nil)
            sanitized = .object(object)
        }
        let encoded = String(data: try ProtocolCoding.encode(sanitized), encoding: .utf8) ?? "{}"
        let now = Date().timeIntervalSince1970
        if isDefault {
            try database.execute("UPDATE speech_profiles SET is_default = 0;")
        }
        try database.execute("""
        INSERT INTO speech_profiles(profile_id, provider_id, is_default, revision, updated_at, record_json)
        VALUES (?, ?, ?, 1, ?, ?)
        ON CONFLICT(profile_id) DO UPDATE SET
            provider_id = excluded.provider_id,
            is_default = excluded.is_default,
            revision = speech_profiles.revision + 1,
            updated_at = excluded.updated_at,
            record_json = excluded.record_json;
        """, [profileID, providerID, isDefault ? 1 : 0, now, encoded])
    }

    public func resolvedVolcengineCredentials() -> (appID: String, token: String)? {
        let appID = secrets.secret(for: Self.speechVolcengineAppIDAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = secrets.secret(for: Self.speechVolcengineTokenAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !appID.isEmpty, !token.isEmpty else { return nil }
        return (appID, token)
    }

    public func defaultSpeechProfile() throws -> JSONValue? {
        try listSpeechProfiles().first { $0["isDefault"]?.boolValue == true } ?? listSpeechProfiles().first
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
            "displayName": .string(connection.displayName),
        ]), updatedBy: updatedBy)

        let routeID = "custom.default"
        let record = JSONValue.object([
            "protocolKind": .string("openai.chat.completions"),
            "profile": .object([
                "id": .string(routeID),
                "adapter": .string("openai.chat.completions"),
                "baseURL": .string(connection.baseURL),
                "displayName": .string(connection.displayName),
                "credential": .string("store://" + Self.modelSecretAccount),
                "models": .array([.string(connection.model)]),
                "prefersStreaming": .bool(true),
                "executionLocation": .string("remote"),
                "temperature": .number(connection.temperature),
                "version": .string("1.0.0"),
            ]),
        ])
        try upsertCustomModelRoute(routeID: routeID, record: record, createdBy: updatedBy)
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


    // MARK: - Memories

    public func listMemories(sessionID: String? = nil, limit: Int = 50) throws -> [JSONValue] {
        let rows: [[String: Any?]]
        if let sessionID {
            rows = try database.query(
                """
                SELECT id, session_id, kind, content, created_at, record_json FROM memories
                WHERE session_id = ? ORDER BY created_at DESC LIMIT ?;
                """,
                [sessionID, limit]
            )
        } else {
            rows = try database.query(
                """
                SELECT id, session_id, kind, content, created_at, record_json FROM memories
                ORDER BY created_at DESC LIMIT ?;
                """,
                [limit]
            )
        }
        return rows.compactMap { row in Self.decodeRecordRow(row, idKey: "id", extra: { r in
            [
                "sessionID": .string((r["session_id"] as? String) ?? ""),
                "kind": .string((r["kind"] as? String) ?? "note"),
                "content": .string((r["content"] as? String) ?? ""),
                "createdAt": .string(ISO8601.string(from: Date(timeIntervalSince1970: (r["created_at"] as? Double) ?? 0))),
            ]
        })}
    }

    public func upsertMemory(
        id: String,
        sessionID: String?,
        kind: String,
        content: String,
        record: JSONValue
    ) throws {
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        let now = Date().timeIntervalSince1970
        try database.execute("""
        INSERT INTO memories(id, session_id, kind, content, created_at, record_json)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            session_id = excluded.session_id,
            kind = excluded.kind,
            content = excluded.content,
            record_json = excluded.record_json;
        """, [id, sessionID, kind, content, now, encoded])
    }

    public func deleteMemory(id: String) throws {
        try database.execute("DELETE FROM memories WHERE id = ?;", [id])
    }

    // MARK: - Agent tasks

    public func listAgentTasks(sessionID: String? = nil, limit: Int = 50) throws -> [JSONValue] {
        let rows: [[String: Any?]]
        if let sessionID {
            rows = try database.query(
                """
                SELECT id, session_id, title, state, updated_at, record_json FROM agent_tasks
                WHERE session_id = ? ORDER BY updated_at DESC LIMIT ?;
                """,
                [sessionID, limit]
            )
        } else {
            rows = try database.query(
                """
                SELECT id, session_id, title, state, updated_at, record_json FROM agent_tasks
                ORDER BY updated_at DESC LIMIT ?;
                """,
                [limit]
            )
        }
        return rows.compactMap { row in Self.decodeRecordRow(row, idKey: "id", extra: { r in
            [
                "sessionID": .string((r["session_id"] as? String) ?? ""),
                "title": .string((r["title"] as? String) ?? ""),
                "state": .string((r["state"] as? String) ?? "unknown"),
                "updatedAt": .string(ISO8601.string(from: Date(timeIntervalSince1970: (r["updated_at"] as? Double) ?? 0))),
            ]
        })}
    }

    public func upsertAgentTask(
        id: String,
        sessionID: String?,
        title: String,
        state: String,
        record: JSONValue
    ) throws {
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        let now = Date().timeIntervalSince1970
        try database.execute("""
        INSERT INTO agent_tasks(id, session_id, title, state, updated_at, record_json)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            session_id = excluded.session_id,
            title = excluded.title,
            state = excluded.state,
            updated_at = excluded.updated_at,
            record_json = excluded.record_json;
        """, [id, sessionID, title, state, now, encoded])
    }

    public func deleteAgentTask(id: String) throws {
        try database.execute("DELETE FROM agent_tasks WHERE id = ?;", [id])
    }

    // MARK: - Alarms

    public func listAlarms(limit: Int = 50) throws -> [JSONValue] {
        try database.query(
            "SELECT id, title, fire_at, enabled, record_json FROM alarms ORDER BY fire_at ASC LIMIT ?;",
            [limit]
        ).compactMap { row in Self.decodeRecordRow(row, idKey: "id", extra: { r in
            [
                "title": .string((r["title"] as? String) ?? ""),
                "fireAt": .string(ISO8601.string(from: Date(timeIntervalSince1970: (r["fire_at"] as? Double) ?? 0))),
                "enabled": .bool(((r["enabled"] as? Int64) ?? 0) != 0),
            ]
        })}
    }

    public func upsertAlarm(
        id: String,
        title: String,
        fireAt: Date,
        enabled: Bool,
        record: JSONValue
    ) throws {
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        try database.execute("""
        INSERT INTO alarms(id, title, fire_at, enabled, record_json)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            fire_at = excluded.fire_at,
            enabled = excluded.enabled,
            record_json = excluded.record_json;
        """, [id, title, fireAt.timeIntervalSince1970, enabled ? 1 : 0, encoded])
    }

    public func deleteAlarm(id: String) throws {
        try database.execute("DELETE FROM alarms WHERE id = ?;", [id])
    }

    // MARK: - MCP events

    public func listMCPEvents(serverID: String? = nil, limit: Int = 100) throws -> [JSONValue] {
        let rows: [[String: Any?]]
        if let serverID {
            rows = try database.query(
                """
                SELECT id, server_id, event, created_at, record_json FROM mcp_events
                WHERE server_id = ? ORDER BY created_at DESC LIMIT ?;
                """,
                [serverID, limit]
            )
        } else {
            rows = try database.query(
                """
                SELECT id, server_id, event, created_at, record_json FROM mcp_events
                ORDER BY created_at DESC LIMIT ?;
                """,
                [limit]
            )
        }
        return rows.compactMap { row in Self.decodeRecordRow(row, idKey: "id", extra: { r in
            [
                "serverID": .string((r["server_id"] as? String) ?? ""),
                "event": .string((r["event"] as? String) ?? ""),
                "createdAt": .string(ISO8601.string(from: Date(timeIntervalSince1970: (r["created_at"] as? Double) ?? 0))),
            ]
        })}
    }

    public func appendMCPEvent(
        id: String = UUID().uuidString,
        serverID: String,
        event: String,
        record: JSONValue = .object([:])
    ) throws {
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        try database.execute("""
        INSERT INTO mcp_events(id, server_id, event, created_at, record_json)
        VALUES (?, ?, ?, ?, ?);
        """, [id, serverID, event, Date().timeIntervalSince1970, encoded])
    }

    private static func decodeRecordRow(
        _ row: [String: Any?],
        idKey: String,
        extra: ([String: Any?]) -> [String: JSONValue]
    ) -> JSONValue? {
        guard
            let id = row[idKey] as? String,
            let recordJSON = row["record_json"] as? String,
            let data = recordJSON.data(using: .utf8),
            let record = try? ProtocolCoding.decode(JSONValue.self, from: data)
        else { return nil }
        var object = extra(row)
        object["id"] = .string(id)
        object["record"] = record
        return .object(object)
    }


    // MARK: - Modules

    public func listModules(limit: Int = 100) throws -> [JSONValue] {
        try database.query(
            "SELECT id, version, enabled, record_json FROM modules ORDER BY id ASC LIMIT ?;",
            [limit]
        ).compactMap { row in Self.decodeRecordRow(row, idKey: "id", extra: { r in
            [
                "version": .string((r["version"] as? String) ?? "0"),
                "enabled": .bool(((r["enabled"] as? Int64) ?? 0) != 0),
            ]
        })}
    }

    public func upsertModule(id: String, version: String, enabled: Bool, record: JSONValue) throws {
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        try database.execute("""
        INSERT INTO modules(id, version, enabled, record_json)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            version = excluded.version,
            enabled = excluded.enabled,
            record_json = excluded.record_json;
        """, [id, version, enabled ? 1 : 0, encoded])
    }

    // MARK: - Runs

    public func listRuns(agentID: String? = nil, limit: Int = 50) throws -> [JSONValue] {
        let rows: [[String: Any?]]
        if let agentID {
            rows = try database.query(
                """
                SELECT id, agent_id, state, updated_at, record_json FROM runs
                WHERE agent_id = ? ORDER BY updated_at DESC LIMIT ?;
                """,
                [agentID, limit]
            )
        } else {
            rows = try database.query(
                """
                SELECT id, agent_id, state, updated_at, record_json FROM runs
                ORDER BY updated_at DESC LIMIT ?;
                """,
                [limit]
            )
        }
        return rows.compactMap { row in Self.decodeRecordRow(row, idKey: "id", extra: { r in
            [
                "agentID": .string((r["agent_id"] as? String) ?? ""),
                "state": .string((r["state"] as? String) ?? "unknown"),
                "updatedAt": .string(ISO8601.string(from: Date(timeIntervalSince1970: (r["updated_at"] as? Double) ?? 0))),
            ]
        })}
    }

    public func upsertRun(
        id: String,
        agentID: String,
        state: String,
        record: JSONValue
    ) throws {
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        let now = Date().timeIntervalSince1970
        try database.execute("""
        INSERT INTO runs(id, agent_id, state, updated_at, record_json)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            agent_id = excluded.agent_id,
            state = excluded.state,
            updated_at = excluded.updated_at,
            record_json = excluded.record_json;
        """, [id, agentID, state, now, encoded])
    }

    // MARK: - Knowledge documents

    public func listKnowledgeDocuments(limit: Int = 50) throws -> [JSONValue] {
        try database.query(
            "SELECT id, title, updated_at, record_json FROM knowledge_documents ORDER BY updated_at DESC LIMIT ?;",
            [limit]
        ).compactMap { row in Self.decodeRecordRow(row, idKey: "id", extra: { r in
            [
                "title": .string((r["title"] as? String) ?? ""),
                "updatedAt": .string(ISO8601.string(from: Date(timeIntervalSince1970: (r["updated_at"] as? Double) ?? 0))),
            ]
        })}
    }

    public func upsertKnowledgeDocument(id: String, title: String, record: JSONValue) throws {
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        let now = Date().timeIntervalSince1970
        try database.execute("""
        INSERT INTO knowledge_documents(id, title, updated_at, record_json)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            updated_at = excluded.updated_at,
            record_json = excluded.record_json;
        """, [id, title, now, encoded])
    }

    public func deleteKnowledgeDocument(id: String) throws {
        try database.execute("DELETE FROM knowledge_documents WHERE id = ?;", [id])
    }

    // MARK: - Subscriptions

    public func listSubscriptions(limit: Int = 50) throws -> [JSONValue] {
        try database.query(
            "SELECT id, information_type, active, record_json FROM subscriptions ORDER BY information_type ASC, id ASC LIMIT ?;",
            [limit]
        ).compactMap { row in Self.decodeRecordRow(row, idKey: "id", extra: { r in
            [
                "informationType": .string((r["information_type"] as? String) ?? ""),
                "active": .bool(((r["active"] as? Int64) ?? 0) != 0),
            ]
        })}
    }

    public func upsertSubscription(
        id: String,
        informationType: String,
        active: Bool,
        record: JSONValue
    ) throws {
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        try database.execute("""
        INSERT INTO subscriptions(id, information_type, active, record_json)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            information_type = excluded.information_type,
            active = excluded.active,
            record_json = excluded.record_json;
        """, [id, informationType, active ? 1 : 0, encoded])
    }


    // MARK: - Context snapshots

    public func listContextSnapshots(agentID: String? = nil, limit: Int = 50) throws -> [JSONValue] {
        let rows: [[String: Any?]]
        if let agentID {
            rows = try database.query(
                """
                SELECT id, agent_id, created_at, record_json FROM context_snapshots
                WHERE agent_id = ? ORDER BY created_at DESC LIMIT ?;
                """,
                [agentID, limit]
            )
        } else {
            rows = try database.query(
                """
                SELECT id, agent_id, created_at, record_json FROM context_snapshots
                ORDER BY created_at DESC LIMIT ?;
                """,
                [limit]
            )
        }
        return rows.compactMap { row in Self.decodeRecordRow(row, idKey: "id", extra: { r in
            [
                "agentID": .string((r["agent_id"] as? String) ?? ""),
                "createdAt": .string(ISO8601.string(from: Date(timeIntervalSince1970: (r["created_at"] as? Double) ?? 0))),
            ]
        })}
    }

    public func upsertContextSnapshot(id: String, agentID: String, record: JSONValue) throws {
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        let now = Date().timeIntervalSince1970
        try database.execute("""
        INSERT INTO context_snapshots(id, agent_id, created_at, record_json)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            agent_id = excluded.agent_id,
            created_at = excluded.created_at,
            record_json = excluded.record_json;
        """, [id, agentID, now, encoded])
    }

    // MARK: - Cancellations

    public func listCancellations(limit: Int = 50) throws -> [JSONValue] {
        try database.query(
            """
            SELECT cancellation_id, request_id, state, requested_at, record_json FROM cancellations
            ORDER BY requested_at DESC LIMIT ?;
            """,
            [limit]
        ).compactMap { row in Self.decodeRecordRow(row, idKey: "cancellation_id", extra: { r in
            [
                "cancellationID": .string((r["cancellation_id"] as? String) ?? ""),
                "requestID": .string((r["request_id"] as? String) ?? ""),
                "state": .string((r["state"] as? String) ?? "unknown"),
                "requestedAt": .string(ISO8601.string(from: Date(timeIntervalSince1970: (r["requested_at"] as? Double) ?? 0))),
            ]
        })}
    }

    public func upsertCancellation(
        cancellationID: String,
        requestID: String,
        state: String,
        record: JSONValue
    ) throws {
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        let now = Date().timeIntervalSince1970
        try database.execute("""
        INSERT INTO cancellations(cancellation_id, request_id, state, requested_at, record_json)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(cancellation_id) DO UPDATE SET
            request_id = excluded.request_id,
            state = excluded.state,
            requested_at = excluded.requested_at,
            record_json = excluded.record_json;
        """, [cancellationID, requestID, state, now, encoded])
    }

    // MARK: - Capability delegations

    public func listCapabilityDelegations(limit: Int = 50) throws -> [JSONValue] {
        try database.query(
            """
            SELECT id, request_id, delegatee, expires_at, record_json FROM capability_delegations
            ORDER BY (expires_at IS NULL) ASC, expires_at DESC LIMIT ?;
            """,
            [limit]
        ).compactMap { row in Self.decodeRecordRow(row, idKey: "id", extra: { r in
            var extra: [String: JSONValue] = [
                "requestID": .string((r["request_id"] as? String) ?? ""),
                "delegatee": .string((r["delegatee"] as? String) ?? ""),
            ]
            if let expires = r["expires_at"] as? Double {
                extra["expiresAt"] = .string(ISO8601.string(from: Date(timeIntervalSince1970: expires)))
            }
            return extra
        })}
    }

    public func upsertCapabilityDelegation(
        id: String,
        requestID: String,
        delegatee: String,
        expiresAt: Date?,
        record: JSONValue
    ) throws {
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        try database.execute("""
        INSERT INTO capability_delegations(id, request_id, delegatee, expires_at, record_json)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            request_id = excluded.request_id,
            delegatee = excluded.delegatee,
            expires_at = excluded.expires_at,
            record_json = excluded.record_json;
        """, [id, requestID, delegatee, expiresAt?.timeIntervalSince1970, encoded])
    }

    // MARK: - Information revisions

    public func listInformationRevisions(informationID: String? = nil, limit: Int = 50) throws -> [JSONValue] {
        let rows: [[String: Any?]]
        if let informationID {
            rows = try database.query(
                """
                SELECT revision_id, information_id, type, namespace, owner, observed_at, record_json
                FROM information_revisions
                WHERE information_id = ? ORDER BY observed_at DESC LIMIT ?;
                """,
                [informationID, limit]
            )
        } else {
            rows = try database.query(
                """
                SELECT revision_id, information_id, type, namespace, owner, observed_at, record_json
                FROM information_revisions
                ORDER BY observed_at DESC LIMIT ?;
                """,
                [limit]
            )
        }
        return rows.compactMap { row in Self.decodeRecordRow(row, idKey: "revision_id", extra: { r in
            [
                "revisionID": .string((r["revision_id"] as? String) ?? ""),
                "informationID": .string((r["information_id"] as? String) ?? ""),
                "type": .string((r["type"] as? String) ?? ""),
                "namespace": .string((r["namespace"] as? String) ?? ""),
                "owner": .string((r["owner"] as? String) ?? ""),
                "observedAt": .string(ISO8601.string(from: Date(timeIntervalSince1970: (r["observed_at"] as? Double) ?? 0))),
            ]
        })}
    }

    public func upsertInformationRevision(
        revisionID: String,
        informationID: String,
        type: String,
        namespace: String,
        owner: String,
        observedAt: Date,
        record: JSONValue
    ) throws {
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        try database.execute("""
        INSERT INTO information_revisions(revision_id, information_id, type, namespace, owner, observed_at, record_json)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(revision_id) DO UPDATE SET
            information_id = excluded.information_id,
            type = excluded.type,
            namespace = excluded.namespace,
            owner = excluded.owner,
            observed_at = excluded.observed_at,
            record_json = excluded.record_json;
        """, [revisionID, informationID, type, namespace, owner, observedAt.timeIntervalSince1970, encoded])
    }

    // MARK: - Generated tool artifacts

    public func listToolArtifacts(projectID: String? = nil, limit: Int = 50) throws -> [JSONValue] {
        let rows: [[String: Any?]]
        if let projectID {
            rows = try database.query(
                """
                SELECT id, project_id, enabled, built_at, record_json FROM generated_tool_artifacts
                WHERE project_id = ? ORDER BY built_at DESC LIMIT ?;
                """,
                [projectID, limit]
            )
        } else {
            rows = try database.query(
                """
                SELECT id, project_id, enabled, built_at, record_json FROM generated_tool_artifacts
                ORDER BY built_at DESC LIMIT ?;
                """,
                [limit]
            )
        }
        return rows.compactMap { row in Self.decodeRecordRow(row, idKey: "id", extra: { r in
            [
                "projectID": .string((r["project_id"] as? String) ?? ""),
                "enabled": .bool(((r["enabled"] as? Int64) ?? 0) != 0),
                "builtAt": .string(ISO8601.string(from: Date(timeIntervalSince1970: (r["built_at"] as? Double) ?? 0))),
            ]
        })}
    }

    public func upsertToolArtifact(
        id: String,
        projectID: String,
        enabled: Bool,
        builtAt: Date,
        record: JSONValue
    ) throws {
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        try database.execute("""
        INSERT INTO generated_tool_artifacts(id, project_id, enabled, built_at, record_json)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            project_id = excluded.project_id,
            enabled = excluded.enabled,
            built_at = excluded.built_at,
            record_json = excluded.record_json;
        """, [id, projectID, enabled ? 1 : 0, builtAt.timeIntervalSince1970, encoded])
    }

    // MARK: - Information types

    public func listInformationTypes(limit: Int = 100) throws -> [JSONValue] {
        try database.query(
            """
            SELECT type_id, schema_version, record_json FROM information_types
            ORDER BY type_id ASC, schema_version DESC LIMIT ?;
            """,
            [limit]
        ).compactMap { row -> JSONValue? in
            guard
                let typeID = row["type_id"] as? String,
                let schemaVersion = row["schema_version"] as? Int64,
                let recordJSON = row["record_json"] as? String,
                let data = recordJSON.data(using: .utf8),
                let record = try? ProtocolCoding.decode(JSONValue.self, from: data)
            else { return nil }
            return .object([
                "typeID": .string(typeID),
                "schemaVersion": .number(Double(schemaVersion)),
                "record": record,
            ])
        }
    }

    public func upsertInformationType(typeID: String, schemaVersion: Int, record: JSONValue) throws {
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        try database.execute("""
        INSERT INTO information_types(type_id, schema_version, record_json)
        VALUES (?, ?, ?)
        ON CONFLICT(type_id, schema_version) DO UPDATE SET
            record_json = excluded.record_json;
        """, [typeID, schemaVersion, encoded])
    }

    // MARK: - Information heads

    public func listInformationHeads(limit: Int = 100) throws -> [JSONValue] {
        try database.query(
            "SELECT information_id, revision_id FROM information_heads ORDER BY information_id ASC LIMIT ?;",
            [limit]
        ).compactMap { row -> JSONValue? in
            guard let informationID = row["information_id"] as? String,
                  let revisionID = row["revision_id"] as? String else { return nil }
            return .object([
                "informationID": .string(informationID),
                "revisionID": .string(revisionID),
            ])
        }
    }

    public func setInformationHead(informationID: String, revisionID: String) throws {
        try database.execute("""
        INSERT INTO information_heads(information_id, revision_id)
        VALUES (?, ?)
        ON CONFLICT(information_id) DO UPDATE SET
            revision_id = excluded.revision_id;
        """, [informationID, revisionID])
    }

    // MARK: - Information processors

    public func listInformationProcessors(limit: Int = 100) throws -> [JSONValue] {
        try database.query(
            """
            SELECT id, module_id, capability, priority, record_json FROM information_processors
            ORDER BY priority DESC, module_id ASC LIMIT ?;
            """,
            [limit]
        ).compactMap { row in Self.decodeRecordRow(row, idKey: "id", extra: { r in
            [
                "moduleID": .string((r["module_id"] as? String) ?? ""),
                "capability": .string((r["capability"] as? String) ?? ""),
                "priority": .number(Double((r["priority"] as? Int64) ?? 0)),
            ]
        })}
    }

    public func upsertInformationProcessor(
        id: String,
        moduleID: String,
        capability: String,
        priority: Int,
        record: JSONValue
    ) throws {
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        try database.execute("""
        INSERT INTO information_processors(id, module_id, capability, priority, record_json)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            module_id = excluded.module_id,
            capability = excluded.capability,
            priority = excluded.priority,
            record_json = excluded.record_json;
        """, [id, moduleID, capability, priority, encoded])
    }

    // MARK: - Deliveries

    public func listDeliveries(subscriptionID: String? = nil, limit: Int = 50) throws -> [JSONValue] {
        let rows: [[String: Any?]]
        if let subscriptionID {
            rows = try database.query(
                """
                SELECT id, subscription_id, revision_id, state, record_json FROM deliveries
                WHERE subscription_id = ? ORDER BY id ASC LIMIT ?;
                """,
                [subscriptionID, limit]
            )
        } else {
            rows = try database.query(
                """
                SELECT id, subscription_id, revision_id, state, record_json FROM deliveries
                ORDER BY id ASC LIMIT ?;
                """,
                [limit]
            )
        }
        return rows.compactMap { row in Self.decodeRecordRow(row, idKey: "id", extra: { r in
            [
                "subscriptionID": .string((r["subscription_id"] as? String) ?? ""),
                "revisionID": .string((r["revision_id"] as? String) ?? ""),
                "state": .string((r["state"] as? String) ?? "unknown"),
            ]
        })}
    }

    public func upsertDelivery(
        id: String,
        subscriptionID: String,
        revisionID: String,
        state: String,
        record: JSONValue
    ) throws {
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        try database.execute("""
        INSERT INTO deliveries(id, subscription_id, revision_id, state, record_json)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            subscription_id = excluded.subscription_id,
            revision_id = excluded.revision_id,
            state = excluded.state,
            record_json = excluded.record_json;
        """, [id, subscriptionID, revisionID, state, encoded])
    }

    // MARK: - Situations

    public func listSituations(limit: Int = 50) throws -> [JSONValue] {
        try database.query(
            "SELECT id, updated_at, record_json FROM situations ORDER BY updated_at DESC LIMIT ?;",
            [limit]
        ).compactMap { row in Self.decodeRecordRow(row, idKey: "id", extra: { r in
            [
                "updatedAt": .string(ISO8601.string(from: Date(timeIntervalSince1970: (r["updated_at"] as? Double) ?? 0))),
            ]
        })}
    }

    public func upsertSituation(id: String, record: JSONValue) throws {
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        let now = Date().timeIntervalSince1970
        try database.execute("""
        INSERT INTO situations(id, updated_at, record_json)
        VALUES (?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            updated_at = excluded.updated_at,
            record_json = excluded.record_json;
        """, [id, now, encoded])
    }

    // MARK: - Self-healing events

    public func listSelfHealingEvents(limit: Int = 50) throws -> [JSONValue] {
        try database.query(
            """
            SELECT id, kind, created_at, record_json FROM self_healing_events
            ORDER BY created_at DESC LIMIT ?;
            """,
            [limit]
        ).compactMap { row in Self.decodeRecordRow(row, idKey: "id", extra: { r in
            [
                "kind": .string((r["kind"] as? String) ?? ""),
                "createdAt": .string(ISO8601.string(from: Date(timeIntervalSince1970: (r["created_at"] as? Double) ?? 0))),
            ]
        })}
    }

    public func appendSelfHealingEvent(id: String? = nil, kind: String, record: JSONValue = .object([:])) throws {
        let eventID = (id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? id!.trimmingCharacters(in: .whitespacesAndNewlines)
            : UUID().uuidString
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        let now = Date().timeIntervalSince1970
        try database.execute("""
        INSERT INTO self_healing_events(id, kind, created_at, record_json)
        VALUES (?, ?, ?, ?);
        """, [eventID, kind, now, encoded])
    }

    public func statistics() throws -> (sessions: Int, turns: Int, tools: Int) {
        (
            try database.scalarInt("SELECT COUNT(*) FROM sessions;"),
            try database.scalarInt("SELECT COUNT(*) FROM turns;"),
            try database.scalarInt("SELECT COUNT(*) FROM tool_invocations;")
        )
    }

    /// Row counts for every known lucas.store table (demo / parity).
    public func tableCounts() throws -> [String: Int] {
        let tables = [
            "metadata", "configurations", "sessions", "turns", "permission_grants",
            "tool_invocations", "configuration_history", "custom_model_routes", "speech_profiles",
            "memories", "agent_tasks", "alarms", "mcp_events", "modules", "runs",
            "knowledge_documents", "subscriptions", "context_snapshots", "cancellations",
            "capability_delegations", "information_revisions", "generated_tool_artifacts",
            "persistence_migrations", "information_types", "information_heads",
            "information_processors", "deliveries", "situations", "self_healing_events",
        ]
        var result: [String: Int] = [:]
        for table in tables {
            result[table] = try database.scalarInt("SELECT COUNT(*) FROM \(table);")
        }
        return result
    }
}

public enum JSONCoding {
    public static func encodeToString(_ value: JSONValue) throws -> String {
        String(data: try ProtocolCoding.encode(value), encoding: .utf8) ?? "null"
    }
}
