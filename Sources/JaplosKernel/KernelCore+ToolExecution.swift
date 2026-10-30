import Foundation
import JaplosProtocol

/// Tool execution shared by `tool.invoke` and the streaming chat loop.
extension KernelCore {

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

    func invokeTool(_ request: KernelRequest) async -> KernelResponse {
        let requestID = request.id
        guard
            let name = request.arguments["name"]?.stringValue,
            let toolDefinition = definition(named: name)
        else {
            return .failure(.invalidArgument("Unknown tool name"), requestID: requestID)
        }

        let call = ToolCall(
            id: request.arguments["callID"]?.stringValue ?? UUID().uuidString,
            name: name,
            arguments: request.arguments["arguments"] ?? .object([:])
        )
        // tool.invoke RPC has no ApprovalBroker stream — same gate as chat, deny side-effects.
        if ToolApprovalGate.requiresApproval(call: call, definition: toolDefinition) {
            let denied = ToolExecution(
                call: call,
                ok: false,
                output: .null,
                error: "approval_required: tool.invoke 不能绕过审批闸；请走流式 chat.send 由 ApprovalBroker 决策"
            )
            return .success(Self.encode(execution: denied), requestID: requestID)
        }
        let sessionID = request.arguments["sessionID"]?.stringValue
        let execution = await executeTool(call, sessionID: sessionID, principal: request.principal)
        return .success(Self.encode(execution: execution), requestID: requestID)
    }

    public func enrichedWeChatStatus() -> JSONValue {
        let base = (try? wechat.status()) ?? .object([:])
        var object = base.objectValue ?? [:]
        for (key, value) in wechatApprovalBridge.statusExtras() {
            object[key] = value
        }
        return .object(object)
    }
}
