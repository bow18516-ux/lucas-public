import Foundation
import JaplosProtocol

/// Memory operations, moved out of the dispatch switch so `KernelCore`
/// only gates policy and routes. Behaviour is unchanged.
extension KernelCore {
    func handleMemoryOperations(_ request: KernelRequest) async throws -> KernelResponse {
        let requestID = request.id
        switch request.operation {
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

        default:
            return .failure(.notFound("Unhandled memory operation \(request.operation.rawValue)"), requestID: requestID)
        }
    }
}
