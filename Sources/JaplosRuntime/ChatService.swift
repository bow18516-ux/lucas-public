import Foundation
import JaplosKernel
import JaplosProtocol

/// Orchestrates one chat turn: history -> prompt -> model -> tools -> persist.
///
/// The same execution path serves both the blocking RPC and the streaming RPC;
/// `emit` receives `delta` / `tool` events while the turn runs.
public final class ChatService: @unchecked Sendable {
    private let core: KernelCore
    private let maximumToolRounds = 8

    public init(core: KernelCore) {
        self.core = core
    }

    public func handle(_ request: KernelRequest) async -> KernelResponse {
        switch request.operation {
        case .chatSend:
            return await executeChat(request, emit: nil, approval: nil)
        case .modelTest:
            return await testConnection(request)
        case .modelCatalog:
            return await catalog(request)
        default:
            return .failure(.notFound("Unsupported operation \(request.operation.rawValue)"), requestID: request.id)
        }
    }

    /// Streaming entry point used by the socket server. The final frame carries
    /// either a `done` event or a failure.
    public func handleStreaming(
        _ request: KernelRequest,
        emit: @escaping (KernelResponse) -> Void,
        approval: StreamApprovalProvider? = nil
    ) async {
        guard request.operation == .chatSend else {
            emit(await handle(request))
            return
        }
        let response = await executeChat(request, emit: emit, approval: approval)
        if let failure = response.failure {
            emit(.failure(failure, requestID: request.id))
        } else if let result = response.result {
            var object = result.objectValue ?? [:]
            object["event"] = .string("done")
            emit(.success(.object(object), requestID: request.id))
        } else {
            emit(.failure(.internalError("Chat produced no result"), requestID: request.id))
        }
    }

    // MARK: - Chat

    private func executeChat(
        _ request: KernelRequest,
        emit: ((KernelResponse) -> Void)?,
        approval: StreamApprovalProvider?
    ) async -> KernelResponse {
        let requestID = request.id
        guard let text = request.arguments["text"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .failure(.invalidArgument("text is required"), requestID: requestID)
        }

        let connection: ModelConnection
        do {
            guard let stored = try core.store.resolvedModelConnection(), stored.isConfigured else {
                return .failure(
                    KernelFailure(
                        code: "model_not_configured",
                        message: "请先在设置中配置模型连接（Base URL / 模型 / API Key）",
                        origin: "runtime",
                        retryable: false
                    ),
                    requestID: requestID
                )
            }
            connection = stored
        } catch {
            return .failure(.internalError("读取模型配置失败：\(error)"), requestID: requestID)
        }

        var trackedRunID: String?
        var trackedSessionID: String?

        do {
            let session = try resolveSession(request: request, text: text)
            let isFirstMessage = session.title == "新对话"
            let runID = {
                if let key = request.idempotencyKey, !key.isEmpty { return key }
                if let key = request.correlationID, !key.isEmpty { return key }
                return UUID().uuidString
            }()
            trackedRunID = runID
            trackedSessionID = session.id
            try? core.store.upsertRun(
                id: runID,
                agentID: "default",
                state: "running",
                record: .object([
                    "sessionID": .string(session.id),
                    "requestID": .string(requestID),
                    "preview": .string(String(text.prefix(120))),
                ])
            )

            let userTurn = ChatTurn(sessionID: session.id, role: .user, text: text)
            try core.store.appendTurn(userTurn)
            try core.store.touchSession(session.id, title: isFirstMessage ? Self.title(from: text) : nil)

            let scene = SceneRouter.match(text)
            let tools = core.tools.definitions() + core.mcpDefinitions
            let history = try historyMessages(sessionID: session.id)
            // Current user turn already persisted; count user roles in historyMessages
            // (history includes the turn we just appended via store, depending on implementation).
            let firstInSession = isFirstMessage

            var system = PromptLibrary.systemPrompt(scene: scene, tools: tools)
            system += "\n\n" + ContextInjector.policyGuidance
            let injected = ContextInjector.build(
                store: core.store,
                query: text,
                isFirstMessageInSession: firstInSession
            )
            if !injected.isEmpty {
                system += "\n\n" + injected
            }

            _ = ContextInjector.maybeCaptureExplicitMemory(
                store: core.store,
                sessionID: session.id,
                text: text
            )

            var messages: [ModelMessage] = [.system(system)]
            messages.append(contentsOf: history)

            let client = ModelClient(connection: connection)
            var steps: [JSONValue] = []

            for _ in 0..<maximumToolRounds {
                try Task.checkCancellation()
                let reply: ModelReply
                if let emit {
                    reply = try await client.stream(messages: messages, tools: tools) { delta in
                        emit(.success(.object([
                            "event": .string("delta"),
                            "text": .string(delta),
                        ]), requestID: requestID))
                    }
                } else {
                    reply = try await client.complete(messages: messages, tools: tools)
                }

                if reply.text.isEmpty && reply.toolCalls.isEmpty {
                    throw ModelError.invalidResponse("模型返回了空消息")
                }

                let assistantTurn = ChatTurn(
                    sessionID: session.id,
                    role: .assistant,
                    text: reply.text,
                    toolCalls: reply.toolCalls,
                    metadata: .object(["model": .string(connection.model)])
                )
                try core.store.appendTurn(assistantTurn)
                messages.append(.assistant(text: reply.text, toolCalls: reply.toolCalls))

                guard !reply.toolCalls.isEmpty else {
                    try core.store.touchSession(session.id)
                    try? core.store.upsertRun(
                        id: runID,
                        agentID: "default",
                        state: "completed",
                        record: .object([
                            "sessionID": .string(session.id),
                            "requestID": .string(requestID),
                            "finishReason": .string(reply.finishReason),
                        ])
                    )
                    return .success(.object([
                        "sessionID": .string(session.id),
                        "text": .string(reply.text),
                        "steps": .array(steps),
                        "finishReason": .string(reply.finishReason),
                    ]), requestID: requestID)
                }

                for call in reply.toolCalls {
                    try Task.checkCancellation()
                    let execution: ToolExecution
                    if
                        let approval,
                        let definition = core.definition(named: call.name),
                        definition.risk == .high
                    {
                        let allowed = await approval(call, definition)
                        if allowed {
                            execution = await core.executeTool(call, sessionID: session.id, principal: request.principal)
                        } else {
                            execution = ToolExecution(
                                call: call,
                                ok: false,
                                output: .null,
                                error: "用户拒绝了该高风险操作"
                            )
                        }
                    } else {
                        execution = await core.executeTool(call, sessionID: session.id, principal: request.principal)
                    }
                    let payload = Self.toolPayload(execution)
                    let toolTurn = ChatTurn(
                        sessionID: session.id,
                        role: .tool,
                        text: payload,
                        toolCallID: call.id,
                        toolName: call.name
                    )
                    try core.store.appendTurn(toolTurn)
                    messages.append(.tool(callID: call.id, name: call.name, content: payload))
                    steps.append(.object([
                        "tool": .string(call.name),
                        "ok": .bool(execution.ok),
                        "output": Self.truncate(execution.output, limit: 800),
                        "error": execution.error.map(JSONValue.string) ?? .null,
                        "durationMilliseconds": .number(execution.durationMilliseconds),
                    ]))
                    emit?(.success(.object([
                        "event": .string("tool"),
                        "name": .string(call.name),
                        "ok": .bool(execution.ok),
                        "detail": .string(Self.toolDetail(execution)),
                    ]), requestID: requestID))
                }
            }

            let fallback = "工具调用次数已达上限（\(maximumToolRounds) 轮），我把目前掌握的信息整理给你。"
            let finalTurn = ChatTurn(sessionID: session.id, role: .assistant, text: fallback)
            try core.store.appendTurn(finalTurn)
            try core.store.touchSession(session.id)
            try? core.store.upsertRun(
                id: runID,
                agentID: "default",
                state: "completed",
                record: .object([
                    "sessionID": .string(session.id),
                    "requestID": .string(requestID),
                    "finishReason": .string("tool_budget_exhausted"),
                ])
            )
            return .success(.object([
                "sessionID": .string(session.id),
                "text": .string(fallback),
                "steps": .array(steps),
                "finishReason": .string("tool_budget_exhausted"),
            ]), requestID: requestID)
        } catch is CancellationError {
            if let runID = trackedRunID {
                try? core.store.upsertRun(
                    id: runID,
                    agentID: "default",
                    state: "failed",
                    record: .object([
                        "sessionID": .string(trackedSessionID ?? ""),
                        "requestID": .string(requestID),
                        "error": .string("cancelled"),
                    ])
                )
            }
            return .failure(
                KernelFailure(code: "cancelled", message: "已停止", origin: "runtime", retryable: false),
                requestID: requestID
            )
        } catch let error as ModelError {
            if let runID = trackedRunID {
                try? core.store.upsertRun(
                    id: runID,
                    agentID: "default",
                    state: "failed",
                    record: .object([
                        "sessionID": .string(trackedSessionID ?? ""),
                        "requestID": .string(requestID),
                        "error": .string(error.description),
                    ])
                )
            }
            return .failure(
                KernelFailure(
                    code: "model_error",
                    message: error.description,
                    origin: "runtime",
                    retryable: true
                ),
                requestID: requestID
            )
        } catch {
            if let runID = trackedRunID {
                try? core.store.upsertRun(
                    id: runID,
                    agentID: "default",
                    state: "failed",
                    record: .object([
                        "sessionID": .string(trackedSessionID ?? ""),
                        "requestID": .string(requestID),
                        "error": .string(String(describing: error)),
                    ])
                )
            }
            if Task.isCancelled {
                return .failure(
                    KernelFailure(code: "cancelled", message: "已停止", origin: "runtime", retryable: false),
                    requestID: requestID
                )
            }
            return .failure(.internalError("\(error)"), requestID: requestID)
        }
    }

    private func catalog(_ request: KernelRequest) async -> KernelResponse {
        let stored = (try? core.store.resolvedModelConnection()) ?? nil
        let requestKey = request.arguments["apiKey"]?.stringValue ?? ""
        let connection = ModelConnection(
            baseURL: request.arguments["baseURL"]?.stringValue ?? stored?.baseURL ?? "",
            model: request.arguments["model"]?.stringValue ?? stored?.model ?? "",
            apiKey: requestKey.isEmpty ? (stored?.apiKey ?? "") : requestKey,
            temperature: 0
        )
        guard connection.isConfigured else {
            return .failure(.invalidArgument("模型连接不完整"), requestID: request.id)
        }
        do {
            let models = try await ModelClient(connection: connection).listModels()
            return .success(.object(["models": .array(models.map(JSONValue.string))]), requestID: request.id)
        } catch {
            return .failure(
                KernelFailure(code: "model_catalog_failed", message: String(describing: error), origin: "runtime", retryable: true),
                requestID: request.id
            )
        }
    }

    // MARK: - Model test

    private func testConnection(_ request: KernelRequest) async -> KernelResponse {
        let stored = (try? core.store.resolvedModelConnection()) ?? nil
        let requestKey = request.arguments["apiKey"]?.stringValue ?? ""
        let connection = ModelConnection(
            baseURL: request.arguments["baseURL"]?.stringValue ?? stored?.baseURL ?? "",
            model: request.arguments["model"]?.stringValue ?? stored?.model ?? "",
            apiKey: requestKey.isEmpty ? (stored?.apiKey ?? "") : requestKey,
            temperature: 0
        )
        guard connection.isConfigured else {
            return .failure(.invalidArgument("模型连接不完整"), requestID: request.id)
        }
        let started = Date()
        do {
            let reply = try await ModelClient(connection: connection)
                .complete(messages: [.user("回复 pong 两个字母即可")], tools: [])
            return .success(.object([
                "ok": .bool(true),
                "latencyMilliseconds": .number(Date().timeIntervalSince(started) * 1000),
                "model": .string(connection.model),
                "reply": .string(String(reply.text.prefix(80))),
            ]), requestID: request.id)
        } catch {
            return .success(.object([
                "ok": .bool(false),
                "latencyMilliseconds": .number(Date().timeIntervalSince(started) * 1000),
                "model": .string(connection.model),
                "message": .string(String(describing: error)),
            ]), requestID: request.id)
        }
    }

    // MARK: - Helpers

    private func resolveSession(request: KernelRequest, text: String) throws -> ChatSession {
        if let id = request.arguments["sessionID"]?.stringValue, let existing = try core.store.session(id) {
            return existing
        }
        return try core.store.createSession(title: "新对话")
    }

    /// Keeps the most recent turns under an approximate character budget.
    /// Tool results follow their assistant call, so trimming from the end keeps
    /// the request valid; a leading dangling tool message is dropped.
    private func historyMessages(sessionID: String) throws -> [ModelMessage] {
        let turns = try core.store.history(sessionID: sessionID, limit: 240)
        let budget = 48_000
        var used = 0
        var selected: [ChatTurn] = []

        for turn in turns.reversed() {
            let cost = turn.text.count + turn.toolCalls.count * 64
            if used + cost > budget, !selected.isEmpty { break }
            used += cost
            selected.append(turn)
        }

        var ordered = Array(selected.reversed())
        while let first = ordered.first, first.role == .tool {
            ordered.removeFirst()
        }

        return ordered.compactMap { turn in
            switch turn.role {
            case .user:
                return .user(turn.text)
            case .assistant:
                return .assistant(text: turn.text, toolCalls: turn.toolCalls)
            case .tool:
                guard let callID = turn.toolCallID else { return nil }
                return .tool(callID: callID, name: turn.toolName ?? "tool", content: turn.text)
            case .system:
                return nil
            }
        }
    }

    private static func toolDetail(_ execution: ToolExecution) -> String {
        if let error = execution.error { return String(error.prefix(160)) }
        if let text = execution.output["stdout"]?.stringValue, !text.isEmpty {
            return String(text.prefix(160))
        }
        if let path = execution.output["path"]?.stringValue {
            return path
        }
        if let track = execution.output["track"]?.stringValue, !track.isEmpty {
            let artist = execution.output["artist"]?.stringValue ?? ""
            let state = execution.output["state"]?.stringValue ?? ""
            return [state, track, artist].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if let name = execution.output["name"]?.stringValue ?? execution.output["application"]?.stringValue {
            return name
        }
        if let action = execution.output["action"]?.stringValue {
            return action
        }
        if let text = try? JSONCoding.encodeToString(execution.output) {
            return String(text.prefix(160))
        }
        return ""
    }

    private static func toolPayload(_ execution: ToolExecution) -> String {
        let value = JSONValue.object([
            "ok": .bool(execution.ok),
            "output": execution.output,
            "error": execution.error.map(JSONValue.string) ?? .null,
        ])
        let text = (try? JSONCoding.encodeToString(value)) ?? "{\"ok\":false}"
        return truncateText(text, limit: 6000)
    }

    private static func truncate(_ value: JSONValue, limit: Int) -> JSONValue {
        let text = (try? JSONCoding.encodeToString(value)) ?? "null"
        guard text.count > limit else { return value }
        return .string(String(text.prefix(limit)) + "…(truncated)")
    }

    private static func truncateText(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…(truncated)"
    }

    private static func title(from text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
        let prefix = String(cleaned.prefix(24))
        return cleaned.count > 24 ? prefix + "…" : prefix
    }
}
