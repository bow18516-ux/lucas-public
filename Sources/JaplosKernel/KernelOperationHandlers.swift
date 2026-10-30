import Foundation
import JaplosProtocol

/// One handler per domain. `KernelCore` only gates policy and routes here.
protocol KernelOperationHandler {
    var operations: Set<KernelOperation> { get }
    func handle(_ request: KernelRequest) async throws -> KernelResponse
}

struct AdminOperations: KernelOperationHandler {
    unowned let core: KernelCore

    let operations: Set<KernelOperation> = [
        .cancellationsList,
        .cancellationsUpsert,
        .capabilityDelegationsList,
        .capabilityDelegationsUpsert,
        .configurationHistory,
        .configurationList,
        .configurationSet,
        .contextSnapshotsList,
        .contextSnapshotsUpsert,
        .deliveriesList,
        .deliveriesUpsert,
        .kernelPing,
        .kernelShutdown,
        .kernelStatus,
        .kernelStoreStats,
        .modulesList,
        .modulesSet,
        .policyEvaluate,
        .policyGrantsList,
        .runsList,
        .runsUpsert,
        .selfHealingEventsAppend,
        .selfHealingEventsList,
        .situationsList,
        .situationsUpsert,
        .subscriptionsList,
        .subscriptionsUpsert,
        .toolArtifactsList,
        .toolArtifactsUpsert,
    ]

    func handle(_ request: KernelRequest) async throws -> KernelResponse {
        try await core.handleAdminOperations(request)
    }
}

struct ChatOperations: KernelOperationHandler {
    unowned let core: KernelCore

    let operations: Set<KernelOperation> = [
        .chatHistory,
        .chatSend,
        .chatSessionCreate,
        .chatSessionRename,
        .chatSessionsList,
    ]

    func handle(_ request: KernelRequest) async throws -> KernelResponse {
        try await core.handleChatOperations(request)
    }
}

struct MemoryOperations: KernelOperationHandler {
    unowned let core: KernelCore

    let operations: Set<KernelOperation> = [
        .agentTasksDelete,
        .agentTasksList,
        .agentTasksUpsert,
        .alarmDelete,
        .alarmList,
        .alarmUpsert,
        .memoryDelete,
        .memoryList,
        .memoryUpsert,
    ]

    func handle(_ request: KernelRequest) async throws -> KernelResponse {
        try await core.handleMemoryOperations(request)
    }
}

struct KnowledgeOperations: KernelOperationHandler {
    unowned let core: KernelCore

    let operations: Set<KernelOperation> = [
        .knowledgeDocumentsDelete,
        .knowledgeDocumentsList,
        .knowledgeDocumentsUpsert,
    ]

    func handle(_ request: KernelRequest) async throws -> KernelResponse {
        try await core.handleKnowledgeOperations(request)
    }
}

struct ChannelOperations: KernelOperationHandler {
    unowned let core: KernelCore

    let operations: Set<KernelOperation> = [
        .feishuConfigurationCancel,
        .feishuConfigurationOpen,
        .feishuConnectionConfigure,
        .runtimeFeishuConnect,
        .runtimeFeishuDisconnect,
        .runtimeFeishuSendText,
        .runtimeFeishuSession,
        .runtimeFeishuStatus,
        .runtimeMailClearSecrets,
        .runtimeMailConfigure,
        .runtimeMailConnect,
        .runtimeMailDisconnect,
        .runtimeMailStatus,
        .runtimeWeChatConnect,
        .runtimeWeChatDisconnect,
        .runtimeWeChatStatus,
        .runtimeWeChatVerify,
        .speechSynthesize,
        .wechatConnectionList,
        .wechatConnectionRemove,
    ]

    func handle(_ request: KernelRequest) async throws -> KernelResponse {
        try await core.handleChannelOperations(request)
    }
}

struct ModelOperations: KernelOperationHandler {
    unowned let core: KernelCore

    let operations: Set<KernelOperation> = [
        .modelCatalog,
        .modelRoutesDelete,
        .modelRoutesList,
        .modelRoutesSet,
        .modelTest,
        .speechProfilesList,
        .speechProfilesSet,
    ]

    func handle(_ request: KernelRequest) async throws -> KernelResponse {
        try await core.handleModelOperations(request)
    }
}

struct ToolsOperations: KernelOperationHandler {
    unowned let core: KernelCore

    let operations: Set<KernelOperation> = [
        .mcpEventsList,
        .mcpRefresh,
        .mcpStatus,
        .toolInvoke,
        .toolList,
    ]

    func handle(_ request: KernelRequest) async throws -> KernelResponse {
        try await core.handleToolsOperations(request)
    }
}
