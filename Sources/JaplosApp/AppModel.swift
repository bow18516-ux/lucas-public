import Combine
import Foundation
import JaplosProtocol

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
    @Published var isTestingModel = false
    @Published var testResult: String?
    @Published var memoryNotes: [MemoryNote] = []
    @Published var recentTasks: [PersistedTask] = []

    struct MemoryNote: Identifiable, Equatable {
        var id: String
        var content: String
        var kind: String
        var sessionID: String
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
            let result = try await client.callAsync(.chatSessionCreate, arguments: .object(["title": .string("新对话")]))
            guard let id = result["id"]?.stringValue else { return }
            currentSessionID = id
            messages = []
            await loadSessions()
            await loadMemories()
            await loadRecentTasks()
        } catch {
            errorText = String(describing: error)
        }
    }

    func selectSession(_ id: String) async {
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

    func loadMemories(limit: Int = 40) async {
        do {
            var args: [String: JSONValue] = ["limit": .number(Double(limit))]
            if let sessionID = currentSessionID {
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
            // Keep session-title fallback in UI when kernel is offline.
        }
    }

    func rememberNote(_ content: String) async {
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
            await loadMemories()
        } catch {
            errorText = (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func rememberLatestUserMessage() async {
        guard let last = messages.last(where: { $0.role == "user" }) else { return }
        await rememberNote(String(last.text.prefix(280)))
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

    /// Persist current system TTS prefs into `speech_profiles` (kernel store).
    func syncSpeechProfile(from voice: SpeechOutput) async {
        let record = JSONValue.object([
            "provider": .string("system"),
            "voiceIdentifier": .string(voice.voiceIdentifier),
            "languageCode": .string(voice.languageCode),
            "rate": .number(voice.rate),
            "pitch": .number(voice.pitch),
            "inputDeviceUID": .string(voice.inputDeviceUID),
            "tone": .string(OnboardingPrefs.tone),
        ])
        _ = try? await client.callAsync(.speechProfilesSet, arguments: .object([
            "profileID": .string("system-default"),
            "providerID": .string("system"),
            "isDefault": .bool(true),
            "record": record,
        ]))
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

    func dismissError() {
        errorText = nil
    }

    static func approvalSummary(_ arguments: JSONValue?) -> String {
        guard let arguments else { return "" }
        let text = (try? arguments.encodedString()) ?? ""
        return String(text.prefix(400))
    }
}
