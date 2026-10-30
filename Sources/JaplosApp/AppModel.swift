import Combine
import Foundation
import JaplosProtocol
import PDFKit
import AppKit

@MainActor
final class AppModel: ObservableObject {
    struct ToolStep: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var ok: Bool
        var detail: String
    }

    struct Message: Identifiable, Equatable {
        let id: UUID
        var role: String
        var text: String
        var steps: [ToolStep]
        var createdAt: Date

        init(id: UUID = UUID(), role: String, text: String, steps: [ToolStep] = [], createdAt: Date = Date()) {
            self.id = id
            self.role = role
            self.text = text
            self.steps = steps
            self.createdAt = createdAt
        }
    }

    struct Approval: Identifiable, Equatable {
        let id = UUID()
        var callID: String
        var name: String
        var title: String
        var summary: String
    }

    struct ToolSummary: Identifiable, Equatable {
        var name: String
        var title: String
        var summary: String = ""
        var capability: String = ""
        var risk: String
        var provider: String = "kernel"
        var id: String { name }

        var sourceLabel: String {
            if provider.lowercased().contains("mcp") || name.hasPrefix("mcp.") {
                return "MCP"
            }
            return "Kernel"
        }
    }

    struct SessionSummary: Identifiable, Equatable {
        var id: String
        var title: String
        var updatedAt: Date
    }

    @Published var sessions: [SessionSummary] = []
    @Published var currentSessionID: String?
    @Published var messages: [Message] = []
    @Published var isSending = false
    @Published var errorText: String?
    @Published var statusText = "正在连接内核…"
    @Published var connected = false
    @Published var settings = ModelConnection(baseURL: "https://api.deepseek.com/v1", model: "", apiKey: "")
    /// The stored key is never echoed back into the editable field.
    @Published var storedAPIKey: String = ""
    /// Whether the kernel actually has a saved model connection.
    @Published var hasStoredConnection = false
    @Published var tools: [ToolSummary] = []
    @Published var availableModels: [String] = []
    @Published var pendingApproval: Approval?
    @Published var settingsPresented = false
    @Published var onboardingPresented = false

    static let onboardingCompletedKey = "LucasOnboardingCompleted"
    static let onboardingSkippedKey = "LucasOnboardingSkipped"
    static let unfinishedNudgeDayKey = "LucasUnfinishedNudgeDay"
    @Published var isTestingModel = false
    @Published var testResult: String?
    @Published var memoryNotes: [MemoryNote] = []
    @Published var recentTasks: [PersistedTask] = []
    /// One-shot unfinished-task banner (cleared by dismiss / continue / day key).
    @Published var unfinishedNudge: UnfinishedNudge?
    @Published var alarms: [AlarmItem] = []
    @Published var knowledgeDocuments: [KnowledgeDocument] = []
    @Published var mcpEvents: [MCPEventItem] = []
    @Published var wechatStatus: JSONValue = .object([:])
    /// Settings → 通道 → 微信：「审批推送到微信」(default on).
    @Published var wechatApprovalPushEnabled: Bool = true
    @Published var feishuStatus: JSONValue = .object([:])
    @Published var mailStatus: JSONValue = .object([:])
    @Published var storeTableCounts: [(name: String, count: Int)] = []
    @Published var lastSelfHealingEvent: SelfHealingEventSummary?

    struct KnowledgeDocument: Identifiable, Equatable {
        var id: String
        var title: String
        var body: String
        var updatedAt: Date
        var library: String
        var fileType: String
        var extractStatus: String
        var extractNote: String
        var sourcePath: String
    }

    struct MCPEventItem: Identifiable, Equatable {
        var id: String
        var serverID: String
        var event: String
        var createdAt: Date
    }

    struct SelfHealingEventSummary: Equatable {
        var id: String
        var kind: String
        var createdAt: Date
        var detail: String
    }

    struct AlarmItem: Identifiable, Equatable {
        var id: String
        var title: String
        var fireAt: Date
        var enabled: Bool
    }

    struct MemoryNote: Identifiable, Equatable {
        var id: String
        var content: String
        var kind: String
        var sessionID: String
    }

    struct UnfinishedNudge: Equatable {
        var titles: [String]
        var taskIDs: [String]
        var dayKey: String
    }

    struct PersistedTask: Identifiable, Equatable {
        var id: String
        var title: String
        var state: String
        var sessionID: String
        var updatedAt: Date
    }

    let client: KernelClient
    let voice = SpeechOutput()
    private var sendTask: Task<Void, Never>?
    private var currentStream: ChatStream?

    init(socketPath: String = KernelClient.defaultSocketPath) {
        self.client = KernelClient(socketPath: socketPath)
    }

    // MARK: - Lifecycle

    private func migrateLegacyStoreIfNeeded() {
        guard ProcessInfo.processInfo.environment["LUCAS_CLONE_HOME"] == nil else { return }
        let fileManager = FileManager.default
        let newHome = KernelClient.homeDirectory
        let legacy = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/JaplosClone", isDirectory: true)
        guard
            !fileManager.fileExists(atPath: newHome.path),
            fileManager.fileExists(atPath: legacy.path)
        else { return }
        do {
            try fileManager.copyItem(at: legacy, to: newHome)
            AppLog.write("migrated legacy store from \(legacy.path) to \(newHome.path)")
        } catch {
            AppLog.write("legacy store migration failed: \(error)")
        }
    }

    func bootstrap() async {
        migrateLegacyStoreIfNeeded()
        AppLog.write("bootstrap start home=\(KernelClient.homeDirectory.path)")
        statusText = "正在连接内核…"
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Lucas/lucasd.log")
        do {
            try await Task.detached(priority: .userInitiated) { [client, logURL] in
                try DaemonController.ensureRunning(client: client, logURL: logURL)
            }.value
            connected = true
            statusText = "已连接"
            AppLog.write("bootstrap connected socket=\(client.socketPath)")
        } catch {
            connected = false
            statusText = "未连接"
            errorText = String(describing: error)
            AppLog.write("bootstrap failed: \(error)")
            return
        }

        await loadSettings()
        wireSpeechCloud()
        await loadSpeechProfile()
        presentOnboardingIfNeeded()
        await loadTools()
        await loadSessions()
        if currentSessionID == nil {
            await createSession()
        } else if let id = currentSessionID {
            await loadHistory(sessionID: id)
        }
        await loadMemories()
        await loadRecentTasks()
        await loadAlarms()
        await loadKnowledgeDocuments()
        await loadMCPEvents()
        await considerUnfinishedNudge(reason: "launch")
    }

    // MARK: - Sessions

    func loadSessions() async {
        do {
            let result = try await client.callAsync(.chatSessionsList, arguments: .object(["limit": .number(50)]))
            let list = (result.arrayValue ?? []).compactMap { item -> SessionSummary? in
                guard let id = item["id"]?.stringValue, let title = item["title"]?.stringValue else { return nil }
                let updated = item["updatedAt"]?.stringValue.flatMap(ISO8601.date(from:)) ?? Date()
                return SessionSummary(id: id, title: title, updatedAt: updated)
            }
            sessions = list
            if currentSessionID == nil { currentSessionID = list.first?.id }
        } catch {
            errorText = String(describing: error)
        }
    }

    func createSession() async {
        do {
            await snapshotContext(reason: "session_create")
            let result = try await client.callAsync(.chatSessionCreate, arguments: .object(["title": .string("新对话")]))
            guard let id = result["id"]?.stringValue else { return }
            currentSessionID = id
            messages = []
            await loadSessions()
            await loadMemories()
            await loadRecentTasks()
            await considerUnfinishedNudge(reason: "new_chat")
        } catch {
            errorText = String(describing: error)
        }
    }

    func selectSession(_ id: String) async {
        await snapshotContext(reason: "session_switch")
        currentSessionID = id
        messages = []
        await loadHistory(sessionID: id)
        await loadMemories()
        await loadRecentTasks()
    }

    func loadHistory(sessionID: String) async {
        do {
            let result = try await client.callAsync(
                .chatHistory,
                arguments: .object(["sessionID": .string(sessionID), "limit": .number(200)])
            )
            let turns = result.arrayValue ?? []
            messages = turns.compactMap { turn in
                guard
                    let role = turn["role"]?.stringValue,
                    role == "user" || role == "assistant",
                    let text = turn["text"]?.stringValue,
                    !text.isEmpty
                else { return nil }
                let created = turn["createdAt"]?.stringValue.flatMap(ISO8601.date(from:)) ?? Date()
                return Message(role: role, text: text, createdAt: created)
            }
        } catch {
            errorText = String(describing: error)
        }
    }

    // MARK: - Chat

    /// Starts a turn on a child task so `stop()` can cancel it.
    func send(_ text: String) {
        guard sendTask == nil else { return }
        sendTask = Task { [weak self] in
            await self?.performSend(text)
            self?.sendTask = nil
        }
    }

    func stop() {
        sendTask?.cancel()
        sendTask = nil
        currentStream = nil
        pendingApproval = nil
        isSending = false
        Task { await recordCancellation(state: "user_stop") }
    }

    func resolveApproval(_ approved: Bool) {
        guard let approval = pendingApproval else { return }
        currentStream?.approve(callID: approval.callID, approved: approved)
        pendingApproval = nil
    }

    private func performSend(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if currentSessionID == nil { await createSession() }
        guard let sessionID = currentSessionID else { return }

        isSending = true
        errorText = nil
        voice.stop()
        messages.append(Message(role: "user", text: trimmed))
        messages.append(Message(role: "assistant", text: ""))
        let index = messages.count - 1

        do {
            var finished = false
            let stream = client.streamChat(sessionID: sessionID, text: trimmed)
            currentStream = stream
            for try await event in stream.events {
                switch event["event"]?.stringValue {
                case "delta":
                    messages[index].text += event["text"]?.stringValue ?? ""
                case "tool":
                    messages[index].steps.append(ToolStep(
                        name: event["name"]?.stringValue ?? "tool",
                        ok: event["ok"]?.boolValue ?? false,
                        detail: String((event["detail"]?.stringValue ?? "").prefix(220))
                    ))
                case "approval":
                    pendingApproval = Approval(
                        callID: event["callID"]?.stringValue ?? "",
                        name: event["name"]?.stringValue ?? "tool",
                        title: event["title"]?.stringValue ?? "",
                        summary: AppModel.approvalSummary(event["arguments"])
                    )
                case "approvalResolved":
                    // WeChat / timeout / other channel settled — keep desktop card in sync.
                    let callID = event["callID"]?.stringValue ?? ""
                    if let pending = pendingApproval, callID.isEmpty || pending.callID == callID {
                        pendingApproval = nil
                    }
                case "done":
                    finished = true
                    if let finalText = event["text"]?.stringValue, !finalText.isEmpty {
                        messages[index].text = finalText
                    }
                    if let finalText = event["text"]?.stringValue, !finalText.isEmpty {
                        voice.speak(finalText)
                    }
                    if let stepArray = event["steps"]?.arrayValue, !stepArray.isEmpty {
                        messages[index].steps = stepArray.map { step in
                            let error = step["error"]?.stringValue ?? ""
                            let output = step["output"]
                            let path = output?["path"]?.stringValue
                            let track = output?["track"]?.stringValue
                            let detail: String
                            if !error.isEmpty {
                                detail = error
                            } else if let path, !path.isEmpty {
                                detail = path
                            } else if let track, !track.isEmpty {
                                let artist = output?["artist"]?.stringValue ?? ""
                                let state = output?["state"]?.stringValue ?? ""
                                detail = [state, track, artist].filter { !$0.isEmpty }.joined(separator: " · ")
                            } else {
                                detail = ""
                            }
                            return ToolStep(
                                name: step["tool"]?.stringValue ?? "tool",
                                ok: step["ok"]?.boolValue ?? false,
                                detail: String(detail.prefix(220))
                            )
                        }
                    }
                default:
                    break
                }
            }

            if Task.isCancelled {
                if messages[index].text.isEmpty {
                    messages[index].text = "（已停止）"
                } else {
                    messages[index].text += "\n\n（已停止）"
                }
            } else if !finished && messages[index].text.isEmpty {
                messages[index].text = "（内核提前结束了响应）"
            }
            await loadSessions()
        } catch is CancellationError {
            if messages[index].text.isEmpty {
                messages[index].text = "（已停止）"
            } else {
                messages[index].text += "\n\n（已停止）"
            }
        } catch {
            let message = (error as? ClientError)?.description ?? String(describing: error)
            if case .kernel(let failure) = error as? ClientError ?? .transport(""), failure.code == "model_not_configured" {
                let completed = UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
                let skipped = UserDefaults.standard.bool(forKey: Self.onboardingSkippedKey)
                if completed || skipped {
                    settingsPresented = true
                } else {
                    onboardingPresented = true
                }
            }
            errorText = message
            if messages[index].text.isEmpty {
                messages[index].text = "请求失败：\(message)"
            } else {
                messages[index].text += "\n\n（中断：\(message)）"
            }
        }
        if !messages[index].steps.isEmpty {
            await persistAgentTask(
                sessionID: sessionID,
                steps: messages[index].steps,
                preview: trimmed
            )
        }
        await loadMemories()
        await loadRecentTasks()
        isSending = false
    }

    /// - Parameter scopedToCurrentSession: when true (default), filter by `currentSessionID` if set.
    ///   Settings 「记忆」 pane passes false to list every persisted note.
    func loadMemories(limit: Int = 40, scopedToCurrentSession: Bool = true) async {
        do {
            var args: [String: JSONValue] = ["limit": .number(Double(limit))]
            if scopedToCurrentSession, let sessionID = currentSessionID {
                args["sessionID"] = .string(sessionID)
            }
            let result = try await client.callAsync(.memoryList, arguments: .object(args))
            memoryNotes = (result.arrayValue ?? []).compactMap { item in
                guard let id = item["id"]?.stringValue else { return nil }
                let content = item["content"]?.stringValue
                    ?? item["record"]?["content"]?.stringValue
                    ?? ""
                guard !content.isEmpty else { return nil }
                return MemoryNote(
                    id: id,
                    content: content,
                    kind: item["kind"]?.stringValue ?? "note",
                    sessionID: item["sessionID"]?.stringValue ?? ""
                )
            }
        } catch {
            // Soft-fail when kernel is offline.
        }
    }

    func rememberNote(_ content: String, reloadScopedToCurrentSession: Bool = true) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            var args: [String: JSONValue] = [
                "content": .string(trimmed),
                "kind": .string("note"),
            ]
            if let sessionID = currentSessionID {
                args["sessionID"] = .string(sessionID)
            }
            _ = try await client.callAsync(.memoryUpsert, arguments: .object(args))
            await loadMemories(scopedToCurrentSession: reloadScopedToCurrentSession)
        } catch {
            errorText = (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func deleteMemory(id: String, reloadScopedToCurrentSession: Bool = true) async {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await client.callAsync(.memoryDelete, arguments: .object(["id": .string(trimmed)]))
            await loadMemories(scopedToCurrentSession: reloadScopedToCurrentSession)
        } catch {
            errorText = (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func rememberLatestUserMessage() async {
        guard let last = messages.last(where: { $0.role == "user" }) else { return }
        await rememberNote(String(last.text.prefix(280)))
    }


    func loadKnowledgeDocuments(limit: Int = 80, library: String? = nil) async {
        do {
            var args: [String: JSONValue] = ["limit": .number(Double(limit))]
            if let library, !library.isEmpty, library != "all" {
                args["library"] = .string(library)
            }
            let result = try await client.callAsync(
                .knowledgeDocumentsList,
                arguments: .object(args)
            )
            knowledgeDocuments = (result.arrayValue ?? []).compactMap { item in
                guard let id = item["id"]?.stringValue else { return nil }
                let record = item["record"]
                let title = item["title"]?.stringValue ?? record?["title"]?.stringValue ?? ""
                let body = record?["body"]?.stringValue
                    ?? record?["text"]?.stringValue
                    ?? item["body"]?.stringValue
                    ?? ""
                let updated = item["updatedAt"]?.stringValue.flatMap(ISO8601.date(from:)) ?? Date()
                return KnowledgeDocument(
                    id: id,
                    title: title,
                    body: body,
                    updatedAt: updated,
                    library: record?["library"]?.stringValue ?? "all",
                    fileType: record?["fileType"]?.stringValue ?? "",
                    extractStatus: record?["extractStatus"]?.stringValue ?? "ok",
                    extractNote: record?["extractNote"]?.stringValue ?? "",
                    sourcePath: record?["sourcePath"]?.stringValue ?? ""
                )
            }
        } catch {
            // Soft-fail when kernel offline.
        }
    }

    func upsertKnowledgeDocument(
        title: String,
        body: String,
        id: String? = nil,
        library: String = "all",
        fileType: String = "note",
        extractStatus: String = "ok",
        extractNote: String = "",
        sourcePath: String = ""
    ) async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        do {
            var record: [String: JSONValue] = [
                "title": .string(trimmedTitle),
                "body": .string(trimmedBody),
                "library": .string(library),
                "fileType": .string(fileType),
                "extractStatus": .string(extractStatus),
            ]
            if !extractNote.isEmpty { record["extractNote"] = .string(extractNote) }
            if !sourcePath.isEmpty { record["sourcePath"] = .string(sourcePath) }
            var args: [String: JSONValue] = [
                "title": .string(trimmedTitle),
                "body": .string(trimmedBody),
                "library": .string(library),
                "fileType": .string(fileType),
                "extractStatus": .string(extractStatus),
                "record": .object(record),
            ]
            if !extractNote.isEmpty { args["extractNote"] = .string(extractNote) }
            if !sourcePath.isEmpty { args["sourcePath"] = .string(sourcePath) }
            if let id, !id.isEmpty {
                args["id"] = .string(id)
            }
            _ = try await client.callAsync(.knowledgeDocumentsUpsert, arguments: .object(args))
            await loadKnowledgeDocuments(library: library == "all" ? nil : library)
        } catch {
            errorText = (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    /// Import local files into knowledge_documents with best-effort text extract.
    @discardableResult
    func importKnowledgeFiles(urls: [URL], library: String) async -> String {
        var ok = 0
        var partial = 0
        var failed = 0
        let destRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lucas/KnowledgeFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)

        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let extracted = Self.extractKnowledgeFile(url: url)
            let stamp = ISO8601.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let destName = "\(stamp)_\(url.lastPathComponent)"
            let dest = destRoot.appendingPathComponent(destName)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                // Still upsert even if copy fails; keep original path.
            }
            let storedPath = FileManager.default.fileExists(atPath: dest.path) ? dest.path : url.path
            let title = url.deletingPathExtension().lastPathComponent
            await upsertKnowledgeDocument(
                title: title,
                body: extracted.body,
                library: library,
                fileType: extracted.fileType,
                extractStatus: extracted.status,
                extractNote: extracted.note,
                sourcePath: storedPath
            )
            switch extracted.status {
            case "ok": ok += 1
            case "partial", "unsupported", "empty": partial += 1
            default: failed += 1
            }
        }
        return "导入完成：完整 \(ok)，部分/未抽正文 \(partial)，失败 \(failed)"
    }

    private struct ExtractedKnowledge {
        var body: String
        var fileType: String
        var status: String
        var note: String
    }

    private static func extractKnowledgeFile(url: URL) -> ExtractedKnowledge {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "txt", "text", "csv", "json", "log":
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let fileType = (ext == "json" || ext == "log") ? (ext == "json" ? "chat" : "txt") : (ext == "markdown" ? "md" : ext)
                if trimmed.isEmpty {
                    return ExtractedKnowledge(body: "", fileType: fileType, status: "empty", note: "文件为空")
                }
                // Cap stored body to keep SQLite rows reasonable.
                let capped = String(trimmed.prefix(200_000))
                return ExtractedKnowledge(body: capped, fileType: fileType, status: "ok", note: "")
            }
            return ExtractedKnowledge(body: "", fileType: ext, status: "empty", note: "无法按文本读取")
        case "pdf":
            if let doc = PDFDocument(url: url) {
                var chunks: [String] = []
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i), let s = page.string else { continue }
                    chunks.append(s)
                    if chunks.joined().count > 200_000 { break }
                }
                let body = String(chunks.joined(separator: "\n").prefix(200_000))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty {
                    return ExtractedKnowledge(body: "", fileType: "pdf", status: "empty", note: "PDF 无文本层（可能是扫描件）")
                }
                return ExtractedKnowledge(body: body, fileType: "pdf", status: "ok", note: "")
            }
            return ExtractedKnowledge(body: "", fileType: "pdf", status: "empty", note: "无法打开 PDF")
        case "xlsx", "xls":
            if ext == "xls" {
                return ExtractedKnowledge(
                    body: "",
                    fileType: "xlsx",
                    status: "unsupported",
                    note: "旧版 .xls（非 OOXML）暂不支持；请另存为 .xlsx 后重试"
                )
            }
            let r = OfficeKnowledgeExtract.extractXLSX(url: url)
            return ExtractedKnowledge(body: r.body, fileType: "xlsx", status: r.status, note: r.note)
        case "pptx", "ppt":
            if ext == "ppt" {
                return ExtractedKnowledge(
                    body: "",
                    fileType: "pptx",
                    status: "unsupported",
                    note: "旧版 .ppt（非 OOXML）暂不支持；请另存为 .pptx 后重试"
                )
            }
            let r = OfficeKnowledgeExtract.extractPPTX(url: url)
            return ExtractedKnowledge(body: r.body, fileType: "pptx", status: r.status, note: r.note)
        default:
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8),
               text.contains(where: { !$0.isWhitespace }) {
                return ExtractedKnowledge(
                    body: String(text.prefix(200_000)),
                    fileType: ext.isEmpty ? "其他" : ext,
                    status: "partial",
                    note: "按纯文本尝试读取"
                )
            }
            return ExtractedKnowledge(
                body: "",
                fileType: ext.isEmpty ? "其他" : ext,
                status: "unsupported",
                note: "不支持的格式"
            )
        }
    }

    func deleteKnowledgeDocument(id: String) async {
        guard !id.isEmpty else { return }
        do {
            _ = try await client.callAsync(.knowledgeDocumentsDelete, arguments: .object([
                "id": .string(id),
            ]))
            await loadKnowledgeDocuments()
        } catch {
            errorText = (error as? ClientError)?.description ?? String(describing: error)
        }
    }

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

    private func recordCancellation(state: String) async {
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

    private func snapshotContext(reason: String) async {
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

    private func fetchOpenAgentTasks(limit: Int) async -> [PersistedTask] {
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

    private func ensureUnfinishedAlarm(titles: [String]) async {
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

    private func persistAgentTask(sessionID: String, steps: [ToolStep], preview: String) async {
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

    // MARK: - Settings

    func presentOnboardingIfNeeded() {
        let forced = ProcessInfo.processInfo.environment["LUCAS_SHOW_ONBOARDING"] == "1"
        let completed = UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
        let skipped = UserDefaults.standard.bool(forKey: Self.onboardingSkippedKey)
        if forced || (!completed && !skipped && !hasStoredConnection) {
            onboardingPresented = true
        }
    }

    func skipOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingSkippedKey)
        OnboardingPrefs.markSkipped()
        onboardingPresented = false
    }

    func resetOnboarding() {
        UserDefaults.standard.removeObject(forKey: Self.onboardingSkippedKey)
        UserDefaults.standard.removeObject(forKey: Self.onboardingCompletedKey)
        OnboardingPrefs.reset()
        settingsPresented = false
        onboardingPresented = true
    }

    func loadSettings() async {
        do {
            let result = try await client.callAsync(.configurationList, arguments: .object([:]))
            let entries = result.arrayValue ?? []
            guard
                let entry = entries.first(where: { $0["path"]?.stringValue == "agents.default.model.connection" }),
                let value = entry["value"]
            else { return }
            let data = try ProtocolCoding.encode(value)
            var decoded = try ProtocolCoding.decode(ModelConnection.self, from: data)
            let keyConfigured = value["apiKeyConfigured"]?.boolValue ?? !(value["apiKey"]?.stringValue ?? "").isEmpty
            storedAPIKey = keyConfigured ? "__stored__" : ""
            decoded.apiKey = ""
            settings = decoded
            hasStoredConnection = !decoded.model.isEmpty && !decoded.baseURL.isEmpty && keyConfigured
        } catch {
            errorText = String(describing: error)
        }
    }

    func saveSettings() async -> Bool {
        let key = settings.apiKey
        guard
            !settings.baseURL.trimmingCharacters(in: .whitespaces).isEmpty,
            !settings.model.trimmingCharacters(in: .whitespaces).isEmpty,
            !key.isEmpty || !storedAPIKey.isEmpty
        else {
            errorText = "请填写 Base URL、模型和 API Key 后再保存"
            return false
        }
        do {
            let value = JSONValue.object([
                "baseURL": .string(settings.baseURL),
                "model": .string(settings.model),
                "apiKey": .string(key),
                "temperature": .number(settings.temperature),
                "displayName": .string(settings.displayName),
            ])
            _ = try await client.callAsync(.configurationSet, arguments: .object([
                "path": .string("agents.default.model.connection"),
                "value": value,
            ]))
            // Mirror into custom_model_routes so Settings can list provider history like Japlos.
            let routeID = Self.routeID(for: settings)
            let routeRecord = JSONValue.object([
                "baseURL": .string(settings.baseURL),
                "model": .string(settings.model),
                "temperature": .number(settings.temperature),
                "displayName": .string(settings.displayName.isEmpty ? providerHint(for: settings.baseURL) : settings.displayName),
                "protocol": .string("chat.completions"),
            ])
            _ = try? await client.callAsync(.modelRoutesSet, arguments: .object([
                "routeID": .string(routeID),
                "record": routeRecord,
            ]))
            storedAPIKey = "__stored__"
            settings.apiKey = ""
            hasStoredConnection = true
            return true
        } catch {
            errorText = String(describing: error)
            return false
        }
    }

    /// Persist TTS prefs into `speech_profiles` (kernel store). Volcengine
    /// credentials ride in the record and are redacted into SecretStore by the kernel.
    func syncSpeechProfile(from voice: SpeechOutput) async {
        let providerID = voice.provider.rawValue
        var record: [String: JSONValue] = [
            "provider": .string(providerID),
            "voiceIdentifier": .string(voice.voiceIdentifier),
            "languageCode": .string(voice.languageCode),
            "rate": .number(voice.rate),
            "pitch": .number(voice.pitch),
            "inputDeviceUID": .string(voice.inputDeviceUID),
            "tone": .string(OnboardingPrefs.tone),
            "volcengineVoiceType": .string(voice.volcengineVoiceType),
            "volcengineCluster": .string(voice.volcengineCluster),
        ]
        if !voice.volcengineAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record["volcengineAppID"] = .string(voice.volcengineAppID)
        }
        if !voice.volcengineToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record["volcengineToken"] = .string(voice.volcengineToken)
        }
        _ = try? await client.callAsync(.speechProfilesSet, arguments: .object([
            "profileID": .string("default"),
            "providerID": .string(providerID),
            "isDefault": .bool(true),
            "record": .object(record),
        ]))
        if !voice.volcengineToken.isEmpty {
            voice.volcengineToken = ""
            voice.markVolcengineConfigured(true)
        }
        await loadSpeechProfile()
    }

    func loadSpeechProfile() async {
        do {
            let result = try await client.callAsync(.speechProfilesList, arguments: .object([:]))
            guard let profile = (result.arrayValue ?? []).first(where: { $0["isDefault"]?.boolValue == true })
                    ?? result.arrayValue?.first else { return }
            let record = profile["record"] ?? .object([:])
            if let providerRaw = profile["providerID"]?.stringValue ?? record["provider"]?.stringValue,
               let provider = SpeechOutput.Provider(rawValue: providerRaw) {
                voice.provider = provider
            }
            if let voiceID = record["voiceIdentifier"]?.stringValue {
                voice.voiceIdentifier = voiceID
            }
            if let language = record["languageCode"]?.stringValue, !language.isEmpty {
                voice.languageCode = language
            }
            if let rate = record["rate"]?.doubleValue { voice.rate = rate }
            if let pitch = record["pitch"]?.doubleValue { voice.pitch = pitch }
            if let input = record["inputDeviceUID"]?.stringValue {
                voice.inputDeviceUID = input
            }
            if let vt = record["volcengineVoiceType"]?.stringValue, !vt.isEmpty {
                voice.volcengineVoiceType = vt
            }
            if let cluster = record["volcengineCluster"]?.stringValue, !cluster.isEmpty {
                voice.volcengineCluster = cluster
            }
            let configured = record["volcengineTokenConfigured"]?.boolValue == true
                && record["volcengineAppIDConfigured"]?.boolValue == true
            voice.markVolcengineConfigured(configured)
        } catch {
            // Offline: keep local UserDefaults prefs.
        }
    }

    func wireSpeechCloud() {
        voice.cloudSynthesize = { [weak self] text in
            guard let self else { return nil }
            do {
                let result = try await self.client.callAsync(
                    .speechSynthesize,
                    arguments: .object([
                        "text": .string(text),
                        "providerID": .string(self.voice.provider.rawValue),
                        "voiceType": .string(self.voice.volcengineVoiceType),
                        "cluster": .string(self.voice.volcengineCluster),
                    ]),
                    timeout: 45
                )
                if result["fallback"]?.boolValue == true {
                    let reason = result["reason"]?.stringValue ?? "fallback"
                    await MainActor.run { self.voice.noteCloudError(reason) }
                    AppLog.write("speech.synthesize fallback: \(reason)")
                    return nil
                }
                guard
                    let b64 = result["data"]?.stringValue,
                    let data = Data(base64Encoded: b64),
                    !data.isEmpty
                else {
                    await MainActor.run { self.voice.noteCloudError("empty_audio") }
                    return nil
                }
                let encoding = result["encoding"]?.stringValue ?? "mp3"
                return (data, encoding)
            } catch {
                await MainActor.run {
                    self.voice.noteCloudError((error as? ClientError)?.description ?? String(describing: error))
                }
                AppLog.write("speech.synthesize error: \(error)")
                return nil
            }
        }
    }

    func loadAlarms(limit: Int = 40) async {
        do {
            let result = try await client.callAsync(.alarmList, arguments: .object([
                "limit": .number(Double(limit)),
            ]))
            alarms = (result.arrayValue ?? []).compactMap { item in
                guard let id = item["id"]?.stringValue else { return nil }
                let title = item["title"]?.stringValue ?? ""
                let fireAt = item["fireAt"]?.stringValue.flatMap(ISO8601.date(from:)) ?? Date()
                let enabled = item["enabled"]?.boolValue ?? true
                return AlarmItem(id: id, title: title, fireAt: fireAt, enabled: enabled)
            }
        } catch {
            // Keep empty list when kernel offline.
        }
    }

    func upsertAlarm(title: String, fireAt: Date, enabled: Bool = true, id: String? = nil) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            var args: [String: JSONValue] = [
                "title": .string(trimmed),
                "fireAt": .string(ISO8601.string(from: fireAt)),
                "enabled": .bool(enabled),
            ]
            if let id, !id.isEmpty { args["id"] = .string(id) }
            _ = try await client.callAsync(.alarmUpsert, arguments: .object(args))
            await loadAlarms()
        } catch {
            errorText = (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func deleteAlarm(id: String) async {
        do {
            _ = try await client.callAsync(.alarmDelete, arguments: .object(["id": .string(id)]))
            await loadAlarms()
        } catch {
            errorText = (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func listModelRoutes() async -> [JSONValue] {
        do {
            let result = try await client.callAsync(.modelRoutesList, arguments: .object([:]))
            return result.arrayValue ?? []
        } catch {
            return []
        }
    }

    private static func routeID(for settings: ModelConnection) -> String {
        let host = URL(string: settings.baseURL)?.host ?? "custom"
        let model = settings.model.replacingOccurrences(of: "/", with: "-")
        let raw = "\(host)/\(model)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("-") })
    }

    private func providerHint(for baseURL: String) -> String {
        let url = baseURL.lowercased()
        if url.contains("deepseek") { return "DeepSeek" }
        if url.contains("xiaomimimo") { return "MiMo" }
        if url.contains("pollinations") { return "Pollinations" }
        if url.contains("openai.com") { return "OpenAI" }
        return "Custom"
    }

    func switchModel(_ id: String) async {
        guard id != settings.model else { return }
        settings.model = id
        guard hasStoredConnection else { return }
        _ = await saveSettings()
    }

    func testModel() async {
        isTestingModel = true
        testResult = nil
        defer { isTestingModel = false }
        do {
            let result = try await client.callAsync(.modelTest, arguments: .object([
                "baseURL": .string(settings.baseURL),
                "model": .string(settings.model),
                "apiKey": .string(settings.apiKey),
            ]), timeout: 60)
            if result["ok"]?.boolValue == true {
                let latency = Int(result["latencyMilliseconds"]?.doubleValue ?? 0)
                testResult = "连接成功 · \(latency) ms"
            } else {
                testResult = "失败：\(result["message"]?.stringValue ?? "未知错误")"
            }
        } catch {
            testResult = "失败：\((error as? ClientError)?.description ?? String(describing: error))"
        }
    }


    // MARK: - Channels (微信 / 飞书)

    var wechatStatusLabel: String {
        let state = wechatStatus["state"]?.stringValue ?? "unknown"
        switch state {
        case "connected": return "已连接"
        case "awaiting_scan": return "待扫码"
        case "verification_required": return "需验证码"
        case "needs_auth": return "需授权"
        case "disconnected": return "未连接"
        case "unavailable": return "不可用"
        default: return state
        }
    }

    var wechatStatusDetail: String {
        if let msg = wechatStatus["message"]?.stringValue, !msg.isEmpty { return msg }
        if let action = wechatStatus["action"]?.stringValue, !action.isEmpty { return action }
        if let err = wechatStatus["lastError"]?.stringValue, !err.isEmpty { return err }
        let count = wechatStatus["connectedAccountCount"]?.intValue ?? 0
        return "账号数 \(count) · 状态 \(wechatStatus["state"]?.stringValue ?? "—")"
    }

    var feishuStatusLabel: String {
        let state = feishuStatus["state"]?.stringValue ?? "unknown"
        switch state {
        case "connected": return "已连接"
        case "awaiting_configuration": return "待配置"
        case "needs_auth": return "需凭据"
        case "disconnected": return "未连接"
        case "connecting": return "连接中"
        case "error": return "错误"
        default: return state
        }
    }

    var feishuStatusDetail: String {
        if let msg = feishuStatus["message"]?.stringValue, !msg.isEmpty { return msg }
        if let action = feishuStatus["action"]?.stringValue, !action.isEmpty { return action }
        let app = feishuStatus["appIdConfigured"]?.boolValue == true
        let secret = feishuStatus["appSecretConfigured"]?.boolValue == true
        return "App ID \(app ? "已配置" : "未配置") · Secret \(secret ? "已配置" : "未配置")"
    }

    func refreshChannelStatus() async {
        do {
            wechatStatus = try await client.callAsync(.runtimeWeChatStatus, arguments: .object([:]))
            if let enabled = wechatStatus["approvalPushEnabled"]?.boolValue {
                wechatApprovalPushEnabled = enabled
            }
        } catch {
            wechatStatus = .object([
                "state": .string("unavailable"),
                "message": .string((error as? ClientError)?.description ?? String(describing: error)),
            ])
        }
        do {
            feishuStatus = try await client.callAsync(.runtimeFeishuStatus, arguments: .object([:]))
        } catch {
            feishuStatus = .object([
                "state": .string("unavailable"),
                "message": .string((error as? ClientError)?.description ?? String(describing: error)),
            ])
        }
        do {
            mailStatus = try await client.callAsync(.runtimeMailStatus, arguments: .object([:]))
        } catch {
            mailStatus = .object([
                "state": .string("unavailable"),
                "message": .string((error as? ClientError)?.description ?? String(describing: error)),
            ])
        }
    }

    func wechatConnect() async -> String {
        do {
            let result = try await client.callAsync(.runtimeWeChatConnect, arguments: .object([:]), timeout: 30)
            wechatStatus = result
            return result["message"]?.stringValue
                ?? (result["ok"]?.boolValue == true ? "已启动扫码登录" : (result["error"]?.stringValue ?? "连接未完成"))
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func wechatDisconnect() async -> String {
        do {
            let result = try await client.callAsync(.runtimeWeChatDisconnect, arguments: .object([:]))
            wechatStatus = result
            return result["message"]?.stringValue ?? "已断开"
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func setWechatApprovalPushEnabled(_ enabled: Bool) async -> String {
        wechatApprovalPushEnabled = enabled
        do {
            _ = try await client.callAsync(.configurationSet, arguments: .object([
                "path": .string("channels.wechat.approvalPush"),
                "value": .object([
                    "enabled": .bool(enabled),
                ]),
            ]))
            await refreshChannelStatus()
            return enabled ? "已开启：审批将尝试推送到微信" : "已关闭：审批仅桌面卡片"
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }


    func feishuConfigure(appID: String, appSecret: String, verificationToken: String) async -> String {
        var args: [String: JSONValue] = [:]
        if !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["app_id"] = .string(appID.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !appSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["app_secret"] = .string(appSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !verificationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["verification_token"] = .string(verificationToken.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do {
            let result = try await client.callAsync(.feishuConnectionConfigure, arguments: .object(args))
            feishuStatus = result
            return result["message"]?.stringValue ?? "已保存"
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func feishuConnect() async -> String {
        do {
            let result = try await client.callAsync(.runtimeFeishuConnect, arguments: .object([:]), timeout: 30)
            feishuStatus = result
            return result["message"]?.stringValue
                ?? (result["ok"]?.boolValue == true ? "已连接" : (result["error"]?.stringValue ?? "连接失败"))
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func feishuDisconnect() async -> String {
        do {
            let result = try await client.callAsync(.runtimeFeishuDisconnect, arguments: .object([:]))
            feishuStatus = result
            return result["message"]?.stringValue ?? "已断开"
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }


    var mailStatusLabel: String {
        let state = mailStatus["state"]?.stringValue ?? "unknown"
        switch state {
        case "connected": return "已连接"
        case "configured": return "已配置"
        case "disconnected": return "未连接"
        case "unavailable": return "不可用"
        default: return state
        }
    }

    var mailStatusDetail: String {
        if let msg = mailStatus["message"]?.stringValue, !msg.isEmpty { return msg }
        if let action = mailStatus["action"]?.stringValue, !action.isEmpty { return action }
        let email = mailStatus["email"]?.stringValue ?? ""
        let pwd = mailStatus["passwordConfigured"]?.boolValue == true
        return "\(email.isEmpty ? "未填地址" : email) · 密码 \(pwd ? "已存" : "未存")"
    }

    func mailConfigure(
        preset: String,
        email: String,
        displayName: String,
        password: String,
        imapHost: String,
        imapPort: String,
        smtpHost: String,
        smtpPort: String
    ) async -> String {
        var args: [String: JSONValue] = [
            "preset": .string(preset),
        ]
        if !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["email"] = .string(email.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["displayName"] = .string(displayName.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !password.isEmpty {
            args["password"] = .string(password)
        }
        if !imapHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["imapHost"] = .string(imapHost.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let p = Int(imapPort.trimmingCharacters(in: .whitespacesAndNewlines)), p > 0 {
            args["imapPort"] = .number(Double(p))
        }
        if !smtpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["smtpHost"] = .string(smtpHost.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let p = Int(smtpPort.trimmingCharacters(in: .whitespacesAndNewlines)), p > 0 {
            args["smtpPort"] = .number(Double(p))
        }
        do {
            let result = try await client.callAsync(.runtimeMailConfigure, arguments: .object(args))
            mailStatus = result
            return result["message"]?.stringValue ?? "已保存"
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func mailConnect() async -> String {
        do {
            let result = try await client.callAsync(.runtimeMailConnect, arguments: .object([:]), timeout: 35)
            mailStatus = result
            return result["message"]?.stringValue
                ?? (result["ok"]?.boolValue == true ? "已连接" : "连接失败")
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func mailDisconnect() async -> String {
        do {
            let result = try await client.callAsync(.runtimeMailDisconnect, arguments: .object([:]))
            mailStatus = result
            return result["message"]?.stringValue ?? "已断开"
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func mailClearSecrets() async -> String {
        do {
            let result = try await client.callAsync(.runtimeMailClearSecrets, arguments: .object([:]))
            mailStatus = result
            return result["message"]?.stringValue ?? "已清除密码"
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func dismissError() {
        errorText = nil
    }

    static func approvalSummary(_ arguments: JSONValue?) -> String {
        guard let arguments else { return "" }
        let text = (try? arguments.encodedString()) ?? ""
        return String(text.prefix(400))
    }
}
