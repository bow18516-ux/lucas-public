import Darwin
import Foundation
import JaplosProtocol

/// A minimal request/response Unix-socket server.
///
/// Transport matches the original product: a 4-byte big-endian length followed
/// by a JSON envelope. Each connection carries exactly one request.
public typealias StreamingKernelHandler = (
    KernelRequest,
    @escaping (KernelResponse) -> Void,
    @escaping StreamApprovalProvider
) async -> Void

public final class UnixSocketServer: @unchecked Sendable {
    public enum ServerError: Error, CustomStringConvertible {
        case pathTooLong
        case cannotCreateSocket(Int32)
        case cannotBind(String, Int32)
        case cannotListen(Int32)
        case alreadyRunning

        public var description: String {
            switch self {
            case .pathTooLong: return "Socket path is too long"
            case .cannotCreateSocket(let code): return "Cannot create socket: errno \(code)"
            case .cannotBind(let path, let code): return "Cannot bind socket at \(path): errno \(code)"
            case .cannotListen(let code): return "Cannot listen on socket: errno \(code)"
            case .alreadyRunning: return "Server is already running"
            }
        }
    }

    private let path: String
    private let handler: (KernelRequest) async -> KernelResponse
    private let streamHandler: StreamingKernelHandler?
    private let approvalBridge: WeChatApprovalBridge?
    private let keepAlive: () -> Bool
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    /// Set when start() had to unlink + rebind after an initial bind failure.
    public private(set) var recoveredFromBindFailure = false

    public init(
        path: String,
        keepAlive: @escaping () -> Bool = { true },
        streamHandler: StreamingKernelHandler? = nil,
        approvalBridge: WeChatApprovalBridge? = nil,
        handler: @escaping (KernelRequest) async -> KernelResponse
    ) {
        self.path = path
        self.keepAlive = keepAlive
        self.streamHandler = streamHandler
        self.approvalBridge = approvalBridge
        self.handler = handler
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { throw ServerError.alreadyRunning }

        removeStaleSocket()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.cannotCreateSocket(errno) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw ServerError.pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        recoveredFromBindFailure = false
        var bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindResult != 0 {
            let firstCode = errno
            // Best-effort self-heal: drop stale socket path and retry once.
            unlink(path)
            bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if bindResult == 0 {
                recoveredFromBindFailure = true
            } else {
                let code = errno
                close(fd)
                throw ServerError.cannotBind(path, firstCode != 0 ? firstCode : code)
            }
        }

        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw ServerError.cannotListen(code)
        }

        listenFD = fd
        running = true
        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
        unlink(path)
    }

    private func removeStaleSocket() {
        var info = stat()
        guard stat(path, &info) == 0 else { return }
        if (info.st_mode & S_IFMT) == S_IFSOCK {
            unlink(path)
        }
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let isRunning = running
            let fd = listenFD
            lock.unlock()
            guard isRunning, fd >= 0 else { return }

            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if errno == EBADF { return }
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.serve(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }

        var timeout = timeval(tv_sec: 600, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard peerIsSameUser(client) else {
            let response = KernelResponse.failure(
                .permissionDenied("Kernel client belongs to a different macOS user"),
                requestID: UUID().uuidString
            )
            _ = try? write(response, to: client)
            return
        }

        if let deny = peerTeamIDDenialReason(client) {
            let response = KernelResponse.failure(
                .permissionDenied(deny),
                requestID: UUID().uuidString
            )
            _ = try? write(response, to: client)
            return
        }

        do {
            let payload = try FrameCodec.readFrame(from: client, timeout: 600)
            let request = try ProtocolCoding.decode(KernelRequest.self, from: payload)

            let wantsStream = request.operation == .chatSend
                && request.arguments["stream"]?.boolValue == true
            if wantsStream, let streamHandler {
                let writer = FrameWriter(client: client)
                let broker = ApprovalBroker(bridge: self.approvalBridge, writer: writer)
                awaitStream(request, handler: streamHandler, writer: writer, client: client, broker: broker)
                writer.finish()
            } else {
                let response = awaitResponse(request)
                try write(response, to: client)
            }
        } catch {
            let response = KernelResponse.failure(
                .invalidArgument("Cannot decode kernel payload: \(error)"),
                requestID: UUID().uuidString
            )
            _ = try? write(response, to: client)
        }
    }

    private func awaitStream(
        _ request: KernelRequest,
        handler: @escaping StreamingKernelHandler,
        writer: FrameWriter,
        client: Int32,
        broker: ApprovalBroker
    ) {
        let done = DispatchSemaphore(value: 0)
        let cancellation = CancellationBox()
        writer.onFailure = { cancellation.cancel() }

        let approval: StreamApprovalProvider = { call, definition in
            await broker.request(call: call, definition: definition, writer: writer, timeout: 120)
        }

        let task = Task {
            await handler(request, { response in writer.write(response) }, approval)
            done.signal()
        }
        cancellation.store(task)

        // The connection doubles as the approval channel while the turn runs.
        // Also poll WeChat inbound for 同意/拒绝 replies (no-op without live iLink).
        var inboundPollCounter = 0
        while true {
            if done.wait(timeout: .now() + 0.15) == .success { break }
            inboundPollCounter += 1
            if inboundPollCounter % 4 == 0 {
                _ = broker.pollWeChatInbound()
            }
            guard pollReadable(client, timeoutMilliseconds: 100) else { continue }
            do {
                let payload = try FrameCodec.readFrame(from: client, timeout: 10)
                let message = try ProtocolCoding.decode(KernelRequest.self, from: payload)
                guard message.operation == .toolApproval else { continue }
                let callID = message.arguments["callID"]?.stringValue ?? ""
                let approved = message.arguments["approved"]?.boolValue ?? false
                broker.resolve(callID: callID, approved: approved, source: "desktop")
            } catch {
                break
            }
        }
        broker.cancelAll()
    }

    private func pollReadable(_ fd: Int32, timeoutMilliseconds: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, timeoutMilliseconds)
        return result > 0 && (descriptor.revents & Int16(POLLIN)) != 0
    }

    private func awaitResponse(_ request: KernelRequest) -> KernelResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var result: KernelResponse?
        Task {
            result = await handler(request)
            semaphore.signal()
        }
        semaphore.wait()
        return result ?? .failure(.internalError("Handler produced no response"), requestID: request.id)
    }

    private func write(_ response: KernelResponse, to client: Int32) throws {
        let data = try ProtocolCoding.encode(response)
        try FrameCodec.writeFrame(data, to: client, timeout: 30)
    }

    private final class CancellationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var cancelled = false

        func store(_ task: Task<Void, Never>) {
            lock.lock()
            self.task = task
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    private final class ApprovalBroker: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [String: CheckedContinuation<Bool, Never>] = [:]
        private let bridge: WeChatApprovalBridge?
        private let writer: FrameWriter

        init(bridge: WeChatApprovalBridge?, writer: FrameWriter) {
            self.bridge = bridge
            self.writer = writer
        }

        func request(
            call: ToolCall,
            definition: ToolDefinition,
            writer: FrameWriter,
            timeout: TimeInterval
        ) async -> Bool {
            let shortId = WeChatApprovalBridge.makeShortId(for: call.id)
            let attemptPush = bridge?.shouldAttemptPush() == true
            let effectiveTimeout = bridge?.preferredTimeout(attemptingWeChatPush: attemptPush) ?? timeout

            return await withCheckedContinuation { continuation in
                lock.lock()
                pending[call.id] = continuation
                lock.unlock()

                bridge?.register(
                    callID: call.id,
                    shortId: shortId,
                    title: definition.title,
                    name: definition.name,
                    onResolve: { [weak self] approved in
                        // Broker takes the continuation once, settles bridge, acks WeChat, notifies App.
                        self?.resolve(callID: call.id, approved: approved, source: "wechat")
                    }
                )

                writer.write(.success(.object([
                    "event": .string("approval"),
                    "callID": .string(call.id),
                    "shortId": .string(shortId),
                    "name": .string(definition.name),
                    "title": .string(definition.title),
                    "risk": .string(definition.risk.rawValue),
                    "arguments": call.arguments,
                    "wechatPushAttempted": .bool(attemptPush),
                    "approvalTimeoutSec": .number(effectiveTimeout),
                ]), requestID: call.id))

                // Side channel: push to WeChat when enabled + appears connected.
                // Never blocks the desktop card; failures are non-fatal.
                if attemptPush || bridge?.isPushEnabled() == true {
                    _ = bridge?.notifyApproval(call: call, definition: definition, shortId: shortId)
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + effectiveTimeout) { [weak self] in
                    self?.resolve(callID: call.id, approved: false, source: "timeout")
                }
            }
        }

        /// First successful resolve wins (continuation take under lock).
        /// Settles the WeChat bridge, acks WeChat, and emits `approvalResolved`
        /// so the App clears its pending card when WeChat/timeout decided.
        func resolve(callID: String, approved: Bool, source: String) {
            lock.lock()
            guard let continuation = pending.removeValue(forKey: callID) else {
                lock.unlock()
                return
            }
            lock.unlock()

            _ = bridge?.settle(
                callID: callID,
                approved: approved,
                source: source,
                notifyWeChat: true
            )
            writer.write(.success(.object([
                "event": .string("approvalResolved"),
                "callID": .string(callID),
                "approved": .bool(approved),
                "source": .string(source),
            ]), requestID: callID))
            continuation.resume(returning: approved)
        }

        @discardableResult
        func pollWeChatInbound() -> Int {
            bridge?.pollInboundOnce() ?? 0
        }

        func cancelAll() {
            lock.lock()
            let all = pending
            pending.removeAll()
            lock.unlock()
            for callID in all.keys {
                _ = bridge?.settle(
                    callID: callID,
                    approved: false,
                    source: "cancel",
                    notifyWeChat: false
                )
            }
            for continuation in all.values {
                continuation.resume(returning: false)
            }
        }
    }

    private final class FrameWriter: @unchecked Sendable {
        private let client: Int32
        private let lock = NSLock()
        private var failed = false
        private var wroteAny = false
        var onFailure: (() -> Void)?

        init(client: Int32) {
            self.client = client
        }

        func write(_ response: KernelResponse) {
            lock.lock()
            defer { lock.unlock() }
            guard !failed else { return }
            do {
                let data = try ProtocolCoding.encode(response)
                try FrameCodec.writeFrame(data, to: client, timeout: 30)
                wroteAny = true
            } catch {
                failed = true
                onFailure?()
            }
        }

        func finish() {
            lock.lock()
            defer { lock.unlock() }
            if !wroteAny && !failed {
                let fallback = KernelResponse.failure(.internalError("Stream produced no frames"), requestID: UUID().uuidString)
                if let data = try? ProtocolCoding.encode(fallback) {
                    try? FrameCodec.writeFrame(data, to: client, timeout: 30)
                }
            }
        }
    }

    private func peerIsSameUser(_ client: Int32) -> Bool {
        var credential = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        let result = getsockopt(client, 0 /* SOL_LOCAL */, 0x001 /* LOCAL_PEERCRED */, &credential, &length)
        guard result == 0 else { return false }
        return credential.cr_uid == getuid()
    }

    /// Optional codesign Team-ID gate. Off unless `LUCAS_REQUIRE_TEAM_ID` is set
    /// (comma-separated Team IDs; use `adhoc` to allow ad-hoc signed clients).
    /// Default off so local debug builds keep working.
    private func peerTeamIDDenialReason(_ client: Int32) -> String? {
        let raw = ProcessInfo.processInfo.environment["LUCAS_REQUIRE_TEAM_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        let allowed = Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !allowed.isEmpty else { return nil }

        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        // LOCAL_PEERPID = 0x002 on Darwin
        let result = getsockopt(client, 0 /* SOL_LOCAL */, 0x002 /* LOCAL_PEERPID */, &pid, &length)
        guard result == 0, pid > 0 else {
            return "Cannot resolve kernel client process for Team ID check"
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN))
        guard pathLen > 0 else {
            return "Cannot resolve executable path for pid \(pid)"
        }
        let exePath = String(cString: pathBuffer)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-dv", "--verbose=2", exePath]
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return "codesign probe failed for pid \(pid)"
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        var team: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            if s.hasPrefix("TeamIdentifier=") {
                team = String(s.dropFirst("TeamIdentifier=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        let resolved = (team == nil || team == "not set") ? "adhoc" : (team ?? "unknown")
        if allowed.contains(resolved) || allowed.contains("*") {
            return nil
        }
        return "Kernel client Team ID \(resolved) not in LUCAS_REQUIRE_TEAM_ID allow-list"
    }
}
