import JaplosProtocol

/// RPC names that stay in the schema for existing databases, but are no longer served.
/// Tables are not dropped. The App uses the canonical `runtime.*` names that remain.
enum KernelRetiredOperations {
    static let all: Set<KernelOperation> = [
        .chatTurnAppend,
        .informationRevisionsList,
        .informationRevisionsUpsert,
        .informationTypesList,
        .informationTypesUpsert,
        .informationHeadsList,
        .informationHeadsSet,
        .informationProcessorsList,
        .informationProcessorsUpsert,
        .runtimeLedgerList,
        .runtimeLedgerUpsert,
        .runtimeLedgerDelete,
        .runtimeLedgerTables,
        .runtimeKnowledgeImportFeishu,
        .runtimeWeChatSendText,
        .runtimeWeChatSendFile,
        .wechatLoginStart,
        .wechatLoginStatus,
        .wechatLoginVerify,
        .wechatLoginEvents,
        .wechatConnectionManage,
        .wechatConnectionRead,
        .wechatConnections,
        .feishuConnectionStatus,
        .feishuConnectionRead,
        .feishuConnectionDisconnect,
        .feishuConnectionManage,
        .mailConnectionStatus,
        .mailConnectionConfigure,
        .mailConnectionConnect,
        .mailConnectionDisconnect,
        // Q1: unused ledgers stay in the schema, but the RPC is no longer served.
        // `context.snapshots.upsert` is intentionally kept: the App writes it.
        .deliveriesList,
        .deliveriesUpsert,
        .situationsList,
        .situationsUpsert,
        .subscriptionsList,
        .subscriptionsUpsert,
        .capabilityDelegationsList,
        .capabilityDelegationsUpsert,
        .contextSnapshotsList,
        .toolArtifactsList,
        .toolArtifactsUpsert,
        .modulesList,
        .modulesSet,
    ]
}
