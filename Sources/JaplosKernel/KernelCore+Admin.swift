import Foundation
import JaplosProtocol

/// Admin operations, moved out of the dispatch switch so `KernelCore`
/// only gates policy and routes. Behaviour is unchanged.
extension KernelCore {
    func handleAdminOperations(_ request: KernelRequest) async throws -> KernelResponse {
        let requestID = request.id
        switch request.operation {
            case .kernelStatus:
                let stats = try store.statistics()
                return .success(.object([
                    "version": .string(version),
                    "build": .string(ProductBuild.current),
                    "pid": .number(Double(getpid())),
                    "executable": .object([
                        "path": .string(ProductBuild.executablePath),
                        "modifiedAt": ProductBuild.executableModifiedAt.map(JSONValue.number) ?? .null,
                    ]),
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
                requestShutdown()?()
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

            // MARK: WeChat

        default:
            return .failure(.notFound("Unhandled admin operation \(request.operation.rawValue)"), requestID: requestID)
        }
    }
}
