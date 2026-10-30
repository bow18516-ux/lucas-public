import Foundation

public enum Capability {
    public static let root = "kernel.root@1"
    public static let chatRead = "chat.read@1"
    public static let chatManage = "chat.manage@1"
    public static let modelInvoke = "model.invoke@1"
    public static let toolRead = "tool.read@1"
    public static let toolManage = "tool.manage@1"
    public static let toolInvoke = "tool.invoke@1"
    public static let policyRead = "policy.read@1"
    public static let policyManage = "policy.manage@1"
    public static let filesystemRead = "filesystem.read@1"
    public static let filesystemWrite = "filesystem.write@1"
    public static let processExecute = "process.execute@1"
    public static let screenCapture = "screen.capture@1"
    public static let clipboardRead = "clipboard.read@1"
    public static let clipboardWrite = "clipboard.write@1"
    public static let applicationsControl = "applications.control@1"
    public static let musicControl = "music.control@1"
    public static let audioControl = "audio.control@1"
    public static let systemRead = "system.read@1"
    public static let notificationSend = "notification.send@1"
    public static let channelRead = "channel.read@1"
    public static let channelManage = "channel.manage@1"
}

public struct PermissionGrant: Codable, Sendable, Equatable {
    public var id: String
    public var principal: String
    public var capability: String
    public var resourcePattern: String
    public var expiresAt: Date?
    public var revokedAt: Date?
    public var constraints: JSONValue?

    public init(
        id: String = UUID().uuidString,
        principal: String,
        capability: String,
        resourcePattern: String = "*",
        expiresAt: Date? = nil,
        revokedAt: Date? = nil,
        constraints: JSONValue? = nil
    ) {
        self.id = id
        self.principal = principal
        self.capability = capability
        self.resourcePattern = resourcePattern
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
        self.constraints = constraints
    }

    public func isActive(at date: Date = Date()) -> Bool {
        if revokedAt != nil { return false }
        if let expiresAt, expiresAt <= date { return false }
        return true
    }
}

public enum PolicyOutcome: String, Codable, Sendable {
    case allow
    case deny
}

public struct PolicyDecision: Codable, Sendable {
    public var outcome: PolicyOutcome
    public var principal: String
    public var capability: String
    public var resource: String
    public var reasonCode: String
    public var message: String
    public var grantID: String?
    public var decidedAt: Date

    public init(
        outcome: PolicyOutcome,
        principal: String,
        capability: String,
        resource: String,
        reasonCode: String,
        message: String,
        grantID: String? = nil,
        decidedAt: Date = Date()
    ) {
        self.outcome = outcome
        self.principal = principal
        self.capability = capability
        self.resource = resource
        self.reasonCode = reasonCode
        self.message = message
        self.grantID = grantID
        self.decidedAt = decidedAt
    }
}

public enum CapabilityRouting {
    /// Capability required for each kernel operation.
    public static func capability(for operation: KernelOperation) -> String {
        switch operation {
        case .kernelStatus, .kernelPing:
            return Capability.root
        case .kernelShutdown, .policyGrantsList, .policyEvaluate:
            return Capability.root
        case .configurationList, .configurationSet, .configurationHistory:
            return Capability.root
        case .chatSessionCreate, .chatSessionsList, .chatSessionRename,
             .chatTurnAppend, .chatSend:
            return Capability.chatManage
        case .chatHistory:
            return Capability.chatRead
        case .toolList:
            return Capability.toolRead
        case .toolInvoke:
            return Capability.toolInvoke
        case .toolApproval:
            return Capability.chatManage
        case .mcpStatus, .mcpEventsList:
            return Capability.toolRead
        case .mcpRefresh:
            return Capability.toolManage
        case .memoryList, .agentTasksList, .alarmList,
             .modulesList, .runsList, .knowledgeDocumentsList, .subscriptionsList,
             .contextSnapshotsList, .cancellationsList, .capabilityDelegationsList,
             .informationRevisionsList, .toolArtifactsList,
             .informationTypesList, .informationHeadsList, .informationProcessorsList,
             .deliveriesList, .situationsList, .selfHealingEventsList, .kernelStoreStats,
             .runtimeLedgerList, .runtimeLedgerTables:
            return Capability.chatRead
        case .memoryUpsert, .memoryDelete, .agentTasksUpsert, .agentTasksDelete,
             .alarmUpsert, .alarmDelete,
             .modulesSet, .runsUpsert,
             .knowledgeDocumentsUpsert, .knowledgeDocumentsDelete,
             .subscriptionsUpsert,
             .contextSnapshotsUpsert, .cancellationsUpsert, .capabilityDelegationsUpsert,
             .informationRevisionsUpsert, .toolArtifactsUpsert,
             .informationTypesUpsert, .informationHeadsSet, .informationProcessorsUpsert,
             .deliveriesUpsert, .situationsUpsert, .selfHealingEventsAppend,
             .runtimeLedgerUpsert, .runtimeLedgerDelete:
            return Capability.chatManage
        case .modelTest, .modelCatalog, .modelRoutesList, .speechProfilesList, .speechSynthesize:
            return Capability.modelInvoke
        case .modelRoutesSet, .modelRoutesDelete, .speechProfilesSet:
            return Capability.root
        case .runtimeWeChatStatus, .wechatLoginStatus, .wechatLoginEvents,
             .wechatConnectionList, .wechatConnectionRead, .wechatConnections,
             .runtimeFeishuStatus, .runtimeFeishuSession,
             .feishuConnectionStatus, .feishuConnectionRead,
             .runtimeMailStatus, .mailConnectionStatus:
            return Capability.channelRead
        case .runtimeWeChatConnect, .runtimeWeChatDisconnect, .runtimeWeChatVerify,
             .runtimeWeChatSendText, .runtimeWeChatSendFile,
             .wechatLoginStart, .wechatLoginVerify,
             .wechatConnectionManage, .wechatConnectionRemove,
             .runtimeFeishuConnect, .runtimeFeishuDisconnect, .runtimeFeishuSendText,
             .feishuConfigurationOpen, .feishuConfigurationCancel,
             .feishuConnectionConfigure, .feishuConnectionDisconnect, .feishuConnectionManage,
             .runtimeKnowledgeImportFeishu,
             .runtimeMailConfigure, .runtimeMailConnect, .runtimeMailDisconnect, .runtimeMailClearSecrets,
             .mailConnectionConfigure, .mailConnectionConnect, .mailConnectionDisconnect:
            return Capability.channelManage
        default:
            return Capability.root
        }
    }
}

public enum GlobMatcher {
    /// Simple `*` wildcard matcher used for resource patterns.
    public static func matches(pattern: String, value: String) -> Bool {
        if pattern == "*" { return true }
        if !pattern.contains("*") { return pattern == value }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var cursor = value.startIndex
        for (index, part) in parts.enumerated() {
            if part.isEmpty { continue }
            if index == 0 {
                guard value.hasPrefix(part) else { return false }
                cursor = value.index(value.startIndex, offsetBy: part.count)
            } else if index == parts.count - 1 {
                guard value[cursor...].hasSuffix(part) else { return false }
                return true
            } else {
                guard let range = value.range(of: part, range: cursor..<value.endIndex) else { return false }
                cursor = range.upperBound
            }
        }
        return true
    }
}
