import Foundation
import JaplosProtocol

public struct ToolContext: Sendable {
    public var sessionID: String?
    public var workspace: URL

    public init(sessionID: String? = nil, workspace: URL) {
        self.sessionID = sessionID
        self.workspace = workspace
    }
}

public protocol KernelTool: Sendable {
    var definition: ToolDefinition { get }
    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue
}

public enum ToolError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case failed(String)
    case denied(String)
    case timedOut

    public var description: String {
        switch self {
        case .invalidArguments(let message): return "Invalid arguments: \(message)"
        case .failed(let message): return message
        case .denied(let message): return "Denied: \(message)"
        case .timedOut: return "Tool timed out"
        }
    }
}

public final class ToolRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tools: [String: any KernelTool] = [:]

    public init() {}

    public func register(_ tool: any KernelTool) {
        lock.lock()
        defer { lock.unlock() }
        tools[tool.definition.name] = tool
    }

    public func register(contentsOf list: [any KernelTool]) {
        for tool in list { register(tool) }
    }

    public func definitions() -> [ToolDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return tools.values.map(\.definition).sorted { $0.name < $1.name }
    }

    public func definition(named name: String) -> ToolDefinition? {
        lock.lock()
        defer { lock.unlock() }
        return tools[name]?.definition
    }

    public func invoke(_ call: ToolCall, context: ToolContext) async -> ToolExecution {
        lock.lock()
        let tool = tools[call.name]
        lock.unlock()

        guard let tool else {
            return ToolExecution(
                call: call,
                ok: false,
                output: .null,
                error: "Unknown tool: \(call.name)"
            )
        }

        let started = Date()
        do {
            let output = try await tool.invoke(arguments: call.arguments, context: context)
            return ToolExecution(
                call: call,
                ok: true,
                output: output,
                durationMilliseconds: Date().timeIntervalSince(started) * 1000
            )
        } catch {
            return ToolExecution(
                call: call,
                ok: false,
                output: .null,
                error: String(describing: error),
                durationMilliseconds: Date().timeIntervalSince(started) * 1000
            )
        }
    }
}
