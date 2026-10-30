import Foundation
import JaplosProtocol

/// Record-table access (memories, tasks, alarms, knowledge, ledgers).
/// Split out of `KernelStore` so the main file stays navigable; the SQL for
/// tables with their own columns stays explicit, the uniform ones go through
/// `LedgerRepository`.
extension KernelStore {
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

    static func decodeRecordRow(
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
        try ledger.rows(
            table: "modules",
            select: ["id", "version", "enabled", "record_json"],
            orderBy: "id ASC",
            limit: limit
        ).compactMap { row in Self.decodeRecordRow(row, idKey: "id", extra: { r in
            [
                "version": .string((r["version"] as? String) ?? "0"),
                "enabled": .bool(((r["enabled"] as? Int64) ?? 0) != 0),
            ]
        })}
    }

    public func upsertModule(id: String, version: String, enabled: Bool, record: JSONValue) throws {
        try ledger.upsert(
            table: "modules",
            values: [
                "id": id,
                "version": version,
                "enabled": enabled ? 1 : 0,
                "record_json": try LedgerRepository.encode(record),
            ],
            update: ["version", "enabled", "record_json"]
        )
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
        ).compactMap(mapKnowledgeRow)
    }

    private func mapKnowledgeRow(_ row: [String: Any?]) -> JSONValue? {
        Self.decodeRecordRow(row, idKey: "id", extra: { r in
            [
                "title": .string((r["title"] as? String) ?? ""),
                "updatedAt": .string(ISO8601.string(from: Date(timeIntervalSince1970: (r["updated_at"] as? Double) ?? 0))),
            ]
        })
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
        let body = record["body"]?.stringValue ?? record["text"]?.stringValue ?? ""
        try syncKnowledgeFTS(id: id, title: title, body: body)
        try storeKnowledgeVector(id: id, title: title, body: body)
    }

    public func deleteKnowledgeDocument(id: String) throws {
        try database.execute("DELETE FROM knowledge_documents WHERE id = ?;", [id])
        try? database.execute("DELETE FROM knowledge_fts WHERE doc_id = ?;", [id])
        try? database.execute("DELETE FROM knowledge_vectors WHERE id = ?;", [id])
    }

    func syncKnowledgeFTS(id: String, title: String, body: String) throws {
        try database.execute("DELETE FROM knowledge_fts WHERE doc_id = ?;", [id])
        // Cap FTS body so the index stays lean.
        let capped = String(body.prefix(80_000))
        try database.execute(
            "INSERT INTO knowledge_fts(doc_id, title, body) VALUES (?, ?, ?);",
            [id, title, capped]
        )
    }

    func storeKnowledgeVector(id: String, title: String, body: String) throws {
        let text = title + "\n" + String(body.prefix(800))
        guard let vector = LocalEmbedding.vector(for: text), !vector.isEmpty else {
            try? database.execute("DELETE FROM knowledge_vectors WHERE id = ?;", [id])
            return
        }
        let record = JSONValue.object([
            "dim": .number(Double(vector.count)),
            "vector": .array(vector.map(JSONValue.number)),
        ])
        let encoded = String(data: try ProtocolCoding.encode(record), encoding: .utf8) ?? "{}"
        try database.execute("""
        INSERT INTO knowledge_vectors(id, updated_at, record_json)
        VALUES (?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            updated_at = excluded.updated_at,
            record_json = excluded.record_json;
        """, [id, Date().timeIntervalSince1970, encoded])
    }

    func knowledgeVectors(ids: [String]) throws -> [String: [Double]] {
        guard !ids.isEmpty else { return [:] }
        var result: [String: [Double]] = [:]
        var index = 0
        while index < ids.count {
            let slice = Array(ids[index..<min(index + 80, ids.count)])
            index += slice.count
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            let rows = try database.query(
                "SELECT id, record_json FROM knowledge_vectors WHERE id IN (\(placeholders));",
                slice
            )
            for row in rows {
                guard
                    let id = row["id"] as? String,
                    let raw = row["record_json"] as? String,
                    let data = raw.data(using: .utf8),
                    let record = try? ProtocolCoding.decode(JSONValue.self, from: data),
                    let nums = record["vector"]?.arrayValue?.compactMap(\.doubleValue),
                    !nums.isEmpty
                else { continue }
                result[id] = nums
            }
        }
        return result
    }


    /// One-shot: populate FTS from existing knowledge rows when the index is empty.
    func rebuildKnowledgeFTSIfEmpty() throws {
        let ftsCount = (try? database.scalarInt("SELECT COUNT(*) FROM knowledge_fts;")) ?? 0
        guard ftsCount == 0 else { return }
        let docs = try listKnowledgeDocuments(limit: 500)
        guard !docs.isEmpty else { return }
        for doc in docs {
            guard let obj = doc.objectValue else { continue }
            let id = obj["id"]?.stringValue ?? ""
            guard !id.isEmpty else { continue }
            let title = obj["title"]?.stringValue ?? ""
            let record = obj["record"]?.objectValue ?? [:]
            let body = record["body"]?.stringValue ?? record["text"]?.stringValue ?? ""
            try syncKnowledgeFTS(id: id, title: title, body: body)
        }
    }

    public func knowledgeDocument(id: String) throws -> JSONValue? {
        try database.query(
            "SELECT id, title, updated_at, record_json FROM knowledge_documents WHERE id = ? LIMIT 1;",
            [id]
        ).compactMap(mapKnowledgeRow).first
    }

    /// FTS recalls candidates first (including documents outside the recent window), then keyword and stored vectors rerank.
    public func searchKnowledgeDocuments(
        query: String,
        library: String? = nil,
        limit: Int = 8
    ) throws -> [JSONValue] {
        let lim = max(1, min(limit, 40))
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            return Array((try listKnowledgeDocuments(limit: lim)).prefix(lim))
        }

        let ftsIDs = (try? knowledgeFTSMatchIDs(query: q, limit: 80)) ?? []
        let ftsSet = Set(ftsIDs)
        let ftsBoost = Dictionary(uniqueKeysWithValues: ftsIDs.enumerated().map { ($0.element, 8 - min($0.offset, 7)) })

        var docs: [JSONValue] = []
        var seen = Set<String>()
        for id in ftsIDs {
            guard let doc = try knowledgeDocument(id: id) else { continue }
            let key = doc["id"]?.stringValue ?? id
            if seen.insert(key).inserted { docs.append(doc) }
        }
        for doc in try listKnowledgeDocuments(limit: 300) {
            let key = doc["id"]?.stringValue ?? ""
            if seen.insert(key).inserted { docs.append(doc) }
        }

        let storedVectors = (try? knowledgeVectors(ids: Array(seen))) ?? [:]
        let queryVector = LocalEmbedding.vector(for: q)
        let useEmbed = queryVector != nil

        struct Hit {
            var score: Double
            var doc: JSONValue
        }
        var hits: [Hit] = []
        hits.reserveCapacity(docs.count)

        for doc in docs {
            guard let obj = doc.objectValue else { continue }
            let record = obj["record"]?.objectValue ?? [:]
            let lib = record["library"]?.stringValue ?? "all"
            if let library, !library.isEmpty, library != "all", lib != library {
                continue
            }
            let id = obj["id"]?.stringValue ?? ""
            let title = obj["title"]?.stringValue ?? record["title"]?.stringValue ?? ""
            let body = record["body"]?.stringValue ?? record["text"]?.stringValue ?? ""
            let hay = title + "\n" + body
            let keyword = Double(Self.relevanceScore(haystack: hay, query: q))
            let fts = Double(ftsBoost[id] ?? 0)

            var semantic = 0.0
            if let qv = queryVector {
                let dv = storedVectors[id] ?? (ftsSet.contains(id) ? LocalEmbedding.vector(for: title + "\n" + String(body.prefix(800))) : nil)
                if let dv {
                    semantic = max(0, LocalEmbedding.cosineSimilarity(qv, dv)) * 20.0
                }
            }

            let score = keyword + fts + semantic
            if score <= 0 { continue }
            if keyword == 0 && fts == 0 && semantic < 8 { continue }
            hits.append(Hit(score: score, doc: doc))
        }

        // If embeddings unavailable and keyword miss everything, surface recent docs lightly.
        if hits.isEmpty && !useEmbed {
            return []
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(lim).map(\.doc))
    }

    /// Active retrieval backend label for tools / inject copy.
    public func knowledgeRetrievalBackend() -> String {
        if LocalEmbedding.isAvailable {
            return "hybrid:\(LocalEmbedding.backendName)+fts5+keyword"
        }
        return "fts5+keyword"
    }

    private func knowledgeFTSMatchIDs(query: String, limit: Int) throws -> [String] {
        // Build a conservative FTS query: quote multi-char tokens joined with OR.
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let tokens = query.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
            .prefix(8)
        guard !tokens.isEmpty else { return [] }
        let escaped = tokens.map { tok -> String in
            let safe = tok.replacingOccurrences(of: "\"", with: "")
            return "\"\(safe)\""
        }
        let match = escaped.joined(separator: " OR ")
        let rows = try database.query(
            """
            SELECT doc_id FROM knowledge_fts
            WHERE knowledge_fts MATCH ?
            LIMIT ?;
            """,
            [match, limit]
        )
        return rows.compactMap { $0["doc_id"] as? String }
    }

    /// Substring search over memory content.
    public func searchMemories(query: String, limit: Int = 12) throws -> [JSONValue] {
        let lim = max(1, min(limit, 50))
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = try listMemories(sessionID: nil, limit: 200)
        guard !q.isEmpty else { return Array(all.prefix(lim)) }
        let scored = all.compactMap { item -> (Int, JSONValue)? in
            let content = item["content"]?.stringValue ?? ""
            let score = Self.relevanceScore(haystack: content, query: q)
            guard score > 0 else { return nil }
            return (score, item)
        }
        .sorted { $0.0 > $1.0 }
        return Array(scored.prefix(lim).map(\.1))
    }

    /// Open agent tasks (not completed/cancelled) for follow-up nudges.
    public func listOpenAgentTasks(limit: Int = 8) throws -> [JSONValue] {
        let lim = max(1, min(limit, 40))
        let rows = try listAgentTasks(sessionID: nil, limit: 80)
        let open = rows.filter { item in
            let state = (item["state"]?.stringValue ?? "").lowercased()
            return state != "completed" && state != "done" && state != "cancelled" && state != "canceled"
        }
        return Array(open.prefix(lim))
    }

    private static func relevanceScore(haystack: String, query: String) -> Int {
        let h = haystack.lowercased()
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return 0 }
        var score = 0
        if h.contains(q) { score += 12 }
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        for token in q.components(separatedBy: separators) where token.count >= 2 {
            if h.contains(token.lowercased()) { score += 3 }
        }
        // CJK bigrams when no whitespace tokens scored
        if score == 0, q.count >= 2 {
            var i = q.startIndex
            while i < q.endIndex {
                let j = q.index(i, offsetBy: 2, limitedBy: q.endIndex) ?? q.endIndex
                if j > i {
                    let bi = String(q[i..<j])
                    if bi.count == 2, h.contains(bi) { score += 2 }
                }
                if j == q.endIndex { break }
                i = q.index(after: i)
            }
        }
        return score
    }

    // MARK: - Subscriptions

    public func listSubscriptions(limit: Int = 50) throws -> [JSONValue] {
        try ledger.rows(
            table: "subscriptions",
            select: ["id", "information_type", "active", "record_json"],
            orderBy: "information_type ASC, id ASC",
            limit: limit
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
        try ledger.upsert(
            table: "subscriptions",
            values: [
                "id": id,
                "information_type": informationType,
                "active": active ? 1 : 0,
                "record_json": try LedgerRepository.encode(record),
            ],
            update: ["information_type", "active", "record_json"]
        )
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
        try ledger.upsert(
            table: "deliveries",
            values: [
                "id": id,
                "subscription_id": subscriptionID,
                "revision_id": revisionID,
                "state": state,
                "record_json": try LedgerRepository.encode(record),
            ],
            update: ["subscription_id", "revision_id", "state", "record_json"]
        )
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
        try ledger.upsert(
            table: "situations",
            values: [
                "id": id,
                "updated_at": Date().timeIntervalSince1970,
                "record_json": try LedgerRepository.encode(record),
            ],
            update: ["updated_at", "record_json"]
        )
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

    /// Whitelisted simplified ledgers (Japlos agent_runtime_* / knowledge / tool packages).
    public static let runtimeLedgerTables: [String] = [
        "tool_package_publishers",
        "task_plans",
        "scheduled_work",
        "run_attempts",
        "runtime_tools",
        "tool_projects",
        "tool_source_revisions",
        "tool_incidents",
        "tool_packages",
        "tool_package_installations",
        "primary_sessions",
        "memory_embeddings",
        "memory_recognition_jobs",
        "speech_replies",
        "task_privacy",
        "task_desktop_only",
        "mcp_event_cursors",
        "knowledge_chunks",
        "knowledge_terms",
        "knowledge_vectors",
        "knowledge_libraries",
        "knowledge_library_documents",
        "knowledge_import_receipts",
        "knowledge_import_library_receipts",
        "knowledge_library_migrations",
        "knowledge_deletions",
        "knowledge_deletion_aliases",
        "feishu_messages",
    ]

    public static func isRuntimeLedgerTable(_ name: String) -> Bool {
        runtimeLedgerTables.contains(name)
    }

    public func listRuntimeLedger(table: String, limit: Int = 50) throws -> [JSONValue] {
        guard Self.isRuntimeLedgerTable(table) else {
            throw KernelStoreError.invalidArgument("unknown ledger table \(table)")
        }
        return try ledger.rows(
            table: table,
            select: ["id", "updated_at", "record_json"],
            orderBy: "updated_at DESC",
            limit: limit
        ).compactMap { row in Self.decodeRecordRow(row, idKey: "id", extra: { r in
            [
                "table": .string(table),
                "updatedAt": .string(ISO8601.string(from: Date(timeIntervalSince1970: (r["updated_at"] as? Double) ?? 0))),
            ]
        })}
    }

    public func upsertRuntimeLedger(table: String, id: String?, record: JSONValue) throws -> String {
        guard Self.isRuntimeLedgerTable(table) else {
            throw KernelStoreError.invalidArgument("unknown ledger table \(table)")
        }
        let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rowID = trimmed.isEmpty ? UUID().uuidString : trimmed
        try ledger.upsert(
            table: table,
            values: [
                "id": rowID,
                "updated_at": Date().timeIntervalSince1970,
                "record_json": try LedgerRepository.encode(record),
            ],
            update: ["updated_at", "record_json"]
        )
        return rowID
    }

    public func deleteRuntimeLedger(table: String, id: String) throws {
        guard Self.isRuntimeLedgerTable(table) else {
            throw KernelStoreError.invalidArgument("unknown ledger table \(table)")
        }
        try ledger.delete(table: table, id: id)
    }

    /// Row counts for every known lucas.store table (demo / parity).
    public func tableCounts() throws -> [String: Int] {
        var tables = [
            "metadata", "configurations", "sessions", "turns", "permission_grants",
            "tool_invocations", "configuration_history", "custom_model_routes", "speech_profiles",
            "memories", "agent_tasks", "alarms", "mcp_events", "modules", "runs",
            "knowledge_documents", "knowledge_fts", "subscriptions", "context_snapshots", "cancellations",
            "capability_delegations", "information_revisions", "generated_tool_artifacts",
            "persistence_migrations", "information_types", "information_heads",
            "information_processors", "deliveries", "situations", "self_healing_events",
            "wechat_connections",
        ]
        tables.append(contentsOf: Self.runtimeLedgerTables)
        var result: [String: Int] = [:]
        for table in tables {
            result[table] = try database.scalarInt("SELECT COUNT(*) FROM \(table);")
        }
        return result
    }
}
