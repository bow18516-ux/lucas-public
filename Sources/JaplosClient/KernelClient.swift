import Darwin
import Foundation
import JaplosProtocol

/// Owns the socket of one streaming call so cancellation can unblock the reader.
private final class StreamHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?
    private var cancelled = false

    func attach(_ fd: Int32) -> Bool {
        lock.lock()
        if cancelled {
            lock.unlock()
            Darwin.close(fd)
            return false
        }
        descriptor = fd
        lock.unlock()
        return true
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func close() {
        lock.lock()
        let fd = descriptor
        descriptor = nil
        cancelled = true
        lock.unlock()
        if let fd {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    func send(_ request: KernelRequest) throws {
        lock.lock()
        let fd = descriptor
        lock.unlock()
        guard let fd else { return }
        let data = try ProtocolCoding.encode(request)
        try FrameCodec.writeFrame(data, to: fd, timeout: 30)
    }
}

/// A live streaming turn. The client can answer `approval` events while the
/// same socket keeps yielding deltas.
public final class ChatStream: @unchecked Sendable {
    public let events: AsyncThrowingStream<JSONValue, Error>
    private let handle: StreamHandle
    private let principal: String

    fileprivate init(events: AsyncThrowingStream<JSONValue, Error>, handle: StreamHandle, principal: String) {
        self.events = events
        self.handle = handle
        self.principal = principal
    }

    public func approve(callID: String, approved: Bool) {
        let request = KernelRequest(
            principal: principal,
            operation: .toolApproval,
            arguments: .object([
                "callID": .string(callID),
                "approved": .bool(approved),
            ])
        )
        try? handle.send(request)
    }
}

public enum ClientError: Error, CustomStringConvertible {
    case cannotConnect(String)
    case transport(String)
    case kernel(KernelFailure)

    public var description: String {
        switch self {
        case .cannotConnect(let path): return "无法连接内核：\(path)"
        case .transport(let message): return "内核通信失败：\(message)"
        case .kernel(let failure): return failure.message
        }
    }
}

public final class KernelClient: @unchecked Sendable {
    public let socketPath: String
    public let principal: String

    public init(socketPath: String, principal: String = Principal.localUser) {
        self.socketPath = socketPath
        self.principal = principal
    }

    /// `LUCAS_CLONE_HOME` lets development builds keep state inside a repository
    /// instead of `~/Library/Application Support`.
    public static var homeDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["LUCAS_CLONE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lucas", isDirectory: true)
    }

    public static var defaultSocketPath: String {
        homeDirectory.appendingPathComponent("kernel.sock").path
    }

    public static var defaultStorePath: String {
        homeDirectory.appendingPathComponent("kernel.sqlite3").path
    }

    public func ping(timeout: TimeInterval = 1.5) -> Bool {
        (try? perform(.kernelPing, arguments: .object([:]), timeout: timeout)) != nil
    }

    public func daemonVersion(timeout: TimeInterval = 1.5) -> String? {
        (try? perform(.kernelStatus, arguments: .object([:]), timeout: timeout))?["version"]?.stringValue
    }

    /// Ask the daemon to exit. Deliberately does not go through `call`, which
    /// would restart a daemon that happened to be down.
    @discardableResult
    public func shutdown(timeout: TimeInterval = 2) -> Bool {
        (try? perform(.kernelShutdown, arguments: .object([:]), timeout: timeout)) != nil
    }

    /// Full `kernel.status` payload, used by the build handshake.
    public func daemonStatus(timeout: TimeInterval = 1.5) -> JSONValue? {
        try? perform(.kernelStatus, arguments: .object([:]), timeout: timeout)
    }

    public func call(
        _ operation: KernelOperation,
        arguments: JSONValue = .object([:]),
        timeout: TimeInterval = 300,
        resource: String? = nil
    ) throws -> JSONValue {
        do {
            return try perform(operation, arguments: arguments, timeout: timeout, resource: resource)
        } catch let error as ClientError {
            switch error {
            case .cannotConnect, .transport:
                try DaemonController.ensureRunning(client: self)
                return try perform(operation, arguments: arguments, timeout: timeout, resource: resource)
            case .kernel:
                throw error
            }
        }
    }

    fileprivate func perform(
        _ operation: KernelOperation,
        arguments: JSONValue = .object([:]),
        timeout: TimeInterval = 300,
        resource: String? = nil
    ) throws -> JSONValue {
        let fd = try connect()
        defer { close(fd) }

        var sendTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        var receiveTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        let request = KernelRequest(
            principal: principal,
            operation: operation,
            resource: resource,
            arguments: arguments
        )
        do {
            let payload = try ProtocolCoding.encode(request)
            try FrameCodec.writeFrame(payload, to: fd, timeout: timeout)
            let reply = try FrameCodec.readFrame(from: fd, timeout: timeout)
            let response = try ProtocolCoding.decode(KernelResponse.self, from: reply)
            if let failure = response.failure {
                throw ClientError.kernel(failure)
            }
            if let error = response.error, !error.isEmpty {
                throw ClientError.kernel(KernelFailure(code: "error", message: error))
            }
            return response.result ?? .null
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.transport(String(describing: error))
        }
    }

    public func callAsync(
        _ operation: KernelOperation,
        arguments: JSONValue = .object([:]),
        timeout: TimeInterval = 300
    ) async throws -> JSONValue {
        try await Task.detached(priority: .userInitiated) { [self] in
            try call(operation, arguments: arguments, timeout: timeout)
        }.value
    }

    /// Opens a streaming `chat.send` and yields each event frame
    /// (`delta` / `tool` / `done`) until the turn finishes. Cancelling the
    /// consuming task shuts the socket down so the daemon stops writing.
    public func streamChat(
        sessionID: String?,
        text: String,
        timeout: TimeInterval = 600
    ) -> ChatStream {
        let handle = StreamHandle()
        let events = AsyncThrowingStream<JSONValue, Error> { continuation in
            let task = Task.detached(priority: .userInitiated) { [self] in
                do {
                    let fd = try connect()
                    guard handle.attach(fd) else {
                        continuation.finish()
                        return
                    }
                    defer { handle.close() }

                    var sendTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
                    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
                    var receiveTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
                    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

                    var arguments: [String: JSONValue] = [
                        "text": .string(text),
                        "stream": .bool(true),
                    ]
                    if let sessionID { arguments["sessionID"] = .string(sessionID) }

                    let request = KernelRequest(
                        principal: principal,
                        operation: .chatSend,
                        arguments: .object(arguments)
                    )
                    try FrameCodec.writeFrame(ProtocolCoding.encode(request), to: fd, timeout: timeout)

                    while !handle.isCancelled {
                        let payload = try FrameCodec.readFrame(from: fd, timeout: timeout)
                        let response = try ProtocolCoding.decode(KernelResponse.self, from: payload)
                        if let failure = response.failure {
                            throw ClientError.kernel(failure)
                        }
                        if let error = response.error, !error.isEmpty {
                            throw ClientError.kernel(KernelFailure(code: "error", message: error))
                        }
                        guard let result = response.result else { continue }
                        continuation.yield(result)
                        if result["event"]?.stringValue == "done" { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                handle.close()
                task.cancel()
            }
        }
        return ChatStream(events: events, handle: handle, principal: principal)
    }

    private func connect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ClientError.cannotConnect("socket() errno \(errno)")
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw ClientError.cannotConnect("socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw ClientError.cannotConnect(socketPath)
        }
        return fd
    }
}

public enum DaemonController {
    /// Serialises launches: concurrent requests that all find a dead socket
    /// must produce one daemon, not one each.
    private static let startLock = NSLock()

    /// Starts `lucasd` when the socket is not answering yet.
    public static func ensureRunning(
        client: KernelClient,
        logURL: URL? = nil
    ) throws {
        startLock.lock()
        defer { startLock.unlock() }

        // Someone may have started it while we waited for the lock.
        if client.ping() {
            if isCurrentBuild(client.daemonStatus()) { return }
            client.shutdown()
            waitUntilStopped(client: client)
        }

        guard let executable = locateDaemon() else {
            throw ClientError.cannotConnect("找不到 lucasd（可设置 LUCASD_PATH）")
        }

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: client.socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--socket", client.socketPath, "--store", KernelClient.defaultStorePath]
        if let logURL {
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let fd = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if fd >= 0 {
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                process.standardError = handle
                process.standardOutput = handle
            }
        } else {
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
        }

        try process.run()

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if client.ping() { return }
            usleep(120_000)
        }
        throw ClientError.cannotConnect("lucasd 启动超时")
    }

    /// The old daemon only notices `kernel.shutdown` on its next poll, and it
    /// must be gone before a replacement binds the socket path. Ping until it
    /// stops answering (3s), then SIGTERM the pid it reported.
    static func waitUntilStopped(client: KernelClient, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !client.ping(timeout: 0.4) { return }
            usleep(100_000)
        }
        guard let pid = client.daemonStatus(timeout: 0.4)?["pid"]?.doubleValue, pid > 1 else {
            return
        }
        kill(pid_t(pid), SIGTERM)
        let hard = Date().addingTimeInterval(2)
        while Date() < hard {
            if !client.ping(timeout: 0.4) { return }
            usleep(100_000)
        }
    }

    /// Marketing version alone cannot tell two builds apart: the daemon must
    /// also report the same `CFBundleVersion`, come from the binary this app
    /// would launch, and that binary must not have been replaced in place.
    public static func isCurrentBuild(_ status: JSONValue?) -> Bool {
        guard let status,
              status["version"]?.stringValue == ProductVersion.marketing
        else { return false }
        let located = locateDaemon()
        return DaemonHandshake.matches(
            appBuild: ProductBuild.current,
            daemonBuild: status["build"]?.stringValue,
            expectedPath: located?.path,
            daemonPath: status["executable"]?["path"]?.stringValue,
            expectedModifiedAt: located.flatMap(modifiedAt),
            daemonModifiedAt: status["executable"]?["modifiedAt"]?.doubleValue
        )
    }

    private static func modifiedAt(_ url: URL) -> Double? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date
        else { return nil }
        return date.timeIntervalSince1970
    }

    public static func locateDaemon() -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["LUCASD_PATH"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        if let bundleURL = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(bundleURL.appendingPathComponent("lucasd"))
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent(".build/release/lucasd"))
        candidates.append(cwd.appendingPathComponent(".build/debug/lucasd"))
        candidates.append(cwd.appendingPathComponent("clone/.build/debug/lucasd"))
        candidates.append(cwd.appendingPathComponent("clone/.build/release/lucasd"))

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
