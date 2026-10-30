import Foundation
import JaplosProtocol

/// The kernel owns persistence, policy and tools. Chat orchestration lives in
/// `JaplosRuntime`; the daemon wires the two together through `chatHandler`.
public final class KernelCore: @unchecked Sendable {
    public let store: KernelStore
    public let policy: PolicyEngine
    public let tools: ToolRegistry
    public let mcp: MCPManager
    public let startedAt = Date()
    public let version = "1.0.0"
    public let workspace: URL

    private let lock = NSLock()
    private var _chatHandler: ((KernelRequest) async -> KernelResponse)?
    private var _modelHandler: ((KernelRequest) async -> KernelResponse)?
    private var _streamingChatHandler: ((KernelRequest, @escaping (KernelResponse) -> Void, @escaping StreamApprovalProvider) async -> Void)?
    private var _shutdownRequested = false

    public init(storePath: String, workspace: URL? = nil) throws {
        self.store = try KernelStore(path: storePath)
        self.policy = PolicyEngine(store: store)
        self.tools = ToolRegistry()
        self.mcp = MCPManager(store: store)
        self.workspace = workspace ?? FileManager.default.homeDirectoryForCurrentUser
        try policy.bootstrap()
        tools.register(contentsOf: BuiltinTools.all())
        tools.register(contentsOf: ExtendedTools.all())
        tools.register(contentsOf: SystemInfoTools.all())
        tools.register(contentsOf: DocumentTools.all())
    }

    public var mcpDefinitions: [ToolDefinition] {
        mcp.definitions
    }

    public func definition(named name: String) -> ToolDefinition? {
        tools.definition(named: name) ?? mcp.definition(named: name)
    }

    public func reloadMCP() async {
        await mcp.reload()
    }

    public var shutdownRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _shutdownRequested
    }

    public func setChatHandler(_ handler: @escaping (KernelRequest) async -> KernelResponse) {
        lock.withLock { _chatHandler = handler }
    }

    public func setModelHandler(_ handler: @escaping (KernelRequest) async -> KernelResponse) {
        lock.withLock { _modelHandler = handler }
    }

    public func setStreamingChatHandler(
        _ handler: @escaping (KernelRequest, @escaping (KernelResponse) -> Void, @escaping StreamApprovalProvider) async -> Void
    ) {
        lock.withLock { _streamingChatHandler = handler }
    }

    /// Multi-frame variant used by the socket server. Only `chat.send` streams;
    /// every other operation is answered with a single frame.
    public func handleStreaming(
        _ request: KernelRequest,
        emit: @escaping (KernelResponse) -> Void,
        approval: @escaping StreamApprovalProvider = { _, _ in true }
    ) async {
        guard request.operation == .chatSend,
              let handler = lock.withLock({ _streamingChatHandler }) else {
            emit(await handle(request))
            return
        }

        let capability = CapabilityRouting.capability(for: request.operation)
        let resource = request.resource ?? request.operation.rawValue
        do {
            let decision = try policy.evaluate(principal: request.principal, capability: capability, resource: resource)
            guard decision.outcome == .allow else {
                emit(.failure(
                    .permissionDenied(
                        "Policy denied \(request.operation.rawValue): \(decision.reasonCode)",
                        details: .object([
                            "requiredCapability": .string(capability),
                            "resource": .string(resource),
                        ])
                    ),
                    requestID: request.id
                ))
                return
            }
        } catch {
            emit(.failure(.internalError("Policy evaluation failed: \(error)"), requestID: request.id))
            return
        }

        await handler(request, emit, approval)
    }

    // MARK: - Dispatch

    public func handle(_ request: KernelRequest) async -> KernelResponse {
        let requestID = request.id
        let capability = CapabilityRouting.capability(for: request.operation)
        let resource = request.resource ?? request.operation.rawValue

        do {
            let decision = try policy.evaluate(principal: request.principal, capability: capability, resource: resource)
            guard decision.outcome == .allow else {
                return .failure(
                    .permissionDenied(
                        "Policy denied \(request.operation.rawValue): \(decision.reasonCode)",
                        details: .object([
                            "requiredCapability": .string(capability),
                            "resource": .string(resource),
                            "principal": .string(request.principal),
                        ])
                    ),
                    requestID: requestID
                )
            }
        } catch {
            return .failure(.internalError("Policy evaluation failed: \(error)"), requestID: requestID)
        }

        do {
            switch request.operation {
            case .kernelStatus:
                let stats = try store.statistics()
                return .success(.object([
                    "version": .string(version),
                    "protocolVersion": .string(ProtocolVersion.current),
                    "startedAt": .string(ISO8601.string(from: startedAt)),
                    "storePath": .string(store.path),
                    "statistics": .object([
                        "sessions": .number(Double(stats.sessions)),
                        "turns": .number(Double(stats.turns)),
                        "toolInvocations": .number(Double(stats.tools)),
                    ]),
                    "tools": .number(Double(tools.definitions().count + mcp.definitions.count)),
                ]), requestID: requestID)

            case .kernelPing:
                return .success(.object(["pong": .bool(true)]), requestID: requestID)

            case .kernelShutdown:
                lock.withLock { _shutdownRequested = true }
                return .success(.object(["shuttingDown": .bool(true)]), requestID: requestID)

            case .policyGrantsList:
                let grants = try store.grants().map { grant -> JSONValue in
                    .object([
                        "id": .string(grant.id),
                        "principal": .string(grant.principal),
                        "capability": .string(grant.capability),
                        "resource": .string(grant.resourcePattern),
                        "active": .bool(grant.isActive()),
                    ])
                }
                return .success(.object(["grants": .array(grants)]), requestID: requestID)

            case .policyEvaluate:
                let principal = request.arguments["principal"]?.stringValue ?? request.principal
                guard let capability = request.arguments["capability"]?.stringValue else {
                    return .failure(.invalidArgument("capability is required"), requestID: requestID)
                }
                let target = request.arguments["resource"]?.stringValue ?? "*"
                let decision = try policy.evaluate(principal: principal, capability: capability, resource: target)
                return .success(.object([
                    "outcome": .string(decision.outcome.rawValue),
                    "reasonCode": .string(decision.reasonCode),
                    "grantID": decision.grantID.map(JSONValue.string) ?? .null,
                ]), requestID: requestID)

            case .configurationList:
                return .success(.array(try store.configurationList()), requestID: requestID)

            case .configurationSet:
                guard let path = request.arguments["path"]?.stringValue else {
                    return .failure(.invalidArgument("path is required"), requestID: requestID)
                }
                let value = request.arguments["value"] ?? .null
                try store.setConfiguration(path: path, value: value, updatedBy: request.principal)
                return .success(.object(["path": .string(path), "saved": .bool(true)]), requestID: requestID)

            case .configurationHistory:
                let path = request.arguments["path"]?.stringValue
                let limit = request.arguments["limit"]?.intValue ?? 50
                return .success(.array(try store.configurationHistory(path: path, limit: limit)), requestID: requestID)

            case .modelRoutesList:
                return .success(.array(try store.listCustomModelRoutes()), requestID: requestID)

            case .modelRoutesSet:
                guard let routeID = request.arguments["routeID"]?.stringValue, !routeID.isEmpty else {
                    return .failure(.invalidArgument("routeID is required"), requestID: requestID)
                }
                let record = request.arguments["record"] ?? .object([:])
                try store.upsertCustomModelRoute(routeID: routeID, record: record, createdBy: request.principal)
                return .success(.object(["routeID": .string(routeID), "saved": .bool(true)]), requestID: requestID)

            case .modelRoutesDelete:
                guard let routeID = request.arguments["routeID"]?.stringValue, !routeID.isEmpty else {
                    return .failure(.invalidArgument("routeID is required"), requestID: requestID)
                }
                try store.deleteCustomModelRoute(routeID: routeID)
                return .success(.object(["routeID": .string(routeID), "deleted": .bool(true)]), requestID: requestID)

            case .speechProfilesList:
                return .success(.array(try store.listSpeechProfiles()), requestID: requestID)

            case .speechProfilesSet:
                guard let profileID = request.arguments["profileID"]?.stringValue, !profileID.isEmpty else {
                    return .failure(.invalidArgument("profileID is required"), requestID: requestID)
                }
                let providerID = request.arguments["providerID"]?.stringValue ?? "system"
                let isDefault = request.arguments["isDefault"]?.boolValue ?? false
                let record = request.arguments["record"] ?? .object([:])
                try store.upsertSpeechProfile(
                    profileID: profileID,
                    providerID: providerID,
                    isDefault: isDefault,
                    record: record
                )
                return .success(.object([
                    "profileID": .string(profileID),
                    "saved": .bool(true),
                    "isDefault": .bool(isDefault),
                ]), requestID: requestID)

            case .chatSessionCreate:
                let title = request.arguments["title"]?.stringValue ?? "新对话"
                let session = try store.createSession(title: title)
                return .success(Self.encode(session: session), requestID: requestID)

            case .chatSessionsList:
                let limit = request.arguments["limit"]?.intValue ?? 50
                return .success(.array(try store.listSessions(limit: limit).map { Self.encode(session: $0) }), requestID: requestID)

            case .chatSessionRename:
                guard
                    let sessionID = request.arguments["sessionID"]?.stringValue,
                    let title = request.arguments["title"]?.stringValue
                else {
                    return .failure(.invalidArgument("sessionID and title are required"), requestID: requestID)
                }
                try store.renameSession(sessionID, title: title)
                return .success(.object(["renamed": .bool(true)]), requestID: requestID)

            case .chatHistory:
                guard let sessionID = request.arguments["sessionID"]?.stringValue else {
                    return .failure(.invalidArgument("sessionID is required"), requestID: requestID)
                }
                let limit = request.arguments["limit"]?.intValue ?? 200
                let turns = try store.history(sessionID: sessionID, limit: limit)
                return .success(.array(turns.map { Self.encode(turn: $0) }), requestID: requestID)

            case .chatTurnAppend:
                guard
                    let sessionID = request.arguments["sessionID"]?.stringValue,
                    let text = request.arguments["text"]?.stringValue
                else {
                    return .failure(.invalidArgument("sessionID and text are required"), requestID: requestID)
                }
                let role = ChatRole(rawValue: request.arguments["role"]?.stringValue ?? "user") ?? .user
                let turn = ChatTurn(sessionID: sessionID, role: role, text: text)
                try store.appendTurn(turn)
                try store.touchSession(sessionID)
                return .success(Self.encode(turn: turn), requestID: requestID)

            case .toolList:
                let all = tools.definitions() + mcp.definitions
                return .success(.array(all.map { Self.encode(tool: $0) }), requestID: requestID)

            case .mcpStatus:
                return .success(.object([
                    "servers": .array(mcp.status),
                    "tools": .array(mcp.definitions.map { Self.encode(tool: $0) }),
                ]), requestID: requestID)

            case .mcpRefresh:
                await mcp.reload()
                let count = mcp.definitions.count
                return .success(.object([
                    "servers": .array(mcp.status),
                    "toolCount": .number(Double(count)),
                ]), requestID: requestID)

            case .toolInvoke:
                return await invokeTool(request)

            case .chatSend:
                let handler = lock.withLock { _chatHandler }
                guard let handler else {
                    return .failure(.internalError("Chat runtime is not configured"), requestID: requestID)
                }
                return await handler(request)

            case .modelTest, .modelCatalog:
                let handler = lock.withLock { _modelHandler }
                guard let handler else {
                    return .failure(.internalError("Model runtime is not configured"), requestID: requestID)
                }
                return await handler(request)

            default:
                return .failure(.notFound("Unknown operation \(request.operation.rawValue)"), requestID: requestID)
            }
        } catch {
            return .failure(.internalError("\(error)"), requestID: requestID)
        }
    }

    // MARK: - Tools

    /// Policy-checked tool execution, shared by the RPC surface and the agent loop.
    public func executeTool(_ call: ToolCall, sessionID: String?, principal: String) async -> ToolExecution {
        if call.name.hasPrefix("mcp.") {
            guard let definition = mcp.definition(named: call.name) else {
                return ToolExecution(call: call, ok: false, output: .null, error: "Unknown MCP tool: \(call.name)")
            }
            do {
                let decision = try policy.evaluate(principal: principal, capability: definition.capability, resource: call.name)
                guard decision.outcome == .allow else {
                    return ToolExecution(call: call, ok: false, output: .null, error: "Denied by policy: \(decision.reasonCode)")
                }
            } catch {
                return ToolExecution(call: call, ok: false, output: .null, error: "Policy error: \(error)")
            }
            let execution = await mcp.invoke(call)
            try? store.recordToolInvocation(
                sessionID: sessionID,
                tool: call.name,
                ok: execution.ok,
                durationMilliseconds: execution.durationMilliseconds,
                arguments: call.arguments,
                output: execution.output,
                error: execution.error
            )
            return execution
        }

        guard let definition = tools.definition(named: call.name) else {
            return ToolExecution(call: call, ok: false, output: .null, error: "Unknown tool: \(call.name)")
        }
        do {
            let decision = try policy.evaluate(principal: principal, capability: definition.capability, resource: call.name)
            guard decision.outcome == .allow else {
                return ToolExecution(call: call, ok: false, output: .null, error: "Denied by policy: \(decision.reasonCode)")
            }
        } catch {
            return ToolExecution(call: call, ok: false, output: .null, error: "Policy error: \(error)")
        }
        let execution = await tools.invoke(call, context: ToolContext(sessionID: sessionID, workspace: workspace))
        try? store.recordToolInvocation(
            sessionID: sessionID,
            tool: call.name,
            ok: execution.ok,
            durationMilliseconds: execution.durationMilliseconds,
            arguments: call.arguments,
            output: execution.output,
            error: execution.error
        )
        return execution
    }

    private func invokeTool(_ request: KernelRequest) async -> KernelResponse {
        let requestID = request.id
        guard
            let name = request.arguments["name"]?.stringValue,
            definition(named: name) != nil
        else {
            return .failure(.invalidArgument("Unknown tool name"), requestID: requestID)
        }

        let call = ToolCall(
            id: request.arguments["callID"]?.stringValue ?? UUID().uuidString,
            name: name,
            arguments: request.arguments["arguments"] ?? .object([:])
        )
        let sessionID = request.arguments["sessionID"]?.stringValue
        let execution = await executeTool(call, sessionID: sessionID, principal: request.principal)
        return .success(Self.encode(execution: execution), requestID: requestID)
    }

    // MARK: - Encoding helpers

    public static func encode(turn: ChatTurn) -> JSONValue {
        func dateString(_ date: Date) -> JSONValue { .string(ISO8601.string(from: date)) }
        return .object([
            "id": .string(turn.id),
            "sessionID": .string(turn.sessionID),
            "role": .string(turn.role.rawValue),
            "text": .string(turn.text),
            "createdAt": dateString(turn.createdAt),
            "toolCalls": .array(turn.toolCalls.map { call in
                .object([
                    "id": .string(call.id),
                    "name": .string(call.name),
                    "arguments": call.arguments,
                ])
            }),
            "toolCallID": turn.toolCallID.map(JSONValue.string) ?? .null,
            "toolName": turn.toolName.map(JSONValue.string) ?? .null,
        ])
    }

    public static func encode(session: ChatSession) -> JSONValue {
        .object([
            "id": .string(session.id),
            "title": .string(session.title),
            "createdAt": .string(ISO8601.string(from: session.createdAt)),
            "updatedAt": .string(ISO8601.string(from: session.updatedAt)),
        ])
    }

    public static func encode(tool: ToolDefinition) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "title": .string(tool.title),
            "summary": .string(tool.summary),
            "inputSchema": tool.inputSchema,
            "capability": .string(tool.capability),
            "risk": .string(tool.risk.rawValue),
            "provider": .string(tool.provider),
        ])
    }

    public static func encode(execution: ToolExecution) -> JSONValue {
        .object([
            "call": .object([
                "id": .string(execution.call.id),
                "name": .string(execution.call.name),
                "arguments": execution.call.arguments,
            ]),
            "ok": .bool(execution.ok),
            "output": execution.output,
            "error": execution.error.map(JSONValue.string) ?? .null,
            "durationMilliseconds": .number(execution.durationMilliseconds),
        ])
    }
}
