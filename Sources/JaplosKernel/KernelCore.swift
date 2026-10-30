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
        let support = URL(fileURLWithPath: storePath).deletingLastPathComponent()
        self.wechat = WeChatChannel(store: store, supportDirectory: support)
        self.feishu = FeishuChannel(store: store, supportDirectory: support)
        self.workspace = workspace ?? FileManager.default.homeDirectoryForCurrentUser
        try policy.bootstrap()
        tools.register(contentsOf: BuiltinTools.all())
        tools.register(contentsOf: ExtendedTools.all())
        tools.register(contentsOf: SystemInfoTools.all())
        tools.register(contentsOf: DocumentTools.all())
        tools.register(contentsOf: ChannelTools.all(wechat: wechat, feishu: feishu))
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

            case .mcpEventsList:
                let serverID = request.arguments["serverID"]?.stringValue
                let limit = request.arguments["limit"]?.intValue ?? 100
                return .success(.array(try store.listMCPEvents(serverID: serverID, limit: limit)), requestID: requestID)

            case .memoryList:
                let sessionID = request.arguments["sessionID"]?.stringValue
                let limit = request.arguments["limit"]?.intValue ?? 50
                return .success(.array(try store.listMemories(sessionID: sessionID, limit: limit)), requestID: requestID)

            case .memoryUpsert:
                guard let content = request.arguments["content"]?.stringValue, !content.isEmpty else {
                    return .failure(.invalidArgument("content is required"), requestID: requestID)
                }
                let id = request.arguments["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let memoryID = (id?.isEmpty == false) ? id! : UUID().uuidString
                let sessionID = request.arguments["sessionID"]?.stringValue
                let kind = request.arguments["kind"]?.stringValue ?? "note"
                let record = request.arguments["record"] ?? .object([
                    "content": .string(content),
                    "kind": .string(kind),
                ])
                try store.upsertMemory(id: memoryID, sessionID: sessionID, kind: kind, content: content, record: record)
                return .success(.object(["id": .string(memoryID), "saved": .bool(true)]), requestID: requestID)

            case .memoryDelete:
                guard let id = request.arguments["id"]?.stringValue, !id.isEmpty else {
                    return .failure(.invalidArgument("id is required"), requestID: requestID)
                }
                try store.deleteMemory(id: id)
                return .success(.object(["id": .string(id), "deleted": .bool(true)]), requestID: requestID)

            case .agentTasksList:
                let sessionID = request.arguments["sessionID"]?.stringValue
                let limit = request.arguments["limit"]?.intValue ?? 50
                return .success(.array(try store.listAgentTasks(sessionID: sessionID, limit: limit)), requestID: requestID)

            case .agentTasksUpsert:
                guard let title = request.arguments["title"]?.stringValue, !title.isEmpty else {
                    return .failure(.invalidArgument("title is required"), requestID: requestID)
                }
                let id = request.arguments["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let taskID = (id?.isEmpty == false) ? id! : UUID().uuidString
                let sessionID = request.arguments["sessionID"]?.stringValue
                let state = request.arguments["state"]?.stringValue ?? "completed"
                let record = request.arguments["record"] ?? .object([:])
                try store.upsertAgentTask(id: taskID, sessionID: sessionID, title: title, state: state, record: record)
                return .success(.object(["id": .string(taskID), "saved": .bool(true)]), requestID: requestID)

            case .agentTasksDelete:
                guard let id = request.arguments["id"]?.stringValue, !id.isEmpty else {
                    return .failure(.invalidArgument("id is required"), requestID: requestID)
                }
                try store.deleteAgentTask(id: id)
                return .success(.object(["id": .string(id), "deleted": .bool(true)]), requestID: requestID)

            case .alarmList:
                let limit = request.arguments["limit"]?.intValue ?? 50
                return .success(.array(try store.listAlarms(limit: limit)), requestID: requestID)

            case .alarmUpsert:
                guard let title = request.arguments["title"]?.stringValue, !title.isEmpty else {
                    return .failure(.invalidArgument("title is required"), requestID: requestID)
                }
                let id = request.arguments["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let alarmID = (id?.isEmpty == false) ? id! : UUID().uuidString
                let enabled = request.arguments["enabled"]?.boolValue ?? true
                let record = request.arguments["record"] ?? .object([:])
                let fireAt: Date
                if let iso = request.arguments["fireAt"]?.stringValue, let parsed = ISO8601.date(from: iso) {
                    fireAt = parsed
                } else if let epoch = request.arguments["fireAtEpoch"]?.doubleValue {
                    fireAt = Date(timeIntervalSince1970: epoch)
                } else {
                    fireAt = Date().addingTimeInterval(3600)
                }
                try store.upsertAlarm(id: alarmID, title: title, fireAt: fireAt, enabled: enabled, record: record)
                return .success(.object(["id": .string(alarmID), "saved": .bool(true)]), requestID: requestID)

            case .alarmDelete:
                guard let id = request.arguments["id"]?.stringValue, !id.isEmpty else {
                    return .failure(.invalidArgument("id is required"), requestID: requestID)
                }
                try store.deleteAlarm(id: id)
                return .success(.object(["id": .string(id), "deleted": .bool(true)]), requestID: requestID)

            case .modulesList:
                let limit = request.arguments["limit"]?.intValue ?? 100
                return .success(.array(try store.listModules(limit: limit)), requestID: requestID)

            case .modulesSet:
                guard let id = request.arguments["id"]?.stringValue, !id.isEmpty else {
                    return .failure(.invalidArgument("id is required"), requestID: requestID)
                }
                let version = request.arguments["version"]?.stringValue ?? "1"
                let enabled = request.arguments["enabled"]?.boolValue ?? true
                let record = request.arguments["record"] ?? .object([:])
                try store.upsertModule(id: id, version: version, enabled: enabled, record: record)
                return .success(.object(["id": .string(id), "saved": .bool(true)]), requestID: requestID)

            case .runsList:
                let agentID = request.arguments["agentID"]?.stringValue
                let limit = request.arguments["limit"]?.intValue ?? 50
                return .success(.array(try store.listRuns(agentID: agentID, limit: limit)), requestID: requestID)

            case .runsUpsert:
                guard let id = request.arguments["id"]?.stringValue, !id.isEmpty else {
                    return .failure(.invalidArgument("id is required"), requestID: requestID)
                }
                let agentID = request.arguments["agentID"]?.stringValue ?? "default"
                let state = request.arguments["state"]?.stringValue ?? "unknown"
                let record = request.arguments["record"] ?? .object([:])
                try store.upsertRun(id: id, agentID: agentID, state: state, record: record)
                return .success(.object(["id": .string(id), "saved": .bool(true), "state": .string(state)]), requestID: requestID)

            case .knowledgeDocumentsList:
                let limit = request.arguments["limit"]?.intValue ?? 50
                return .success(.array(try store.listKnowledgeDocuments(limit: limit)), requestID: requestID)

            case .knowledgeDocumentsUpsert:
                guard let title = request.arguments["title"]?.stringValue, !title.isEmpty else {
                    return .failure(.invalidArgument("title is required"), requestID: requestID)
                }
                let id = request.arguments["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let docID = (id?.isEmpty == false) ? id! : UUID().uuidString
                var recordObject = request.arguments["record"]?.objectValue ?? ["title": .string(title)]
                recordObject["title"] = .string(title)
                if let body = request.arguments["body"]?.stringValue ?? request.arguments["text"]?.stringValue {
                    recordObject["body"] = .string(body)
                }
                let record = JSONValue.object(recordObject)
                try store.upsertKnowledgeDocument(id: docID, title: title, record: record)
                return .success(.object(["id": .string(docID), "saved": .bool(true)]), requestID: requestID)

            case .knowledgeDocumentsDelete:
                guard let id = request.arguments["id"]?.stringValue, !id.isEmpty else {
                    return .failure(.invalidArgument("id is required"), requestID: requestID)
                }
                try store.deleteKnowledgeDocument(id: id)
                return .success(.object(["id": .string(id), "deleted": .bool(true)]), requestID: requestID)

            case .subscriptionsList:
                let limit = request.arguments["limit"]?.intValue ?? 50
                return .success(.array(try store.listSubscriptions(limit: limit)), requestID: requestID)

            case .subscriptionsUpsert:
                guard let informationType = request.arguments["informationType"]?.stringValue, !informationType.isEmpty else {
                    return .failure(.invalidArgument("informationType is required"), requestID: requestID)
                }
                let id = request.arguments["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let subID = (id?.isEmpty == false) ? id! : UUID().uuidString
                let active = request.arguments["active"]?.boolValue ?? true
                let record = request.arguments["record"] ?? .object([:])
                try store.upsertSubscription(id: subID, informationType: informationType, active: active, record: record)
                return .success(.object(["id": .string(subID), "saved": .bool(true)]), requestID: requestID)

            case .contextSnapshotsList:
                let agentID = request.arguments["agentID"]?.stringValue
                let limit = request.arguments["limit"]?.intValue ?? 50
                return .success(.array(try store.listContextSnapshots(agentID: agentID, limit: limit)), requestID: requestID)

            case .contextSnapshotsUpsert:
                let id = request.arguments["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let snapshotID = (id?.isEmpty == false) ? id! : UUID().uuidString
                let agentID = request.arguments["agentID"]?.stringValue ?? "default"
                let record = request.arguments["record"] ?? .object([:])
                try store.upsertContextSnapshot(id: snapshotID, agentID: agentID, record: record)
                return .success(.object(["id": .string(snapshotID), "saved": .bool(true)]), requestID: requestID)

            case .cancellationsList:
                let limit = request.arguments["limit"]?.intValue ?? 50
                return .success(.array(try store.listCancellations(limit: limit)), requestID: requestID)

            case .cancellationsUpsert:
                let rawID = request.arguments["cancellationID"]?.stringValue
                    ?? request.arguments["id"]?.stringValue
                let trimmed = rawID?.trimmingCharacters(in: .whitespacesAndNewlines)
                let cancellationID = (trimmed?.isEmpty == false) ? trimmed! : UUID().uuidString
                let requestIDValue = request.arguments["requestID"]?.stringValue ?? request.id
                let state = request.arguments["state"]?.stringValue ?? "requested"
                let record = request.arguments["record"] ?? .object([:])
                try store.upsertCancellation(
                    cancellationID: cancellationID,
                    requestID: requestIDValue,
                    state: state,
                    record: record
                )
                return .success(.object([
                    "cancellationID": .string(cancellationID),
                    "saved": .bool(true),
                    "state": .string(state),
                ]), requestID: requestID)

            case .capabilityDelegationsList:
                let limit = request.arguments["limit"]?.intValue ?? 50
                return .success(.array(try store.listCapabilityDelegations(limit: limit)), requestID: requestID)

            case .capabilityDelegationsUpsert:
                let id = request.arguments["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let delegationID = (id?.isEmpty == false) ? id! : UUID().uuidString
                let requestIDValue = request.arguments["requestID"]?.stringValue ?? request.id
                guard let delegatee = request.arguments["delegatee"]?.stringValue, !delegatee.isEmpty else {
                    return .failure(.invalidArgument("delegatee is required"), requestID: requestID)
                }
                var expiresAt: Date?
                if let iso = request.arguments["expiresAt"]?.stringValue, let parsed = ISO8601.date(from: iso) {
                    expiresAt = parsed
                } else if let epoch = request.arguments["expiresAtEpoch"]?.doubleValue {
                    expiresAt = Date(timeIntervalSince1970: epoch)
                }
                let record = request.arguments["record"] ?? .object([:])
                try store.upsertCapabilityDelegation(
                    id: delegationID,
                    requestID: requestIDValue,
                    delegatee: delegatee,
                    expiresAt: expiresAt,
                    record: record
                )
                return .success(.object(["id": .string(delegationID), "saved": .bool(true)]), requestID: requestID)

            case .informationRevisionsList:
                let informationID = request.arguments["informationID"]?.stringValue
                let limit = request.arguments["limit"]?.intValue ?? 50
                return .success(.array(try store.listInformationRevisions(informationID: informationID, limit: limit)), requestID: requestID)

            case .informationRevisionsUpsert:
                let rawID = request.arguments["revisionID"]?.stringValue
                    ?? request.arguments["id"]?.stringValue
                let trimmed = rawID?.trimmingCharacters(in: .whitespacesAndNewlines)
                let revisionID = (trimmed?.isEmpty == false) ? trimmed! : UUID().uuidString
                guard let informationID = request.arguments["informationID"]?.stringValue, !informationID.isEmpty else {
                    return .failure(.invalidArgument("informationID is required"), requestID: requestID)
                }
                let type = request.arguments["type"]?.stringValue ?? "note"
                let namespace = request.arguments["namespace"]?.stringValue ?? "default"
                let owner = request.arguments["owner"]?.stringValue ?? request.principal
                let observedAt: Date
                if let iso = request.arguments["observedAt"]?.stringValue, let parsed = ISO8601.date(from: iso) {
                    observedAt = parsed
                } else if let epoch = request.arguments["observedAtEpoch"]?.doubleValue {
                    observedAt = Date(timeIntervalSince1970: epoch)
                } else {
                    observedAt = Date()
                }
                let record = request.arguments["record"] ?? .object([:])
                try store.upsertInformationRevision(
                    revisionID: revisionID,
                    informationID: informationID,
                    type: type,
                    namespace: namespace,
                    owner: owner,
                    observedAt: observedAt,
                    record: record
                )
                return .success(.object(["revisionID": .string(revisionID), "saved": .bool(true)]), requestID: requestID)

            case .toolArtifactsList:
                let projectID = request.arguments["projectID"]?.stringValue
                let limit = request.arguments["limit"]?.intValue ?? 50
                return .success(.array(try store.listToolArtifacts(projectID: projectID, limit: limit)), requestID: requestID)

            case .toolArtifactsUpsert:
                let id = request.arguments["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let artifactID = (id?.isEmpty == false) ? id! : UUID().uuidString
                let projectID = request.arguments["projectID"]?.stringValue ?? "default"
                let enabled = request.arguments["enabled"]?.boolValue ?? true
                let builtAt: Date
                if let iso = request.arguments["builtAt"]?.stringValue, let parsed = ISO8601.date(from: iso) {
                    builtAt = parsed
                } else if let epoch = request.arguments["builtAtEpoch"]?.doubleValue {
                    builtAt = Date(timeIntervalSince1970: epoch)
                } else {
                    builtAt = Date()
                }
                let record = request.arguments["record"] ?? .object([:])
                try store.upsertToolArtifact(
                    id: artifactID,
                    projectID: projectID,
                    enabled: enabled,
                    builtAt: builtAt,
                    record: record
                )
                return .success(.object(["id": .string(artifactID), "saved": .bool(true)]), requestID: requestID)

            case .informationTypesList:
                let limit = request.arguments["limit"]?.intValue ?? 100
                return .success(.array(try store.listInformationTypes(limit: limit)), requestID: requestID)

            case .informationTypesUpsert:
                guard let typeID = request.arguments["typeID"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !typeID.isEmpty else {
                    return .failure(.invalidArgument("typeID is required"), requestID: requestID)
                }
                let schemaVersion = request.arguments["schemaVersion"]?.intValue ?? 1
                let record = request.arguments["record"] ?? .object([:])
                try store.upsertInformationType(typeID: typeID, schemaVersion: schemaVersion, record: record)
                return .success(.object([
                    "typeID": .string(typeID),
                    "schemaVersion": .number(Double(schemaVersion)),
                    "saved": .bool(true),
                ]), requestID: requestID)

            case .informationHeadsList:
                let limit = request.arguments["limit"]?.intValue ?? 100
                return .success(.array(try store.listInformationHeads(limit: limit)), requestID: requestID)

            case .informationHeadsSet:
                guard let informationID = request.arguments["informationID"]?.stringValue, !informationID.isEmpty else {
                    return .failure(.invalidArgument("informationID is required"), requestID: requestID)
                }
                guard let revisionID = request.arguments["revisionID"]?.stringValue, !revisionID.isEmpty else {
                    return .failure(.invalidArgument("revisionID is required"), requestID: requestID)
                }
                try store.setInformationHead(informationID: informationID, revisionID: revisionID)
                return .success(.object([
                    "informationID": .string(informationID),
                    "revisionID": .string(revisionID),
                    "saved": .bool(true),
                ]), requestID: requestID)

            case .informationProcessorsList:
                let limit = request.arguments["limit"]?.intValue ?? 100
                return .success(.array(try store.listInformationProcessors(limit: limit)), requestID: requestID)

            case .informationProcessorsUpsert:
                let raw = request.arguments["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let processorID = (raw?.isEmpty == false) ? raw! : UUID().uuidString
                let moduleID = request.arguments["moduleID"]?.stringValue ?? "default"
                let capability = request.arguments["capability"]?.stringValue ?? "*"
                let priority = request.arguments["priority"]?.intValue ?? 0
                let record = request.arguments["record"] ?? .object([:])
                try store.upsertInformationProcessor(
                    id: processorID,
                    moduleID: moduleID,
                    capability: capability,
                    priority: priority,
                    record: record
                )
                return .success(.object(["id": .string(processorID), "saved": .bool(true)]), requestID: requestID)

            case .deliveriesList:
                let subscriptionID = request.arguments["subscriptionID"]?.stringValue
                let limit = request.arguments["limit"]?.intValue ?? 50
                return .success(.array(try store.listDeliveries(subscriptionID: subscriptionID, limit: limit)), requestID: requestID)

            case .deliveriesUpsert:
                let raw = request.arguments["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let deliveryID = (raw?.isEmpty == false) ? raw! : UUID().uuidString
                let subscriptionID = request.arguments["subscriptionID"]?.stringValue ?? ""
                let revisionID = request.arguments["revisionID"]?.stringValue ?? ""
                let state = request.arguments["state"]?.stringValue ?? "pending"
                let record = request.arguments["record"] ?? .object([:])
                try store.upsertDelivery(
                    id: deliveryID,
                    subscriptionID: subscriptionID,
                    revisionID: revisionID,
                    state: state,
                    record: record
                )
                return .success(.object(["id": .string(deliveryID), "saved": .bool(true)]), requestID: requestID)

            case .situationsList:
                let limit = request.arguments["limit"]?.intValue ?? 50
                return .success(.array(try store.listSituations(limit: limit)), requestID: requestID)

            case .situationsUpsert:
                let raw = request.arguments["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let situationID = (raw?.isEmpty == false) ? raw! : UUID().uuidString
                let record = request.arguments["record"] ?? .object([:])
                try store.upsertSituation(id: situationID, record: record)
                return .success(.object(["id": .string(situationID), "saved": .bool(true)]), requestID: requestID)

            case .selfHealingEventsList:
                let limit = request.arguments["limit"]?.intValue ?? 50
                return .success(.array(try store.listSelfHealingEvents(limit: limit)), requestID: requestID)

            case .selfHealingEventsAppend:
                let kind = request.arguments["kind"]?.stringValue ?? "note"
                let record = request.arguments["record"] ?? .object([:])
                let id = request.arguments["id"]?.stringValue
                try store.appendSelfHealingEvent(id: id, kind: kind, record: record)
                return .success(.object(["kind": .string(kind), "appended": .bool(true)]), requestID: requestID)

            case .kernelStoreStats:
                let counts = try store.tableCounts()
                var object: [String: JSONValue] = [:]
                for (table, count) in counts.sorted(by: { $0.key < $1.key }) {
                    object[table] = .number(Double(count))
                }
                return .success(.object([
                    "tables": .object(object),
                    "tableCount": .number(Double(counts.count)),
                ]), requestID: requestID)

            case .runtimeLedgerTables:
                return .success(.array(KernelStore.runtimeLedgerTables.map { .string($0) }), requestID: requestID)

            case .runtimeLedgerList:
                guard let table = request.arguments["table"]?.stringValue, !table.isEmpty else {
                    return .failure(.invalidArgument("table is required"), requestID: requestID)
                }
                let limit = request.arguments["limit"]?.intValue ?? 50
                return .success(.array(try store.listRuntimeLedger(table: table, limit: limit)), requestID: requestID)

            case .runtimeLedgerUpsert:
                guard let table = request.arguments["table"]?.stringValue, !table.isEmpty else {
                    return .failure(.invalidArgument("table is required"), requestID: requestID)
                }
                let id = request.arguments["id"]?.stringValue
                let record = request.arguments["record"] ?? .object([:])
                let saved = try store.upsertRuntimeLedger(table: table, id: id, record: record)
                return .success(.object([
                    "table": .string(table),
                    "id": .string(saved),
                    "saved": .bool(true),
                ]), requestID: requestID)

            case .runtimeLedgerDelete:
                guard let table = request.arguments["table"]?.stringValue, !table.isEmpty else {
                    return .failure(.invalidArgument("table is required"), requestID: requestID)
                }
                guard let id = request.arguments["id"]?.stringValue, !id.isEmpty else {
                    return .failure(.invalidArgument("id is required"), requestID: requestID)
                }
                try store.deleteRuntimeLedger(table: table, id: id)
                return .success(.object([
                    "table": .string(table),
                    "id": .string(id),
                    "deleted": .bool(true),
                ]), requestID: requestID)

            // MARK: WeChat
            case .runtimeWeChatStatus, .wechatLoginStatus, .wechatConnectionRead, .wechatConnections:
                return .success(try wechat.status(), requestID: requestID)

            case .runtimeWeChatConnect, .wechatLoginStart:
                return .success(try await wechat.connect(), requestID: requestID)

            case .runtimeWeChatDisconnect:
                return .success(try wechat.disconnect(), requestID: requestID)

            case .runtimeWeChatVerify, .wechatLoginVerify:
                let code = request.arguments["code"]?.stringValue
                    ?? request.arguments["verificationCode"]?.stringValue
                    ?? ""
                return .success(try wechat.verify(code: code), requestID: requestID)

            case .runtimeWeChatSendText:
                let text = request.arguments["text"]?.stringValue ?? ""
                let suppress = request.arguments["suppressAck"]?.boolValue ?? false
                return .success(try wechat.sendText(text: text, suppressAck: suppress), requestID: requestID)

            case .runtimeWeChatSendFile:
                let path = request.arguments["path"]?.stringValue
                    ?? request.arguments["filePath"]?.stringValue
                    ?? ""
                let suppress = request.arguments["suppressTextReplyOnSuccess"]?.boolValue ?? false
                return .success(try wechat.sendFile(path: path, suppressTextReplyOnSuccess: suppress), requestID: requestID)

            case .wechatConnectionList:
                return .success(try wechat.listConnections(), requestID: requestID)

            case .wechatConnectionRemove:
                let id = request.arguments["id"]?.stringValue
                    ?? request.arguments["connectionID"]?.stringValue
                    ?? ""
                return .success(try wechat.removeConnection(id: id), requestID: requestID)

            case .wechatConnectionManage, .wechatLoginEvents:
                // Manage/events: status + connections summary (credential-free).
                let status = try wechat.status()
                let list = try wechat.listConnections()
                return .success(.object([
                    "status": status,
                    "connections": list["connections"] ?? .array([]),
                ]), requestID: requestID)

            // MARK: Feishu
            case .runtimeFeishuStatus, .feishuConnectionStatus, .feishuConnectionRead:
                return .success(try feishu.status(), requestID: requestID)

            case .runtimeFeishuConnect:
                return .success(try await feishu.connect(), requestID: requestID)

            case .runtimeFeishuDisconnect, .feishuConnectionDisconnect:
                return .success(try feishu.disconnect(), requestID: requestID)

            case .runtimeFeishuSession:
                return .success(try feishu.session(), requestID: requestID)

            case .runtimeFeishuSendText:
                let text = request.arguments["text"]?.stringValue ?? ""
                let receiveID = request.arguments["receiveID"]?.stringValue
                    ?? request.arguments["receive_id"]?.stringValue
                let receiveType = request.arguments["receiveIDType"]?.stringValue
                    ?? request.arguments["receive_id_type"]?.stringValue
                    ?? "open_id"
                return .success(
                    try await feishu.sendTextAsync(text: text, receiveID: receiveID, receiveIDType: receiveType),
                    requestID: requestID
                )

            case .feishuConfigurationOpen:
                return .success(try feishu.openConfiguration(), requestID: requestID)

            case .feishuConfigurationCancel:
                return .success(try feishu.cancelConfiguration(), requestID: requestID)

            case .feishuConnectionConfigure, .feishuConnectionManage:
                return .success(try feishu.configure(
                    appID: request.arguments["appId"]?.stringValue ?? request.arguments["app_id"]?.stringValue,
                    appSecret: request.arguments["appSecret"]?.stringValue ?? request.arguments["app_secret"]?.stringValue,
                    verificationToken: request.arguments["verificationToken"]?.stringValue
                        ?? request.arguments["verification_token"]?.stringValue
                ), requestID: requestID)

            case .runtimeKnowledgeImportFeishu:
                return .success(feishu.importKnowledgeStub(), requestID: requestID)

            case .speechSynthesize:
                return await Self.synthesizeSpeech(request: request, store: store)

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

    // MARK: - Speech

    private static func synthesizeSpeech(request: KernelRequest, store: KernelStore) async -> KernelResponse {
        let requestID = request.id
        guard let text = request.arguments["text"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .failure(.invalidArgument("text is required"), requestID: requestID)
        }

        let profile = (try? store.defaultSpeechProfile()) ?? .object([:])
        let record = profile["record"] ?? .object([:])
        let provider = (
            request.arguments["providerID"]?.stringValue
                ?? profile["providerID"]?.stringValue
                ?? record["provider"]?.stringValue
                ?? "system"
        ).lowercased()

        if provider != "volcengine" {
            return .success(.object([
                "provider": .string("system"),
                "fallback": .bool(true),
                "reason": .string("provider_is_system"),
            ]), requestID: requestID)
        }

        guard let credentials = store.resolvedVolcengineCredentials() else {
            FileHandle.standardError.write(Data("lucasd: speech.synthesize volcengine credentials missing → system fallback\n".utf8))
            return .success(.object([
                "provider": .string("system"),
                "fallback": .bool(true),
                "reason": .string("missing_credentials"),
            ]), requestID: requestID)
        }

        let voiceType = request.arguments["voiceType"]?.stringValue
            ?? record["volcengineVoiceType"]?.stringValue
            ?? "BV001_streaming"
        let cluster = request.arguments["cluster"]?.stringValue
            ?? record["volcengineCluster"]?.stringValue
            ?? "volcano_tts"
        let speed = request.arguments["speedRatio"]?.doubleValue
            ?? record["rate"]?.doubleValue.map { max(0.1, min(2.0, $0 * 2.0)) }
            ?? 1.0

        do {
            let result = try await VolcengineTTS.synthesize(
                text: text,
                appID: credentials.appID,
                token: credentials.token,
                voiceType: voiceType,
                cluster: cluster,
                encoding: "mp3",
                speedRatio: speed
            )
            return .success(.object([
                "provider": .string("volcengine"),
                "fallback": .bool(false),
                "encoding": .string(result.encoding),
                "data": .string(result.audioBase64),
                "reqID": .string(result.reqID),
            ]), requestID: requestID)
        } catch {
            let message = String(describing: error)
            FileHandle.standardError.write(Data("lucasd: speech.synthesize failed (\(message)) → system fallback\n".utf8))
            return .success(.object([
                "provider": .string("system"),
                "fallback": .bool(true),
                "reason": .string(message),
            ]), requestID: requestID)
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
