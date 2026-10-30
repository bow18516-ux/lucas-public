import Foundation
import JaplosProtocol

/// Stored API keys stay on the saved base URL. A probe to a different URL
/// must not attach that key unless the request supplies its own.
public enum ModelProbeKey {
    public static func apiKey(
        storedBaseURL: String?,
        storedKey: String?,
        requestedBaseURL: String,
        requestedKey: String
    ) -> String {
        let supplied = requestedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !supplied.isEmpty { return supplied }
        let requested = normalize(requestedBaseURL)
        let stored = normalize(storedBaseURL ?? "")
        if !requested.isEmpty, !stored.isEmpty, requested != stored {
            return ""
        }
        return storedKey ?? ""
    }

    public static func normalize(_ url: String) -> String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value.lowercased()
    }
}

public enum ModelMessage: Sendable {
    case system(String)
    case user(String)
    case assistant(text: String, toolCalls: [ToolCall])
    case tool(callID: String, name: String, content: String)
}

public struct ModelReply: Sendable {
    public var text: String
    public var toolCalls: [ToolCall]
    public var finishReason: String
    public var usage: JSONValue?

    public init(text: String, toolCalls: [ToolCall], finishReason: String = "", usage: JSONValue? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.finishReason = finishReason
        self.usage = usage
    }
}

public enum ModelError: Error, CustomStringConvertible {
    case notConfigured
    case invalidURL(String)
    case httpStatus(Int, String)
    case invalidResponse(String)
    case transport(String)

    public var description: String {
        switch self {
        case .notConfigured: return "模型连接未配置：请在设置中填写 Base URL、模型名和 API Key"
        case .invalidURL(let value): return "无效的 Base URL：\(value)"
        case .httpStatus(let code, let body): return "模型请求失败 HTTP \(code)：\(body.prefix(400))"
        case .invalidResponse(let detail): return "模型响应无法解析：\(detail)"
        case .transport(let detail): return "网络错误：\(detail)"
        }
    }
}

public final class ModelClient {
    private let connection: ModelConnection
    private let session: URLSession

    public init(connection: ModelConnection) {
        self.connection = connection
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    public func endpoint() throws -> URL {
        var base = connection.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw ModelError.invalidURL(connection.baseURL) }
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/chat/completions") {
            base += "/chat/completions"
        }
        guard let url = URL(string: base) else { throw ModelError.invalidURL(base) }
        return url
    }

    /// Fetches the provider's `/models` catalog.
    public func listModels() async throws -> [String] {
        guard connection.isConfigured else { throw ModelError.notConfigured }
        var base = connection.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") {
            base = String(base.dropLast("/chat/completions".count))
        }
        guard let url = URL(string: base + "/models") else {
            throw ModelError.invalidURL(base + "/models")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(connection.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }
        let root = try ProtocolCoding.decode(JSONValue.self, from: data)
        return (root["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }.sorted()
    }

    public func complete(messages: [ModelMessage], tools: [ToolDefinition]) async throws -> ModelReply {
        guard connection.isConfigured else { throw ModelError.notConfigured }

        var request = URLRequest(url: try endpoint())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(connection.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 180

        var body: [String: JSONValue] = [
            "model": .string(connection.model),
            "messages": .array(messages.map(Self.encode(message:))),
            "temperature": .number(connection.temperature),
            "stream": .bool(false),
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map(Self.encode(tool:)))
            body["tool_choice"] = .string("auto")
        }
        request.httpBody = try ProtocolCoding.encode(JSONValue.object(body))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ModelError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ModelError.invalidResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ModelError.httpStatus(http.statusCode, String(decoding: data, as: UTF8.self))
        }

        let root: JSONValue
        do {
            root = try ProtocolCoding.decode(JSONValue.self, from: data)
        } catch {
            throw ModelError.invalidResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }

        guard
            let choice = root["choices"]?.arrayValue?.first,
            let message = choice["message"]
        else {
            throw ModelError.invalidResponse("missing choices[0].message")
        }

        let text = message["content"]?.stringValue ?? ""
        let toolCalls = Self.decodeToolCalls(message["tool_calls"])
        let finish = choice["finish_reason"]?.stringValue ?? ""
        return ModelReply(text: text, toolCalls: toolCalls, finishReason: finish, usage: root["usage"])
    }

    // MARK: - Streaming

    /// Streams an OpenAI-compatible SSE completion, forwarding text deltas.
    public func stream(
        messages: [ModelMessage],
        tools: [ToolDefinition],
        onDelta: @escaping (String) -> Void
    ) async throws -> ModelReply {
        guard connection.isConfigured else { throw ModelError.notConfigured }

        var request = URLRequest(url: try endpoint())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(connection.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 180

        var body: [String: JSONValue] = [
            "model": .string(connection.model),
            "messages": .array(messages.map(Self.encode(message:))),
            "temperature": .number(connection.temperature),
            "stream": .bool(true),
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map(Self.encode(tool:)))
            body["tool_choice"] = .string("auto")
        }
        request.httpBody = try ProtocolCoding.encode(JSONValue.object(body))

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw ModelError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ModelError.invalidResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 4096 { break }
            }
            throw ModelError.httpStatus(http.statusCode, String(decoding: data, as: UTF8.self))
        }

        var text = ""
        var finishReason = ""
        var usage: JSONValue?
        var partialCalls: [Int: PartialToolCall] = [:]

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            guard
                let data = payload.data(using: .utf8),
                let chunk = try? ProtocolCoding.decode(JSONValue.self, from: data),
                let choice = chunk["choices"]?.arrayValue?.first
            else { continue }

            if let delta = choice["delta"] {
                if let content = delta["content"]?.stringValue, !content.isEmpty {
                    text += content
                    onDelta(content)
                }
                if let calls = delta["tool_calls"]?.arrayValue {
                    for call in calls {
                        let index = call["index"]?.intValue ?? 0
                        var partial = partialCalls[index] ?? PartialToolCall()
                        if let id = call["id"]?.stringValue, !id.isEmpty { partial.id = id }
                        if let function = call["function"] {
                            if let name = function["name"]?.stringValue, !name.isEmpty { partial.name = name }
                            if let arguments = function["arguments"]?.stringValue { partial.arguments += arguments }
                        }
                        partialCalls[index] = partial
                    }
                }
            }
            if let reason = choice["finish_reason"]?.stringValue, !reason.isEmpty {
                finishReason = reason
            }
            if let chunkUsage = chunk["usage"] { usage = chunkUsage }
        }

        let toolCalls = partialCalls.keys.sorted().compactMap { key -> ToolCall? in
            guard let partial = partialCalls[key], !partial.name.isEmpty else { return nil }
            let arguments: JSONValue
            if
                let data = partial.arguments.data(using: .utf8),
                let decoded = try? ProtocolCoding.decode(JSONValue.self, from: data)
            {
                arguments = decoded
            } else {
                arguments = .object([:])
            }
            return ToolCall(id: partial.id, name: partial.name, arguments: arguments)
        }
        return ModelReply(text: text, toolCalls: toolCalls, finishReason: finishReason, usage: usage)
    }

    private struct PartialToolCall {
        var id: String = UUID().uuidString
        var name: String = ""
        var arguments: String = ""
    }

    // MARK: - Encoding

    static func encode(message: ModelMessage) -> JSONValue {
        switch message {
        case .system(let text):
            return .object(["role": .string("system"), "content": .string(text)])
        case .user(let text):
            return .object(["role": .string("user"), "content": .string(text)])
        case .assistant(let text, let toolCalls):
            var object: [String: JSONValue] = [
                "role": .string("assistant"),
                "content": text.isEmpty ? .null : .string(text),
            ]
            if !toolCalls.isEmpty {
                object["tool_calls"] = .array(toolCalls.map { call in
                    .object([
                        "id": .string(call.id),
                        "type": .string("function"),
                        "function": .object([
                            "name": .string(call.name),
                            "arguments": .string((try? call.arguments.encodedString()) ?? "{}"),
                        ]),
                    ])
                })
            }
            return .object(object)
        case .tool(let callID, _, let content):
            // `name` is optional in the OpenAI schema and providers disagree on
            // allowed characters (e.g. dots in MCP tool names), so omit it.
            return .object([
                "role": .string("tool"),
                "tool_call_id": .string(callID),
                "content": .string(content),
            ])
        }
    }

    static func encode(tool: ToolDefinition) -> JSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(tool.name),
                "description": .string(tool.summary),
                "parameters": tool.inputSchema,
            ]),
        ])
    }

    static func decodeToolCalls(_ value: JSONValue?) -> [ToolCall] {
        guard let array = value?.arrayValue else { return [] }
        return array.compactMap { item in
            guard
                let function = item["function"],
                let name = function["name"]?.stringValue
            else { return nil }
            let id = item["id"]?.stringValue ?? UUID().uuidString
            let rawArguments = function["arguments"]?.stringValue ?? "{}"
            let arguments: JSONValue
            if let data = rawArguments.data(using: .utf8),
               let decoded = try? ProtocolCoding.decode(JSONValue.self, from: data) {
                arguments = decoded
            } else {
                arguments = .object([:])
            }
            return ToolCall(id: id, name: name, arguments: arguments)
        }
    }
}
