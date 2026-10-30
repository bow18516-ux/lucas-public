import Foundation
import JaplosProtocol

/// The kernel owns persistence, policy and tools. Chat orchestration lives in
/// `JaplosRuntime`; the daemon wires the two together through `chatHandler`.
public final class KernelCore: @unchecked Sendable {
    public let store: KernelStore
    public let policy: PolicyEngine
    public let tools: ToolRegistry
    public let mcp: MCPManager
    public let wechat: WeChatChannel
    public let feishu: FeishuChannel
    public let mail: MailChannel
    /// WeChat side-channel for tool approvals (desktop card remains primary).
    public let wechatApprovalBridge: WeChatApprovalBridge
    public let startedAt = Date()
    public let version = ProductVersion.marketing
    public let workspace: URL

    /// Built once in `init`: every served operation maps to its domain handler.
    private(set) var operationHandlers: [KernelOperation: any KernelOperationHandler] = [:]

    private let lock = NSLock()
    private var _chatHandler: ((KernelRequest) async -> KernelResponse)?
    private var _modelHandler: ((KernelRequest) async -> KernelResponse)?
    private var _streamingChatHandler: ((KernelRequest, @escaping (KernelResponse) -> Void, @escaping StreamApprovalProvider) async -> Void)?
    private var _shutdownRequested = false
    private var _shutdownHandler: (() -> Void)?

    public init(storePath: String, workspace: URL? = nil) throws {
        self.store = try KernelStore(path: storePath)
        self.policy = PolicyEngine(store: store)
        self.tools = ToolRegistry()
        self.mcp = MCPManager(store: store)
        let support = URL(fileURLWithPath: storePath).deletingLastPathComponent()
        self.wechat = WeChatChannel(store: store, supportDirectory: support)
        self.feishu = FeishuChannel(store: store, supportDirectory: support)
        self.mail = MailChannel(store: store, supportDirectory: support)
        self.wechatApprovalBridge = WeChatApprovalBridge(store: store, wechat: wechat)
        self.workspace = workspace ?? FileManager.default.homeDirectoryForCurrentUser
        try policy.bootstrap()
        tools.register(contentsOf: BuiltinTools.all())
        tools.register(contentsOf: ExtendedTools.all())
        tools.register(contentsOf: SystemInfoTools.all())
        tools.register(contentsOf: DocumentTools.all())
        tools.register(contentsOf: ChannelTools.all(wechat: wechat, feishu: feishu))
        tools.register(contentsOf: MailTools.all(mail: mail))
        tools.register(contentsOf: MemoryKnowledgeTools.all(store: store))

        for handler in Self.makeHandlers(core: self) {
            for operation in handler.operations {
                operationHandlers[operation] = handler
            }
        }
    }

    /// One instance per domain; the test uses this to check for duplicate
    /// registrations without re-listing the types.
    static func makeHandlers(core: KernelCore) -> [any KernelOperationHandler] {
        [
            AdminOperations(core: core),
            ChatOperations(core: core),
            MemoryOperations(core: core),
            KnowledgeOperations(core: core),
            ChannelOperations(core: core),
            ModelOperations(core: core),
            ToolsOperations(core: core),
        ]
    }

    /// True when `handle` will route this operation to a domain handler.
    public func handles(_ operation: KernelOperation) -> Bool {
        operationHandlers[operation] != nil
    }

    /// Marks the shutdown flag and returns the daemon-exit callback.
    func requestShutdown() -> (() -> Void)? {
        lock.withLock {
            _shutdownRequested = true
            return _shutdownHandler
        }
    }

    var chatHandlerClosure: ((KernelRequest) async -> KernelResponse)? {
        lock.withLock { _chatHandler }
    }

    var modelHandlerClosure: ((KernelRequest) async -> KernelResponse)? {
        lock.withLock { _modelHandler }
    }

    /// Ensure `self-healing/` under Application Support Lucas and append a boot ledger row.
    public func recordBootSelfHealing(supportDirectory: URL? = nil) {
        recordSelfHealing(
            kind: "boot",
            detail: [
                "storePath": .string(store.path),
                "version": .string(version),
            ],
            supportDirectory: supportDirectory
        )
    }

    public func recordSelfHealing(kind: String, detail: [String: JSONValue] = [:], supportDirectory: URL? = nil) {
        let support = supportDirectory ?? URL(fileURLWithPath: store.path).deletingLastPathComponent()
        let dir = support.appendingPathComponent("self-healing", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var record = detail
        record["at"] = .string(ISO8601.string(from: Date()))
        try? store.appendSelfHealingEvent(kind: kind, record: .object(record))
        var payloadObject = record
        payloadObject["kind"] = .string(kind)
        if let encoded = try? ProtocolCoding.encode(JSONValue.object(payloadObject)),
           var line = String(data: encoded, encoding: .utf8) {
            line.append("\n")
            let jsonl = dir.appendingPathComponent("events.jsonl")
            let payload = Data(line.utf8)
            if FileManager.default.fileExists(atPath: jsonl.path),
               let handle = try? FileHandle(forWritingTo: jsonl) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: payload)
            } else {
                try? payload.write(to: jsonl, options: .atomic)
            }
        }
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

    /// Called after `kernel.shutdown` is answered; the daemon stops serving and
    /// exits instead of waiting for the next 0.5s poll.
    public func setShutdownHandler(_ handler: @escaping () -> Void) {
        lock.withLock { _shutdownHandler = handler }
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
        approval: @escaping StreamApprovalProvider
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

        if KernelRetiredOperations.all.contains(request.operation) {
            return .failure(
                .notFound("disabled operation \(request.operation.rawValue)"),
                requestID: requestID
            )
        }
        guard let handler = operationHandlers[request.operation] else {
            return .failure(
                .notFound("Unknown operation \(request.operation.rawValue)"),
                requestID: requestID
            )
        }
        do {
            return try await handler.handle(request)
        } catch {
            return .failure(.internalError("\(error)"), requestID: requestID)
        }
    }

}
