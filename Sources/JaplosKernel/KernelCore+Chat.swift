import Foundation
import JaplosProtocol

/// Chat operations, moved out of the dispatch switch so `KernelCore`
/// only gates policy and routes. Behaviour is unchanged.
extension KernelCore {
    func handleChatOperations(_ request: KernelRequest) async throws -> KernelResponse {
        let requestID = request.id
        switch request.operation {
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
            case .chatSend:
                let handler = chatHandlerClosure
                guard let handler else {
                    return .failure(.internalError("Chat runtime is not configured"), requestID: requestID)
                }
                return await handler(request)

        default:
            return .failure(.notFound("Unhandled chat operation \(request.operation.rawValue)"), requestID: requestID)
        }
    }
}
