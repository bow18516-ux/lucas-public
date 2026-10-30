import Combine
import Foundation
import JaplosProtocol
import JaplosClient
import PDFKit
import AppKit

@MainActor
extension AppModel {
    // MARK: - Memory / knowledge backup

    /// Export memories + knowledge_documents + KnowledgeFiles into a dated folder under `parent`.
    @discardableResult
    func exportMemoryKnowledgeBackup(toParent parent: URL) async -> String {
        let accessed = parent.startAccessingSecurityScopedResource()
        defer { if accessed { parent.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let stamp = MemoryKnowledgeBackup.makeExportDirectoryName()
        let root = parent.appendingPathComponent(stamp, isDirectory: true)
        let filesOut = root.appendingPathComponent(MemoryKnowledgeBackup.filesDirName, isDirectory: true)

        do {
            try fm.createDirectory(at: filesOut, withIntermediateDirectories: true)

            // --- Memories (full slice, preserve ids) ---
            let memResult = try await client.callAsync(.memoryList, arguments: .object([
                "limit": .number(2_000),
            ]))
            let memories = memResult.arrayValue ?? []

            // --- Knowledge documents ---
            let knowResult = try await client.callAsync(.knowledgeDocumentsList, arguments: .object([
                "limit": .number(500),
            ]))
            let docs = knowResult.arrayValue ?? []

            var exportedDocs: [JSONValue] = []
            var filesCopied = 0
            for doc in docs {
                guard var obj = doc.objectValue else {
                    exportedDocs.append(doc)
                    continue
                }
                let id = obj["id"]?.stringValue ?? UUID().uuidString
                var record = obj["record"]?.objectValue ?? [:]
                let sourcePath = record["sourcePath"]?.stringValue ?? obj["sourcePath"]?.stringValue ?? ""

                if !sourcePath.isEmpty, fm.fileExists(atPath: sourcePath) {
                    let src = URL(fileURLWithPath: sourcePath)
                    let destDir = filesOut.appendingPathComponent(id, isDirectory: true)
                    try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                    let dest = destDir.appendingPathComponent(src.lastPathComponent)
                    if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                    do {
                        try fm.copyItem(at: src, to: dest)
                        let rel = "\(MemoryKnowledgeBackup.filesDirName)/\(id)/\(src.lastPathComponent)"
                        record["backupFile"] = .string(rel)
                        obj["backupFile"] = .string(rel)
                        filesCopied += 1
                    } catch {
                        // Keep metadata even if file copy fails.
                    }
                }
                obj["record"] = .object(record)
                exportedDocs.append(.object(obj))
            }

            // Also mirror any leftover files under local KnowledgeFiles not tied to a doc.
            let localFiles = MemoryKnowledgeBackup.localKnowledgeFilesRoot
            if fm.fileExists(atPath: localFiles.path),
               let orphanURLs = try? fm.contentsOfDirectory(at: localFiles, includingPropertiesForKeys: nil) {
                let orphanDir = filesOut.appendingPathComponent("_orphan", isDirectory: true)
                for item in orphanURLs {
                    // Skip if already copied under a doc id folder with same filename somewhere — best-effort copy.
                    let dest = orphanDir.appendingPathComponent(item.lastPathComponent)
                    if fm.fileExists(atPath: dest.path) { continue }
                    // Only copy if no exported doc referenced this absolute path.
                    let abs = item.path
                    let already = docs.contains { d in
                        let sp = d["record"]?["sourcePath"]?.stringValue ?? d["sourcePath"]?.stringValue ?? ""
                        return sp == abs
                    }
                    if already { continue }
                    try? fm.createDirectory(at: orphanDir, withIntermediateDirectories: true)
                    try? fm.copyItem(at: item, to: dest)
                    if fm.fileExists(atPath: dest.path) { filesCopied += 1 }
                }
            }

            try MemoryKnowledgeBackup.writeJSON(.array(memories), to: root.appendingPathComponent(MemoryKnowledgeBackup.memoriesName))
            try MemoryKnowledgeBackup.writeJSON(.array(exportedDocs), to: root.appendingPathComponent(MemoryKnowledgeBackup.knowledgeName))

            let manifest: JSONValue = .object([
                "format": .string(MemoryKnowledgeBackup.formatID),
                "exportedAt": .string(ISO8601.string(from: Date())),
                "app": .string("Lucas"),
                "counts": .object([
                    "memories": .number(Double(memories.count)),
                    "knowledgeDocuments": .number(Double(exportedDocs.count)),
                    "files": .number(Double(filesCopied)),
                ]),
                "folder": .string(stamp),
            ])
            try MemoryKnowledgeBackup.writeJSON(manifest, to: root.appendingPathComponent(MemoryKnowledgeBackup.manifestName))

            await loadMemories(limit: 100, scopedToCurrentSession: false)
            await loadKnowledgeDocuments()
            AppLog.write("backup.export ok path=\(root.path) memories=\(memories.count) docs=\(exportedDocs.count) files=\(filesCopied)")
            return "已导出到 \(stamp)：记忆 \(memories.count)，知识 \(exportedDocs.count)，文件 \(filesCopied)"
        } catch {
            let msg = (error as? ClientError)?.description ?? String(describing: error)
            AppLog.write("backup.export failed: \(msg)")
            return "导出失败：\(msg)"
        }
    }

    /// Import a lucas.memory-knowledge.v1 folder (merge / upsert by id). Round-trip safe.
    @discardableResult
    func importMemoryKnowledgeBackup(from picked: URL) async -> String {
        let accessed = picked.startAccessingSecurityScopedResource()
        defer { if accessed { picked.stopAccessingSecurityScopedResource() } }

        guard let root = MemoryKnowledgeBackup.resolveBackupRoot(picked) else {
            return "未找到有效备份（需要包含 manifest.json）"
        }

        let fm = FileManager.default
        do {
            let manifest = try MemoryKnowledgeBackup.readJSON(from: root.appendingPathComponent(MemoryKnowledgeBackup.manifestName))
            let format = manifest["format"]?.stringValue ?? ""
            guard format == MemoryKnowledgeBackup.formatID else {
                return "备份格式不支持：\(format.isEmpty ? "未知" : format)"
            }

            let memoriesURL = root.appendingPathComponent(MemoryKnowledgeBackup.memoriesName)
            let knowledgeURL = root.appendingPathComponent(MemoryKnowledgeBackup.knowledgeName)
            let memories = (try? MemoryKnowledgeBackup.readJSON(from: memoriesURL).arrayValue) ?? []
            let docs = (try? MemoryKnowledgeBackup.readJSON(from: knowledgeURL).arrayValue) ?? []

            var memOK = 0
            for item in memories {
                guard let content = item["content"]?.stringValue, !content.isEmpty else { continue }
                let id = item["id"]?.stringValue ?? UUID().uuidString
                var args: [String: JSONValue] = [
                    "id": .string(id),
                    "content": .string(content),
                    "kind": .string(item["kind"]?.stringValue ?? "note"),
                ]
                if let sessionID = item["sessionID"]?.stringValue, !sessionID.isEmpty {
                    args["sessionID"] = .string(sessionID)
                }
                if let record = item["record"] {
                    args["record"] = record
                } else {
                    args["record"] = .object([
                        "content": .string(content),
                        "kind": .string(item["kind"]?.stringValue ?? "note"),
                        "source": .string("backup.import"),
                    ])
                }
                _ = try await client.callAsync(.memoryUpsert, arguments: .object(args))
                memOK += 1
            }

            let destRoot = MemoryKnowledgeBackup.localKnowledgeFilesRoot
            try? fm.createDirectory(at: destRoot, withIntermediateDirectories: true)
            let backupFilesRoot = root.appendingPathComponent(MemoryKnowledgeBackup.filesDirName, isDirectory: true)

            var docOK = 0
            var filesOK = 0
            for item in docs {
                guard let title = item["title"]?.stringValue ?? item["record"]?["title"]?.stringValue,
                      !title.isEmpty else { continue }
                let id = item["id"]?.stringValue ?? UUID().uuidString
                var record = item["record"]?.objectValue ?? [:]
                record["title"] = .string(title)
                if record["body"] == nil, let body = item["body"]?.stringValue {
                    record["body"] = .string(body)
                }
                let body = record["body"]?.stringValue ?? ""
                let library = record["library"]?.stringValue ?? "all"
                let fileType = record["fileType"]?.stringValue ?? "note"
                let extractStatus = record["extractStatus"]?.stringValue ?? "ok"
                let extractNote = record["extractNote"]?.stringValue ?? ""

                // Restore file copy if present.
                let rel = item["backupFile"]?.stringValue ?? record["backupFile"]?.stringValue
                var restoredPath = ""
                if let rel, !rel.isEmpty {
                    let src = root.appendingPathComponent(rel)
                    if fm.fileExists(atPath: src.path) {
                        let destDir = destRoot.appendingPathComponent(id, isDirectory: true)
                        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                        let dest = destDir.appendingPathComponent(src.lastPathComponent)
                        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                        do {
                            try fm.copyItem(at: src, to: dest)
                            restoredPath = dest.path
                            filesOK += 1
                        } catch {
                            // Fall through — body still restores.
                        }
                    }
                }
                if restoredPath.isEmpty {
                    // Try orphan / legacy absolute path inside backup KnowledgeFiles.
                    let old = record["sourcePath"]?.stringValue ?? ""
                    if old.contains("/KnowledgeFiles/") {
                        let name = URL(fileURLWithPath: old).lastPathComponent
                        let candidates = [
                            backupFilesRoot.appendingPathComponent(id).appendingPathComponent(name),
                            backupFilesRoot.appendingPathComponent("_orphan").appendingPathComponent(name),
                            backupFilesRoot.appendingPathComponent(name),
                        ]
                        for cand in candidates where fm.fileExists(atPath: cand.path) {
                            let destDir = destRoot.appendingPathComponent(id, isDirectory: true)
                            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                            let dest = destDir.appendingPathComponent(name)
                            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                            if (try? fm.copyItem(at: cand, to: dest)) != nil {
                                restoredPath = dest.path
                                filesOK += 1
                                break
                            }
                        }
                    }
                }
                if !restoredPath.isEmpty {
                    record["sourcePath"] = .string(restoredPath)
                }
                var cleanRecord = record
                cleanRecord.removeValue(forKey: "backupFile")

                var args: [String: JSONValue] = [
                    "id": .string(id),
                    "title": .string(title),
                    "body": .string(body),
                    "library": .string(library),
                    "fileType": .string(fileType),
                    "extractStatus": .string(extractStatus),
                    "record": .object(cleanRecord),
                ]
                if !extractNote.isEmpty { args["extractNote"] = .string(extractNote) }
                if !restoredPath.isEmpty { args["sourcePath"] = .string(restoredPath) }
                _ = try await client.callAsync(.knowledgeDocumentsUpsert, arguments: .object(args))
                docOK += 1
            }

            // Copy any remaining backup KnowledgeFiles tree (best-effort merge).
            if fm.fileExists(atPath: backupFilesRoot.path),
               let enumerator = fm.enumerator(at: backupFilesRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
                while let item = enumerator.nextObject() as? URL {
                    let values = try? item.resourceValues(forKeys: [.isRegularFileKey])
                    guard values?.isRegularFile == true else { continue }
                    let rel = item.path.replacingOccurrences(of: backupFilesRoot.path + "/", with: "")
                    guard !rel.isEmpty, rel != item.path else { continue }
                    let dest = destRoot.appendingPathComponent(rel)
                    try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !fm.fileExists(atPath: dest.path) {
                        try? fm.copyItem(at: item, to: dest)
                    }
                }
            }

            await loadMemories(limit: 100, scopedToCurrentSession: false)
            await loadKnowledgeDocuments()
            AppLog.write("backup.import ok memories=\(memOK) docs=\(docOK) files=\(filesOK)")
            return "导入完成：记忆 \(memOK)，知识 \(docOK)，文件 \(filesOK)（按 id 合并，可再导出验证）"
        } catch {
            let msg = (error as? ClientError)?.description ?? String(describing: error)
            AppLog.write("backup.import failed: \(msg)")
            return "导入失败：\(msg)"
        }
    }


    func loadMCPEvents(limit: Int = 10) async {
        do {
            let result = try await client.callAsync(
                .mcpEventsList,
                arguments: .object(["limit": .number(Double(limit))])
            )
            mcpEvents = (result.arrayValue ?? []).compactMap { item in
                guard let id = item["id"]?.stringValue else { return nil }
                let created = item["createdAt"]?.stringValue.flatMap(ISO8601.date(from:)) ?? Date()
                return MCPEventItem(
                    id: id,
                    serverID: item["serverID"]?.stringValue ?? "",
                    event: item["event"]?.stringValue ?? "",
                    createdAt: created
                )
            }
        } catch {
            // Soft-fail.
        }
    }

    func loadStoreStats() async {
        do {
            let result = try await client.callAsync(.kernelStoreStats, arguments: .object([:]))
            let tables = result["tables"]?.objectValue ?? [:]
            storeTableCounts = tables.compactMap { key, value -> (name: String, count: Int)? in
                let count = value.intValue ?? value.doubleValue.map { Int($0) }
                guard let count else { return nil }
                return (name: key, count: count)
            }.sorted { $0.name < $1.name }

            let events = try await client.callAsync(
                .selfHealingEventsList,
                arguments: .object(["limit": .number(1)])
            )
            lastSelfHealingEvent = (events.arrayValue ?? []).compactMap { item -> SelfHealingEventSummary? in
                guard let id = item["id"]?.stringValue else { return nil }
                let created = item["createdAt"]?.stringValue.flatMap(ISO8601.date(from:)) ?? Date()
                let kind = item["kind"]?.stringValue ?? ""
                let detail = item["record"]?["storePath"]?.stringValue
                    ?? item["record"]?["socketPath"]?.stringValue
                    ?? item["record"]?["at"]?.stringValue
                    ?? ""
                return SelfHealingEventSummary(id: id, kind: kind, createdAt: created, detail: detail)
            }.first
        } catch {
            // Soft-fail when kernel offline.
        }
    }

    func recordCancellation(state: String) async {
        let session = currentSessionID ?? ""
        _ = try? await client.callAsync(.cancellationsUpsert, arguments: .object([
            "state": .string(state),
            "requestID": .string(UUID().uuidString),
            "record": .object([
                "sessionID": .string(session),
                "messageCount": .number(Double(messages.count)),
                "source": .string("app.stop"),
            ]),
        ]))
    }

    func snapshotContext(reason: String) async {
        guard let sessionID = currentSessionID else { return }
        let preview = messages.suffix(6).map { msg in
            JSONValue.object([
                "role": .string(msg.role),
                "text": .string(String(msg.text.prefix(160))),
            ])
        }
        _ = try? await client.callAsync(.contextSnapshotsUpsert, arguments: .object([
            "agentID": .string("default"),
            "record": .object([
                "reason": .string(reason),
                "sessionID": .string(sessionID),
                "messageCount": .number(Double(messages.count)),
                "preview": .array(Array(preview)),
            ]),
        ]))
    }


    func loadRecentTasks(limit: Int = 20) async {
        do {
            var args: [String: JSONValue] = ["limit": .number(Double(limit))]
            if let sessionID = currentSessionID {
                args["sessionID"] = .string(sessionID)
            }
            let result = try await client.callAsync(.agentTasksList, arguments: .object(args))
            recentTasks = (result.arrayValue ?? []).compactMap { item in
                guard
                    let id = item["id"]?.stringValue,
                    let title = item["title"]?.stringValue
                else { return nil }
                let updated = item["updatedAt"]?.stringValue.flatMap(ISO8601.date(from:)) ?? Date()
                return PersistedTask(
                    id: id,
                    title: title,
                    state: item["state"]?.stringValue ?? "completed",
                    sessionID: item["sessionID"]?.stringValue ?? "",
                    updatedAt: updated
                )
            }
        } catch {
            // Soft-fail: task panel still shows in-memory steps.
        }
    }

    /// Surfaces a one-shot banner when open agent_tasks exist (once per calendar day).
    /// Uses alarms when available so a soft follow-up fires later the same day.
    func considerUnfinishedNudge(reason: String) async {
        let dayKey = Self.calendarDayKey(for: Date())
        if UserDefaults.standard.string(forKey: Self.unfinishedNudgeDayKey) == dayKey {
            return
        }
        // Only nudge on empty chat surfaces (launch / new chat), not mid-thread.
        guard messages.isEmpty else { return }

        let open = await fetchOpenAgentTasks(limit: 6)
        guard !open.isEmpty else { return }

        let titles = open.map(\.title)
        let ids = open.map(\.id)
        unfinishedNudge = UnfinishedNudge(titles: titles, taskIDs: ids, dayKey: dayKey)
        UserDefaults.standard.set(dayKey, forKey: Self.unfinishedNudgeDayKey)
        AppLog.write("unfinishedNudge reason=\(reason) count=\(open.count)")

        await ensureUnfinishedAlarm(titles: titles)
    }

    func dismissUnfinishedNudge() {
        unfinishedNudge = nil
    }

    /// Prefills a continue prompt for the composer / send path.
    func continueUnfinishedNudgePrompt() -> String {
        guard let nudge = unfinishedNudge else {
            return "继续上次未完成的事项"
        }
        let listed = nudge.titles.prefix(3).map { "· \($0)" }.joined(separator: "\n")
        unfinishedNudge = nil
        return "继续这些未完成事项：\n\(listed)\n请先回顾进度，问我要从哪一项接着做。"
    }

    func fetchOpenAgentTasks(limit: Int) async -> [PersistedTask] {
        do {
            // No session filter — unfinished work across chats.
            let result = try await client.callAsync(.agentTasksList, arguments: .object([
                "limit": .number(80),
            ]))
            let all = (result.arrayValue ?? []).compactMap { item -> PersistedTask? in
                guard
                    let id = item["id"]?.stringValue,
                    let title = item["title"]?.stringValue
                else { return nil }
                let state = (item["state"]?.stringValue ?? "").lowercased()
                let terminal = ["completed", "done", "cancelled", "canceled"]
                guard !terminal.contains(state) else { return nil }
                let updated = item["updatedAt"]?.stringValue.flatMap(ISO8601.date(from:)) ?? Date()
                return PersistedTask(
                    id: id,
                    title: title,
                    state: item["state"]?.stringValue ?? "open",
                    sessionID: item["sessionID"]?.stringValue ?? "",
                    updatedAt: updated
                )
            }
            return Array(all.prefix(limit))
        } catch {
            return []
        }
    }

    func ensureUnfinishedAlarm(titles: [String]) async {
        // Skip if a same-day unfinished alarm already exists.
        let marker = "未完成事项"
        let already = alarms.contains { alarm in
            alarm.enabled && alarm.title.contains(marker) && Calendar.current.isDateInToday(alarm.fireAt)
        }
        guard !already else { return }
        let fire = Date().addingTimeInterval(2 * 60 * 60) // ~2h later
        let summary = titles.prefix(2).joined(separator: "、")
        let title = "\(marker)：\(summary)"
        await upsertAlarm(title: String(title.prefix(80)), fireAt: fire, enabled: true)
    }

    private static func calendarDayKey(for date: Date) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func persistAgentTask(sessionID: String, steps: [ToolStep], preview: String) async {
        let names = steps.map(\.name)
        let title: String
        if names.isEmpty {
            title = String(preview.prefix(48))
        } else if names.count == 1 {
            title = names[0]
        } else {
            title = "\(names[0]) +\(names.count - 1)"
        }
        let okCount = steps.filter(\.ok).count
        let record = JSONValue.object([
            "preview": .string(String(preview.prefix(160))),
            "steps": .array(steps.map { step in
                .object([
                    "name": .string(step.name),
                    "ok": .bool(step.ok),
                    "detail": .string(step.detail),
                ])
            }),
            "okCount": .number(Double(okCount)),
            "stepCount": .number(Double(steps.count)),
        ])
        _ = try? await client.callAsync(.agentTasksUpsert, arguments: .object([
            "id": .string(UUID().uuidString),
            "sessionID": .string(sessionID),
            "title": .string(title),
            "state": .string(okCount == steps.count ? "completed" : "partial"),
            "record": record,
        ]))
    }

    func refreshModels() async {
        do {
            let result = try await client.callAsync(.modelCatalog, arguments: .object([
                "baseURL": .string(settings.baseURL),
                "model": .string(settings.model),
                "apiKey": .string(settings.apiKey),
            ]), timeout: 45)
            availableModels = (result["models"]?.arrayValue ?? []).compactMap { $0.stringValue }
        } catch {
            availableModels = []
        }
    }

    func loadTools() async {
        do {
            let result = try await client.callAsync(.toolList, arguments: .object([:]))
            tools = (result.arrayValue ?? []).compactMap { item in
                guard let name = item["name"]?.stringValue else { return nil }
                let provider = item["provider"]?.stringValue ?? "kernel"
                return ToolSummary(
                    name: name,
                    title: item["title"]?.stringValue ?? "",
                    summary: item["summary"]?.stringValue ?? "",
                    capability: item["capability"]?.stringValue ?? "",
                    risk: item["risk"]?.stringValue ?? "low",
                    provider: provider
                )
            }.sorted { $0.name < $1.name }
        } catch {
            // Tool catalog is informational; keep the UI usable.
        }
    }
}
