import Foundation
import JaplosProtocol

/// Tool and MCP operations, moved out of the dispatch switch.
extension KernelCore {
    func handleToolsOperations(_ request: KernelRequest) async throws -> KernelResponse {
        let requestID = request.id
        switch request.operation {
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
            case .toolInvoke:
                return await invokeTool(request)

        default:
            return .failure(.notFound("Unhandled tools operation \(request.operation.rawValue)"), requestID: requestID)
        }
    }
}
