import Foundation

/// Operation identifiers are open strings on purpose: a daemon can add
/// operations without the client needing a new enum case.
public struct KernelOperation: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public extension KernelOperation {
    // Kernel lifecycle
    static let kernelStatus = KernelOperation("kernel.status")
    static let kernelPing = KernelOperation("kernel.ping")
    static let kernelShutdown = KernelOperation("kernel.shutdown")

    // Policy
    static let policyGrantsList = KernelOperation("policy.grants.list")
    static let policyEvaluate = KernelOperation("policy.evaluate")

    // Configuration
    static let configurationList = KernelOperation("configuration.list")
    static let configurationSet = KernelOperation("configuration.set")
    static let configurationHistory = KernelOperation("configuration.history")

    // Model routes / speech profiles (Japlos store clusters)
    static let modelRoutesList = KernelOperation("model.routes.list")
    static let modelRoutesSet = KernelOperation("model.routes.set")
    static let modelRoutesDelete = KernelOperation("model.routes.delete")
    static let speechProfilesList = KernelOperation("speech.profiles.list")
    static let speechProfilesSet = KernelOperation("speech.profiles.set")
    static let speechSynthesize = KernelOperation("speech.synthesize")

    // Chat
    static let chatSessionCreate = KernelOperation("chat.session.create")
    static let chatSessionsList = KernelOperation("chat.sessions.list")
    static let chatSessionRename = KernelOperation("chat.session.rename")
    static let chatHistory = KernelOperation("chat.history")
    static let chatSend = KernelOperation("chat.send")
    static let chatTurnAppend = KernelOperation("chat.turn.append")

    // Tools
    static let toolList = KernelOperation("tool.list")
    static let toolInvoke = KernelOperation("tool.invoke")
    /// Client -> kernel decision for a pending high-risk tool call.
    static let toolApproval = KernelOperation("tool.approval")

    // MCP
    static let mcpStatus = KernelOperation("mcp.status")
    static let mcpRefresh = KernelOperation("mcp.refresh")
    static let mcpEventsList = KernelOperation("mcp.events.list")

    // Memory / agent tasks / alarms (Japlos store clusters)
    static let memoryList = KernelOperation("memory.list")
    static let memoryUpsert = KernelOperation("memory.upsert")
    static let memoryDelete = KernelOperation("memory.delete")
    static let agentTasksList = KernelOperation("agent.tasks.list")
    static let agentTasksUpsert = KernelOperation("agent.tasks.upsert")
    static let agentTasksDelete = KernelOperation("agent.tasks.delete")
    static let alarmList = KernelOperation("alarm.list")
    static let alarmUpsert = KernelOperation("alarm.upsert")
    static let alarmDelete = KernelOperation("alarm.delete")

    // Modules / runs / knowledge / subscriptions
    static let modulesList = KernelOperation("modules.list")
    static let modulesSet = KernelOperation("modules.set")
    static let runsList = KernelOperation("runs.list")
    static let runsUpsert = KernelOperation("runs.upsert")
    static let knowledgeDocumentsList = KernelOperation("knowledge.documents.list")
    static let knowledgeDocumentsUpsert = KernelOperation("knowledge.documents.upsert")
    static let knowledgeDocumentsDelete = KernelOperation("knowledge.documents.delete")
    static let subscriptionsList = KernelOperation("subscriptions.list")
    static let subscriptionsUpsert = KernelOperation("subscriptions.upsert")

    // Context / cancellations / delegations / revisions / tool artifacts
    static let contextSnapshotsList = KernelOperation("context.snapshots.list")
    static let contextSnapshotsUpsert = KernelOperation("context.snapshots.upsert")
    static let cancellationsList = KernelOperation("cancellations.list")
    static let cancellationsUpsert = KernelOperation("cancellations.upsert")
    static let capabilityDelegationsList = KernelOperation("capability.delegations.list")
    static let capabilityDelegationsUpsert = KernelOperation("capability.delegations.upsert")
    static let informationRevisionsList = KernelOperation("information.revisions.list")
    static let informationRevisionsUpsert = KernelOperation("information.revisions.upsert")
    static let toolArtifactsList = KernelOperation("tool.artifacts.list")
    static let toolArtifactsUpsert = KernelOperation("tool.artifacts.upsert")

    // Information plane / deliveries / situations / self-healing (store v5)
    static let informationTypesList = KernelOperation("information.types.list")
    static let informationTypesUpsert = KernelOperation("information.types.upsert")
    static let informationHeadsList = KernelOperation("information.heads.list")
    static let informationHeadsSet = KernelOperation("information.heads.set")
    static let informationProcessorsList = KernelOperation("information.processors.list")
    static let informationProcessorsUpsert = KernelOperation("information.processors.upsert")
    static let deliveriesList = KernelOperation("deliveries.list")
    static let deliveriesUpsert = KernelOperation("deliveries.upsert")
    static let situationsList = KernelOperation("situations.list")
    static let situationsUpsert = KernelOperation("situations.upsert")
    static let selfHealingEventsList = KernelOperation("selfhealing.events.list")
    static let selfHealingEventsAppend = KernelOperation("selfhealing.events.append")
    static let kernelStoreStats = KernelOperation("kernel.store.stats")

    // Runtime ledgers (store v6 — whitelisted Japlos agent_runtime_* scaffolds)
    static let runtimeLedgerList = KernelOperation("runtime.ledger.list")
    static let runtimeLedgerUpsert = KernelOperation("runtime.ledger.upsert")
    static let runtimeLedgerDelete = KernelOperation("runtime.ledger.delete")
    static let runtimeLedgerTables = KernelOperation("runtime.ledger.tables")

    // Model
    static let modelTest = KernelOperation("model.test")
    static let modelCatalog = KernelOperation("model.catalog")
}

public struct KernelRequest: Codable, Sendable {
    public var protocolVersion: String
    public var id: String
    public var principal: String
    public var operation: KernelOperation
    public var resource: String?
    public var arguments: JSONValue
    public var reason: String?
    public var deadline: Date?
    public var idempotencyKey: String?
    public var correlationID: String?
    public var cancellationID: String?

    public init(
        protocolVersion: String = ProtocolVersion.current,
        id: String = UUID().uuidString,
        principal: String = Principal.localUser,
        operation: KernelOperation,
        resource: String? = nil,
        arguments: JSONValue = .object([:]),
        reason: String? = nil,
        deadline: Date? = nil,
        idempotencyKey: String? = nil,
        correlationID: String? = nil,
        cancellationID: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.principal = principal
        self.operation = operation
        self.resource = resource
        self.arguments = arguments
        self.reason = reason
        self.deadline = deadline
        self.idempotencyKey = idempotencyKey
        self.correlationID = correlationID
        self.cancellationID = cancellationID
    }
}

public struct KernelFailure: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var origin: String
    public var retryable: Bool
    public var details: JSONValue?

    public init(
        code: String,
        message: String,
        origin: String = "kernel",
        retryable: Bool = false,
        details: JSONValue? = nil
    ) {
        self.code = code
        self.message = message
        self.origin = origin
        self.retryable = retryable
        self.details = details
    }

    public static func invalidArgument(_ message: String) -> KernelFailure {
        KernelFailure(code: "invalid_argument", message: message)
    }

    public static func permissionDenied(_ message: String, details: JSONValue? = nil) -> KernelFailure {
        KernelFailure(code: "permission_denied", message: message, details: details)
    }

    public static func notFound(_ message: String) -> KernelFailure {
        KernelFailure(code: "not_found", message: message)
    }

    public static func internalError(_ message: String) -> KernelFailure {
        KernelFailure(code: "internal_error", message: message, retryable: true)
    }
}

public struct KernelResponse: Codable, Sendable {
    public var protocolVersion: String
    public var requestID: String
    public var result: JSONValue?
    public var failure: KernelFailure?
    /// Japlos envelope parity: plain string mirror of the failure message (kept alongside structured `failure`).
    public var error: String?
    public var servedAt: Date

    public init(
        protocolVersion: String = ProtocolVersion.current,
        requestID: String,
        result: JSONValue? = nil,
        failure: KernelFailure? = nil,
        error: String? = nil,
        servedAt: Date = Date()
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.result = result
        self.failure = failure
        self.error = error ?? failure?.message
        self.servedAt = servedAt
    }

    public static func success(_ result: JSONValue, requestID: String) -> KernelResponse {
        KernelResponse(requestID: requestID, result: result)
    }

    public static func failure(_ failure: KernelFailure, requestID: String) -> KernelResponse {
        KernelResponse(requestID: requestID, failure: failure, error: failure.message)
    }
}

public enum ProtocolVersion {
    public static let current = "1.0"
}

public enum Principal {
    /// The daemon bootstraps a root grant for whichever OS user owns the socket.
    public static let localUser = "local-user"
}
