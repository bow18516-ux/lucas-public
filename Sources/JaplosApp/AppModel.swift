import Combine
import Foundation
import JaplosProtocol
import JaplosClient
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
    var sendTask: Task<Void, Never>?
    var currentStream: ChatStream?

    init(socketPath: String = KernelClient.defaultSocketPath) {
        self.client = KernelClient(socketPath: socketPath)
    }

    // MARK: - Lifecycle

    func migrateLegacyStoreIfNeeded() {
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
}
