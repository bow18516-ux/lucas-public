import Foundation

public enum ToolRisk: String, Codable, Sendable {
    case low
    case medium
    case high
}

public struct ToolDefinition: Codable, Sendable, Equatable {
    public var name: String
    public var title: String
    public var summary: String
    public var inputSchema: JSONValue
    public var capability: String
    public var risk: ToolRisk
    public var provider: String

    public init(
        name: String,
        title: String,
        summary: String,
        inputSchema: JSONValue,
        capability: String,
        risk: ToolRisk = .low,
        provider: String = "kernel"
    ) {
        self.name = name
        self.title = title
        self.summary = summary
        self.inputSchema = inputSchema
        self.capability = capability
        self.risk = risk
        self.provider = provider
    }
}

public struct ToolCall: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var arguments: JSONValue

    public init(id: String = UUID().uuidString, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolExecution: Codable, Sendable {
    public var call: ToolCall
    public var ok: Bool
    public var output: JSONValue
    public var error: String?
    public var durationMilliseconds: Double

    public init(
        call: ToolCall,
        ok: Bool,
        output: JSONValue,
        error: String? = nil,
        durationMilliseconds: Double = 0
    ) {
        self.call = call
        self.ok = ok
        self.output = output
        self.error = error
        self.durationMilliseconds = durationMilliseconds
    }
}

// MARK: - Conversation model

public enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct ChatTurn: Codable, Sendable, Equatable {
    public var id: String
    public var sessionID: String
    public var role: ChatRole
    public var text: String
    public var toolCalls: [ToolCall]
    public var toolCallID: String?
    public var toolName: String?
    public var createdAt: Date
    public var metadata: JSONValue?

    public init(
        id: String = UUID().uuidString,
        sessionID: String,
        role: ChatRole,
        text: String,
        toolCalls: [ToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil,
        createdAt: Date = Date(),
        metadata: JSONValue? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

public struct ChatSession: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String = "新对话",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ModelConnection: Codable, Sendable, Equatable {
    public var baseURL: String
    public var model: String
    public var apiKey: String
    public var temperature: Double

    public init(
        baseURL: String = "https://api.deepseek.com/v1",
        model: String = "deepseek-chat",
        apiKey: String = "",
        temperature: Double = 0.3
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.temperature = temperature
    }

    public var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Never leak the key in logs or UI dumps.
    public var redactedDescription: String {
        "\(baseURL) · \(model) · key=\(apiKey.isEmpty ? "missing" : "set")"
    }
}


/// Resolves whether a high-risk tool call may run. Streaming clients implement
/// this with an approval frame and a user decision; other transports may
/// auto-approve.
public typealias StreamApprovalProvider = @Sendable (ToolCall, ToolDefinition) async -> Bool
