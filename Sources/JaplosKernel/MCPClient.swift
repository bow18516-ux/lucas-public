import Foundation
import JaplosProtocol

public enum MCPError: Error, CustomStringConvertible {
    case notRunning
    case spawnFailed(String)
    case transport(String)
    case rpc(String)
    case timedOut(String)
    case invalidConfiguration(String)

    public var description: String {
        switch self {
        case .notRunning: return "MCP server is not running"
        case .spawnFailed(let message): return "MCP spawn failed: \(message)"
        case .transport(let message): return "MCP transport error: \(message)"
        case .rpc(let message): return "MCP rpc error: \(message)"
        case .timedOut(let method): return "MCP request timed out: \(method)"
        case .invalidConfiguration(let message): return "MCP configuration error: \(message)"
        }
    }
}

public struct MCPServerConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var command: String
    public var args: [String]
    public var enabled: Bool
    public var url: String?
    public var headers: [String: String]?

    public init(
        id: String,
        name: String,
        command: String = "",
        args: [String] = [],
        enabled: Bool = true,
        url: String? = nil,
        headers: [String: String]? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.enabled = enabled
        self.url = url
        self.headers = headers
    }

    public var isHTTP: Bool {
        if let url, !url.isEmpty { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, command, args, enabled, url, headers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        url = try container.decodeIfPresent(String.self, forKey: .url)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
    }
}

public struct MCPToolInfo: Sendable {
    public var name: String
    public var summary: String
    public var inputSchema: JSONValue
}

public protocol MCPClientProtocol: AnyObject {
    var config: MCPServerConfig { get }
    var cachedTools: [MCPToolInfo] { get }
    func start() async throws
    func callTool(_ name: String, arguments: JSONValue) async throws -> JSONValue
    func stop()
}

// MARK: - stdio transport

/// One stdio MCP server. Newline-delimited JSON-RPC, matching the MCP spec.
public final class MCPStdioClient: MCPClientProtocol, @unchecked Sendable {
    public let config: MCPServerConfig
    public private(set) var cachedTools: [MCPToolInfo] = []

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private let lock = NSLock()
    private let writeLock = NSLock()
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var closed = false

    public init(config: MCPServerConfig) {
        self.config = config
    }

    public func start() async throws {
        process.executableURL = URL(fileURLWithPath: config.command.hasPrefix("/") ? config.command : "/usr/bin/env")
        process.arguments = config.command.hasPrefix("/") ? config.args : [config.command] + config.args
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            throw MCPError.spawnFailed(error.localizedDescription)
        }
        startReader()

        _ = try await request("initialize", params: .object([
            "protocolVersion": .string("2025-06-18"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("Lucas Agent"),
                "version": .string("0.4.0"),
            ]),
        ]), timeout: 20)

        sendNotification("notifications/initialized")

        let listed = try await request("tools/list", params: .object([:]), timeout: 20)
        cachedTools = (listed["tools"]?.arrayValue ?? []).compactMap { item in
            guard let name = item["name"]?.stringValue else { return nil }
            return MCPToolInfo(
                name: name,
                summary: item["description"]?.stringValue ?? "",
                inputSchema: item["inputSchema"] ?? .object(["type": .string("object")])
            )
        }
    }

    public func callTool(_ name: String, arguments: JSONValue) async throws -> JSONValue {
        try await request("tools/call", params: .object([
            "name": .string(name),
            "arguments": arguments,
        ]), timeout: 120)
    }

    public func stop() {
        lock.lock()
        closed = true
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        for continuation in waiting.values {
            continuation.resume(throwing: MCPError.notRunning)
        }
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: transport

    private func sendNotification(_ method: String) {
        write(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]))
    }

    private func request(_ method: String, params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        let id: Int = {
            lock.lock()
            nextID += 1
            let value = nextID
            lock.unlock()
            return value
        }()

        let payload: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ])

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: MCPError.notRunning)
                return
            }
            pending[id] = continuation
            lock.unlock()

            write(payload)

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(id: id, with: .failure(MCPError.timedOut(method)))
            }
        }
    }

    private func write(_ payload: JSONValue) {
        guard let data = try? ProtocolCoding.encode(payload) else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
        } catch {
            resolveAll(with: .failure(MCPError.transport(error.localizedDescription)))
        }
    }

    private func startReader() {
        let handle = stdoutPipe.fileHandleForReading
        let thread = Thread { [weak self] in
            guard let self else { return }
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                self.lock.lock()
                self.buffer.append(chunk)
                var lines: [Data] = []
                while let range = self.buffer.firstRange(of: Data("\n".utf8)) {
                    lines.append(self.buffer.subdata(in: self.buffer.startIndex..<range.lowerBound))
                    self.buffer.removeSubrange(self.buffer.startIndex...range.lowerBound)
                }
                self.lock.unlock()

                for line in lines where !line.isEmpty {
                    self.handle(line)
                }
            }
            self.resolveAll(with: .failure(MCPError.transport("server exited")))
        }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private func handle(_ line: Data) {
        guard
            let value = try? ProtocolCoding.decode(JSONValue.self, from: line),
            let id = value["id"]?.intValue
        else { return }

        if let error = value["error"] {
            resolve(id: id, with: .failure(MCPError.rpc(error["message"]?.stringValue ?? "unknown error")))
        } else if let result = value["result"] {
            resolve(id: id, with: .success(result))
        }
    }

    private func resolve(id: Int, with result: Result<JSONValue, Error>) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        guard let continuation else { return }
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    private func resolveAll(with result: Result<JSONValue, Error>) {
        lock.lock()
        let waiting = pending
        pending.removeAll()
        closed = true
        lock.unlock()
        for continuation in waiting.values {
            switch result {
            case .success(let value): continuation.resume(returning: value)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - HTTP transport

/// Streamable HTTP MCP transport. Works with servers that answer either JSON
/// or a single SSE response per request.
public final class MCPHTTPClient: MCPClientProtocol, @unchecked Sendable {
    public let config: MCPServerConfig
    public private(set) var cachedTools: [MCPToolInfo] = []

    private let url: URL
    private let session: URLSession
    private var sessionID: String?
    private var nextID = 1
    private let lock = NSLock()

    public init(config: MCPServerConfig) throws {
        guard let raw = config.url, let url = URL(string: raw) else {
            throw MCPError.invalidConfiguration("invalid MCP url")
        }
        self.config = config
        self.url = url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: configuration)
    }

    public func start() async throws {
        _ = try await rpc("initialize", params: .object([
            "protocolVersion": .string("2025-06-18"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("Lucas Agent"),
                "version": .string("0.4.0"),
            ]),
        ]), expectsResponse: true)

        _ = try await rpc("notifications/initialized", params: .object([:]), expectsResponse: false)

        let listed = try await rpc("tools/list", params: .object([:]), expectsResponse: true)
        cachedTools = (listed?["tools"]?.arrayValue ?? []).compactMap { item in
            guard let name = item["name"]?.stringValue else { return nil }
            return MCPToolInfo(
                name: name,
                summary: item["description"]?.stringValue ?? "",
                inputSchema: item["inputSchema"] ?? .object(["type": .string("object")])
            )
        }
    }

    public func callTool(_ name: String, arguments: JSONValue) async throws -> JSONValue {
        let result = try await rpc("tools/call", params: .object([
            "name": .string(name),
            "arguments": arguments,
        ]), expectsResponse: true)
        return result ?? .object([:])
    }

    public func stop() {
        session.invalidateAndCancel()
    }

    private func rpc(_ method: String, params: JSONValue, expectsResponse: Bool) async throws -> JSONValue? {
        let id: Int? = expectsResponse ? {
            lock.lock()
            nextID += 1
            let value = nextID
            lock.unlock()
            return value
        }() : nil

        var payload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ]
        if let id { payload["id"] = .number(Double(id)) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let headers = config.headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        request.httpBody = try ProtocolCoding.encode(JSONValue.object(payload))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MCPError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.transport("no HTTP response")
        }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = sid
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.rpc("HTTP \(http.statusCode): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        guard expectsResponse, let id else { return nil }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
        let message: JSONValue?
        if contentType.contains("text/event-stream") {
            message = parseSSE(data, id: id)
        } else if data.isEmpty {
            message = nil
        } else {
            message = try? ProtocolCoding.decode(JSONValue.self, from: data)
        }

        guard let message else {
            throw MCPError.rpc("empty response for \(method)")
        }
        if let error = message["error"] {
            throw MCPError.rpc(error["message"]?.stringValue ?? "unknown error")
        }
        return message["result"]
    }

    private func parseSSE(_ data: Data, id: Int) -> JSONValue? {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard
                let payloadData = payload.data(using: .utf8),
                let message = try? ProtocolCoding.decode(JSONValue.self, from: payloadData)
            else { continue }
            if message["id"]?.intValue == id {
                return message
            }
        }
        return nil
    }
}

// MARK: - Manager

public final class MCPManager: @unchecked Sendable {
    private let store: KernelStore
    private let lock = NSLock()
    private var clients: [String: any MCPClientProtocol] = [:]
    private var definitionsCache: [ToolDefinition] = []
    private var statusCache: [JSONValue] = []

    public init(store: KernelStore) {
        self.store = store
    }

    public var definitions: [ToolDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return definitionsCache
    }

    public var status: [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return statusCache
    }

    public func definition(named name: String) -> ToolDefinition? {
        definitions.first { $0.name == name }
    }

    public func reload() async {
        let existing: [any MCPClientProtocol] = {
            lock.lock()
            defer { lock.unlock() }
            return Array(clients.values)
        }()
        for client in existing { client.stop() }

        lock.lock()
        clients.removeAll()
        definitionsCache.removeAll()
        statusCache.removeAll()
        lock.unlock()

        let configurations = loadConfigurations()
        guard !configurations.isEmpty else { return }

        for config in configurations where config.enabled {
            let client: any MCPClientProtocol
            if config.isHTTP {
                do {
                    client = try MCPHTTPClient(config: config)
                } catch {
                    recordFailure(config: config, error: error)
                    continue
                }
            } else {
                client = MCPStdioClient(config: config)
            }

            do {
                try await client.start()
                let definitions = client.cachedTools.map { tool in
                    ToolDefinition(
                        name: "mcp.\(config.id).\(tool.name)",
                        title: "\(config.name) · \(tool.name)",
                        summary: tool.summary.isEmpty ? "MCP tool \(tool.name)" : tool.summary,
                        inputSchema: tool.inputSchema,
                        capability: Capability.toolInvoke,
                        risk: .medium,
                        provider: "mcp:\(config.id)"
                    )
                }
                lock.lock()
                clients[config.id] = client
                definitionsCache.append(contentsOf: definitions)
                statusCache.append(.object([
                    "id": .string(config.id),
                    "name": .string(config.name),
                    "transport": .string(config.isHTTP ? "http" : "stdio"),
                    "state": .string("ready"),
                    "toolCount": .number(Double(definitions.count)),
                ]))
                lock.unlock()
            } catch {
                recordFailure(config: config, error: error)
            }
        }
    }

    private func recordFailure(config: MCPServerConfig, error: Error) {
        lock.lock()
        statusCache.append(.object([
            "id": .string(config.id),
            "name": .string(config.name),
            "transport": .string(config.isHTTP ? "http" : "stdio"),
            "state": .string("error"),
            "toolCount": .number(0),
            "error": .string(String(describing: error)),
        ]))
        lock.unlock()
    }

    public func invoke(_ call: ToolCall) async -> ToolExecution {
        let parts = call.name.split(separator: ".", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "mcp" else {
            return ToolExecution(call: call, ok: false, output: .null, error: "Invalid MCP tool name")
        }
        let serverID = parts[1]
        let toolName = parts[2]

        let client: (any MCPClientProtocol)? = {
            lock.lock()
            defer { lock.unlock() }
            return clients[serverID]
        }()
        guard let client else {
            return ToolExecution(call: call, ok: false, output: .null, error: "MCP server \(serverID) is not running")
        }

        let started = Date()
        do {
            let result = try await client.callTool(toolName, arguments: call.arguments)
            let texts = (result["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
            let isError = result["isError"]?.boolValue ?? false
            return ToolExecution(
                call: call,
                ok: !isError,
                output: .object(["text": .string(texts.joined(separator: "\n"))]),
                error: isError ? texts.joined(separator: "\n") : nil,
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

    private func loadConfigurations() -> [MCPServerConfig] {
        guard
            let value = try? store.configurationValue("mcp.servers"),
            let data = try? ProtocolCoding.encode(value)
        else { return [] }
        return (try? ProtocolCoding.decode([MCPServerConfig].self, from: data)) ?? []
    }
}
