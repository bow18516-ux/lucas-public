import Foundation

public enum ToolRisk: String, Codable, Sendable {
    case low
    case medium
    case high
}

/// Whether a tool call must be shown to the user before it runs.
/// A missing value decodes as `always`. Risk level is not a second gate.
public enum ToolApproval: Codable, Sendable, Equatable {
    case always
    case never
    /// Require approval only when `arguments[key]` is one of `values`.
    case whenArgument(key: String, isOneOf: [String])

    private enum CodingKeys: String, CodingKey {
        case kind, key, values
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let raw = try? single.decode(String.self) {
            self = raw == "never" ? .never : .always
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(String.self, forKey: .kind) ?? "always" {
        case "never":
            self = .never
        case "whenArgument":
            self = .whenArgument(
                key: try container.decode(String.self, forKey: .key),
                isOneOf: try container.decode([String].self, forKey: .values)
            )
        default:
            self = .always
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .always:
            try container.encode("always", forKey: .kind)
        case .never:
            try container.encode("never", forKey: .kind)
        case .whenArgument(let key, let values):
            try container.encode("whenArgument", forKey: .kind)
            try container.encode(key, forKey: .key)
            try container.encode(values, forKey: .values)
        }
    }
}

public struct ToolDefinition: Codable, Sendable, Equatable {
    public var name: String
    public var title: String
    public var summary: String
    public var inputSchema: JSONValue
    public var capability: String
    public var risk: ToolRisk
    public var provider: String
    public var approval: ToolApproval

    public init(
        name: String,
        title: String,
        summary: String,
        inputSchema: JSONValue,
        capability: String,
        risk: ToolRisk = .low,
        provider: String = "kernel",
        approval: ToolApproval = .always
    ) {
        self.name = name
        self.title = title
        self.summary = summary
        self.inputSchema = inputSchema
        self.capability = capability
        self.risk = risk
        self.provider = provider
        self.approval = approval
    }

    private enum CodingKeys: String, CodingKey {
        case name, title, summary, inputSchema, capability, risk, provider, approval
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        inputSchema = try container.decode(JSONValue.self, forKey: .inputSchema)
        capability = try container.decode(String.self, forKey: .capability)
        risk = try container.decodeIfPresent(ToolRisk.self, forKey: .risk) ?? .low
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "kernel"
        approval = try container.decodeIfPresent(ToolApproval.self, forKey: .approval) ?? .always
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
    /// Human label for the connection card (optional; empty falls back to host).
    public var displayName: String

    public init(
        baseURL: String = "https://api.deepseek.com/v1",
        model: String = "deepseek-chat",
        apiKey: String = "",
        temperature: Double = 0.3,
        displayName: String = ""
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.temperature = temperature
        self.displayName = displayName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.deepseek.com/v1"
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.3
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
    }

    public var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Never leak the key in logs or UI dumps.
    public var redactedDescription: String {
        "\(baseURL) · \(model) · key=\(apiKey.isEmpty ? "missing" : "set")"
    }
}


/// Resolves whether a tool call may run. Callers must pass a provider.
/// There is no auto-approve default.
public typealias StreamApprovalProvider = @Sendable (ToolCall, ToolDefinition) async -> Bool

/// Single decision source: `ToolDefinition.approval`. Chat stream uses
/// ApprovalBroker; `tool.invoke` and non-stream chat deny instead of running.
public enum ToolApprovalGate {
    public static func requiresApproval(call: ToolCall, definition: ToolDefinition) -> Bool {
        switch definition.approval {
        case .always:
            return true
        case .never:
            return false
        case .whenArgument(let key, let values):
            let actual = call.arguments[key]?.stringValue ?? ""
            return values.contains(actual)
        }
    }
}

/// Text shown on the approval card. Side-effect fields are kept in full so a
/// long body cannot push the command, path, or recipients off the card.
public enum ApprovalPresentation {
    public static func summary(_ arguments: JSONValue?) -> String {
        guard let object = arguments?.objectValue else { return "" }
        var lines: [String] = []
        func take(_ key: String, _ label: String) {
            guard let value = object[key]?.stringValue, !value.isEmpty else { return }
            lines.append("\(label)：\(value)")
        }
        take("command", "命令")
        take("workingDirectory", "工作目录")
        take("action", "动作")
        take("path", "路径")
        take("url", "链接")
        take("to", "收件人")
        take("cc", "抄送")
        take("subject", "主题")
        if let confirm = object["confirm"]?.boolValue {
            lines.append("confirm：\(confirm ? "true" : "false")")
        }
        if let draft = object["draft_only"]?.boolValue {
            lines.append("draft_only：\(draft ? "true" : "false")")
        }
        if !lines.isEmpty {
            return lines.joined(separator: "\n")
        }
        let text = (try? arguments?.encodedString()) ?? ""
        if text.count <= 4000 { return text }
        return String(text.prefix(4000)) + "…"
    }
}
