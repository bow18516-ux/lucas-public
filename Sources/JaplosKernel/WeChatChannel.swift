import Foundation
import JaplosProtocol

/// Official WeChat ClawBot / iLink channel (QR login).
/// Live send/login needs a successful QR scan; without credentials status is never "connected".
public final class WeChatChannel: @unchecked Sendable {
    public static let ilinkBaseURL = "https://ilinkai.weixin.qq.com"
    public static let c2cCDNBaseURL = "https://novac2c.cdn.weixin.qq.com/c2c"

    /// Documented iLink bot paths (from Japlos SoT strings). Exact request bodies may need live capture.
    public enum ILinkPath {
        public static let getBotQRCode = "ilink/bot/get_bot_qrcode"
        public static let getQRCodeStatus = "ilink/bot/get_qrcode_status"
        public static let getUpdates = "ilink/bot/getupdates"
        public static let getUploadURL = "ilink/bot/getuploadurl"
        public static let notifyStart = "ilink/bot/msg/notifystart"
        public static let notifyStop = "ilink/bot/msg/notifystop"
        public static let sendMessage = "ilink/bot/sendmessage"
    }

    public enum State: String {
        case disconnected
        case awaitingScan = "awaiting_scan"
        case verificationRequired = "verification_required"
        case connected
        case needsAuth = "needs_auth"
        case unavailable
        case error
    }

    private let store: KernelStore
    private let supportDirectory: URL
    private let lock = NSLock()
    private var loginSessionID: String?
    private var lastError: String?
    private var qrImagePath: String?
    private var pendingVerification = false

    public init(store: KernelStore, supportDirectory: URL? = nil) {
        self.store = store
        if let supportDirectory {
            self.supportDirectory = supportDirectory
        } else {
            self.supportDirectory = URL(fileURLWithPath: store.path).deletingLastPathComponent()
        }
        Self.ensureDirectories(self.supportDirectory)
    }

    public static func ensureDirectories(_ support: URL) {
        let fm = FileManager.default
        let paths = [
            support.appendingPathComponent("wechat", isDirectory: true),
            support.appendingPathComponent("wechat/credentials", isDirectory: true),
            support.appendingPathComponent("Caches/wechat", isDirectory: true),
        ]
        for url in paths {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private var credentialsDir: URL {
        supportDirectory.appendingPathComponent("wechat/credentials", isDirectory: true)
    }

    private var cachesDir: URL {
        supportDirectory.appendingPathComponent("Caches/wechat", isDirectory: true)
    }

    // MARK: - Public ops

    public func status() throws -> JSONValue {
        let connections = try store.listWeChatConnections(limit: 50)
        let connectedCount = connections.filter { ($0["state"]?.stringValue ?? "") == State.connected.rawValue }.count
        let hasCredentialFiles = !((try? FileManager.default.contentsOfDirectory(atPath: credentialsDir.path)) ?? []).isEmpty

        let state: State
        if pendingVerification {
            state = .verificationRequired
        } else if loginSessionID != nil {
            state = .awaitingScan
        } else if connectedCount > 0 {
            state = .connected
        } else if hasCredentialFiles {
            // Credentials on disk but not restored / verified this session.
            state = .needsAuth
        } else {
            state = .disconnected
        }

        var object: [String: JSONValue] = [
            "channel": .string("wechat"),
            "provider": .string("clawbot"),
            "state": .string(state.rawValue),
            "connected": .bool(state == .connected),
            "connectedAccountCount": .number(Double(connectedCount)),
            "awaitingScan": .bool(state == .awaitingScan),
            "verificationRequired": .bool(state == .verificationRequired),
            "ilinkBaseURL": .string(Self.ilinkBaseURL),
            // Never expose QR payloads, WeChat ids, or tokens.
            "connections": .array(connections.map { redactConnectionSummary($0) }),
            "hardBlock": .string("Live WeChat ClawBot QR login against ilinkai requires an interactive scan; no fabricated connected state."),
        ]
        if let loginSessionID {
            object["loginSessionID"] = .string(loginSessionID)
        }
        if let qrImagePath, FileManager.default.fileExists(atPath: qrImagePath) {
            object["qrImagePath"] = .string(qrImagePath)
            object["qrPresenter"] = .string("open_local_image")
        }
        if let lastError {
            object["lastError"] = .string(lastError)
        }
        if state == .needsAuth {
            object["action"] = .string("Call runtime.wechat.connect to start QR login, or restore persisted credentials after a successful prior scan.")
        } else if state == .disconnected {
            object["action"] = .string("Call runtime.wechat.connect to open a ClawBot QR code.")
        } else if state == .verificationRequired {
            object["action"] = .string("Submit the short numeric code from WeChat via runtime.wechat.verify.")
        }
        return .object(object)
    }

    /// Start QR login. Attempts iLink get_bot_qrcode; on network/API failure returns structured awaiting/needs path — never crashes, never fakes connected.
    public func connect() async throws -> JSONValue {
        lock.lock()
        defer { lock.unlock() }

        let session = UUID().uuidString
        loginSessionID = session
        pendingVerification = false
        lastError = nil

        // Persist a login-started ledger row (credential-free).
        _ = try? store.upsertWeChatConnection(
            id: "login-\(session)",
            state: State.awaitingScan.rawValue,
            record: .object([
                "event": .string("wechat.clawbot.login.started"),
                "loginSessionID": .string(session),
                "at": .string(ISO8601.string(from: Date())),
            ])
        )

        // Try live QR fetch (may fail without ClawBot enrollment / network).
        let qrResult = await fetchBotQRCode(loginSessionID: session)
        if let path = qrResult.imagePath {
            qrImagePath = path
            // Best-effort: open QR image for the user (Japlos presents a local PNG).
            presentQRImage(at: path)
            return .object([
                "ok": .bool(true),
                "state": .string(State.awaitingScan.rawValue),
                "awaitingScan": .bool(true),
                "loginSessionID": .string(session),
                "qrImagePath": .string(path),
                "event": .string("wechat.clawbot.login.started"),
                "message": .string("已打开微信 ClawBot 登录二维码，请使用微信扫码。扫码完成后用 runtime.wechat.status 查询是否成功。"),
            ])
        }

        lastError = qrResult.error ?? "ilink_qr_unavailable"
        // Keep awaiting_scan so UI can show placeholder + retry; do not claim connected.
        let placeholder = writePlaceholderQR(session: session, reason: lastError ?? "unavailable")
        qrImagePath = placeholder
        return .object([
            "ok": .bool(false),
            "state": .string(State.awaitingScan.rawValue),
            "awaitingScan": .bool(true),
            "needsLiveILink": .bool(true),
            "loginSessionID": .string(session),
            "qrImagePath": .string(placeholder),
            "event": .string("wechat.clawbot.login.started"),
            "error": .string(lastError ?? "WeChat iLink did not return a QR code"),
            "message": .string("已启动微信通道登录流程，但未能从 ilinkai 取得真实二维码（硬阻塞：需可访问的 ClawBot/iLink 与扫码）。状态不会伪造为已连接。"),
            "endpoints": .object([
                "base": .string(Self.ilinkBaseURL),
                "get_bot_qrcode": .string(ILinkPath.getBotQRCode),
                "get_qrcode_status": .string(ILinkPath.getQRCodeStatus),
            ]),
        ])
    }

    public func disconnect() throws -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        loginSessionID = nil
        pendingVerification = false
        qrImagePath = nil
        lastError = nil

        let existing = try store.listWeChatConnections(limit: 200)
        for row in existing {
            if let id = row["id"]?.stringValue {
                try store.deleteWeChatConnection(id: id)
            }
        }
        // Remove credential files (local iLink credentials).
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: credentialsDir, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
        return .object([
            "ok": .bool(true),
            "state": .string(State.disconnected.rawValue),
            "connected": .bool(false),
            "event": .string("wechat.clawbot.disconnected"),
            "message": .string("已断开全部微信 ClawBot 连接并清除本地凭据。"),
        ])
    }

    public func verify(code: String) throws -> JSONValue {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ChannelError.invalidArgument("verification code is required")
        }
        guard pendingVerification || loginSessionID != nil else {
            return .object([
                "ok": .bool(false),
                "state": .string(State.disconnected.rawValue),
                "error": .string("verification_not_required"),
                "message": .string("当前不需要验证码。仅当 runtime.wechat.status 报告 verification_required 时调用。"),
            ])
        }
        // Without live iLink session we cannot complete verification.
        lastError = "verify_requires_live_ilink_session"
        return .object([
            "ok": .bool(false),
            "state": .string(State.verificationRequired.rawValue),
            "verificationRequired": .bool(true),
            "needsLiveILink": .bool(true),
            "message": .string("验证码已接收但未向 iLink 提交（硬阻塞：需活跃的 ClawBot 登录会话）。不会伪造连接成功。"),
        ])
    }

    public func sendText(text: String, suppressAck: Bool = false) throws -> JSONValue {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw ChannelError.invalidArgument("text is required")
        }
        let connections = try store.listWeChatConnections(limit: 50)
        let connected = connections.filter { ($0["state"]?.stringValue ?? "") == State.connected.rawValue }
        guard !connected.isEmpty else {
            return .object([
                "ok": .bool(false),
                "delivered": .bool(false),
                "deliveredAccountCount": .number(0),
                "failedAccountCount": .number(0),
                "state": .string(State.disconnected.rawValue),
                "error": .string("not_connected"),
                "event": .string("wechat.clawbot.proactive.failed"),
                "message": .string("当前 Agent 未连接微信 ClawBot，无法发送。请先 runtime.wechat.connect。"),
            ])
        }
        // Connected rows without live tokens still cannot send.
        return .object([
            "ok": .bool(false),
            "delivered": .bool(false),
            "deliveredAccountCount": .number(0),
            "failedAccountCount": .number(Double(connected.count)),
            "needsLiveILink": .bool(true),
            "event": .string("wechat.clawbot.proactive.failed"),
            "message": .string("本地记录显示有连接，但缺少可用的 iLink 会话令牌，未实际发送。"),
            "endpoint": .string(ILinkPath.sendMessage),
        ])
    }

    public func sendFile(path: String, suppressTextReplyOnSuccess: Bool = false) throws -> JSONValue {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ChannelError.invalidArgument("path is required")
        }
        guard FileManager.default.fileExists(atPath: (trimmed as NSString).expandingTildeInPath) else {
            return .object([
                "ok": .bool(false),
                "delivered": .bool(false),
                "error": .string("file_not_found"),
                "event": .string("wechat.clawbot.file.failed"),
            ])
        }
        let connections = try store.listWeChatConnections(limit: 50)
        let connected = connections.filter { ($0["state"]?.stringValue ?? "") == State.connected.rawValue }
        guard !connected.isEmpty else {
            return .object([
                "ok": .bool(false),
                "delivered": .bool(false),
                "deliveredAccountCount": .number(0),
                "failedAccountCount": .number(0),
                "error": .string("not_connected"),
                "event": .string("wechat.clawbot.file.failed"),
                "message": .string("未连接微信，无法发送文件。"),
            ])
        }
        return .object([
            "ok": .bool(false),
            "delivered": .bool(false),
            "deliveredAccountCount": .number(0),
            "failedAccountCount": .number(Double(connected.count)),
            "needsLiveILink": .bool(true),
            "suppressTextReplyOnSuccess": .bool(suppressTextReplyOnSuccess),
            "event": .string("wechat.clawbot.file.failed"),
            "message": .string("文件路径有效，但缺少 iLink 上传会话，未实际发送。"),
            "endpoints": .array([
                .string(ILinkPath.getUploadURL),
                .string(ILinkPath.sendMessage),
            ]),
        ])
    }

    public func listConnections() throws -> JSONValue {
        let rows = try store.listWeChatConnections(limit: 100)
        return .object([
            "connections": .array(rows.map { redactConnectionSummary($0) }),
            "count": .number(Double(rows.count)),
        ])
    }

    public func removeConnection(id: String) throws -> JSONValue {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ChannelError.invalidArgument("id is required")
        }
        try store.deleteWeChatConnection(id: trimmed)
        let cred = credentialsDir.appendingPathComponent(trimmed)
        try? FileManager.default.removeItem(at: cred)
        try? FileManager.default.removeItem(at: credentialsDir.appendingPathComponent("\(trimmed).json"))
        return .object([
            "ok": .bool(true),
            "id": .string(trimmed),
            "event": .string("wechat.clawbot.connection.removed"),
        ])
    }

    public func loginStart() async throws -> JSONValue {
        try await connect()
    }

    public func loginStatus() throws -> JSONValue {
        try status()
    }


    // MARK: - Inbound (approval replies)

    /// Poll ClawBot `getupdates` for inbound text. Without a live iLink token
    /// returns an empty list — never crashes, never fabricates messages.
    public func pollInboundTextMessages() -> [String] {
        lock.lock()
        let token = loadILinkSessionTokenUnlocked()
        lock.unlock()
        guard let token, !token.isEmpty else {
            return []
        }
        return fetchUpdatesTextMessages(token: token)
    }

    /// Whether the ledger claims connected (may still lack a live token).
    public func appearsConnected() -> Bool {
        let connections = (try? store.listWeChatConnections(limit: 50)) ?? []
        return connections.contains { ($0["state"]?.stringValue ?? "") == State.connected.rawValue }
    }

    // MARK: - iLink HTTP (scaffold)

    private struct QRFetchResult {
        var imagePath: String?
        var error: String?
    }

    private func loadILinkSessionTokenUnlocked() -> String? {
        // Credential files under credentialsDir; look for a token-ish file without logging secrets.
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: credentialsDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        for file in files {
            let name = file.lastPathComponent.lowercased()
            guard name.contains("token") || name.hasSuffix(".json") || name.hasSuffix(".session") else { continue }
            guard let data = try? Data(contentsOf: file),
                  let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else { continue }
            // Prefer JSON {"token":"..."} / {"access_token":"..."} shapes.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for key in ["token", "access_token", "session_token", "ilink_token"] {
                    if let value = json[key] as? String, !value.isEmpty {
                        return value
                    }
                }
            }
            // Opaque single-line token file.
            if !raw.contains("{"), raw.count >= 8, raw.count < 4096 {
                return raw
            }
        }
        return nil
    }

    private func fetchUpdatesTextMessages(token: String) -> [String] {
        let base = store.secrets.secret(for: KernelStore.wechatILinkBaseURLAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let root = (base?.isEmpty == false) ? base! : Self.ilinkBaseURL
        let urlString = root.hasSuffix("/") ? "\(root)\(ILinkPath.getUpdates)" : "\(root)/\(ILinkPath.getUpdates)"
        guard let url = URL(string: urlString) else { return [] }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Body shape is best-effort until live capture; empty object is a safe probe.
        request.httpBody = Data("{}".utf8)

        let semaphore = DispatchSemaphore(value: 0)
        var texts: [String] = []
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let data,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else { return }
            texts = Self.extractInboundTexts(from: data)
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        return texts
    }

    /// Best-effort extract plain text bodies from getupdates JSON (shape TBD live).
    static func extractInboundTexts(from data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [String] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                for key in ["text", "content", "msg", "message", "body"] {
                    if let s = dict[key] as? String {
                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { out.append(t) }
                    }
                }
                for value in dict.values { walk(value) }
            } else if let arr = node as? [Any] {
                for value in arr { walk(value) }
            }
        }
        walk(root)
        // Deduplicate while preserving order.
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    private func fetchBotQRCode(loginSessionID: String) async -> QRFetchResult {
        let base = store.secrets.secret(for: KernelStore.wechatILinkBaseURLAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let root = (base?.isEmpty == false) ? base! : Self.ilinkBaseURL
        guard let url = URL(string: root.hasSuffix("/") ? "\(root)\(ILinkPath.getBotQRCode)" : "\(root)/\(ILinkPath.getBotQRCode)") else {
            return QRFetchResult(error: "invalid_ilink_base_url")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Lucas/1.0", forHTTPHeaderField: "User-Agent")
        // TODO(live-capture): exact BaseInfoRequest / headers (iLink-App-ClientVersion, bot id) from a successful Japlos session.
        let body: [String: Any] = [
            "baseInfo": [:] as [String: Any],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200, let image = extractQRImageData(from: data) {
                let path = cachesDir.appendingPathComponent("wechat-clawbot-login-\(loginSessionID).png").path
                try image.write(to: URL(fileURLWithPath: path), options: .atomic)
                return QRFetchResult(imagePath: path)
            }
            // Do not log response body (may contain tokens).
            return QRFetchResult(error: "ilink_http_\(code)_no_qr")
        } catch {
            return QRFetchResult(error: "ilink_network: \(error.localizedDescription)")
        }
    }

    private func extractQRImageData(from data: Data) -> Data? {
        // PNG/JPEG raw
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: [0xFF, 0xD8]) {
            return data
        }
        // JSON with base64 field (shape TBD — live capture).
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in ["qrcode", "qrCode", "qrcode_image", "image", "data"] {
            if let b64 = obj[key] as? String,
               let decoded = Data(base64Encoded: b64) {
                return decoded
            }
            if let nested = obj[key] as? [String: Any],
               let b64 = nested["buffer"] as? String ?? nested["image"] as? String,
               let decoded = Data(base64Encoded: b64) {
                return decoded
            }
        }
        return nil
    }

    private func writePlaceholderQR(session: String, reason: String) -> String {
        let path = cachesDir.appendingPathComponent("wechat-clawbot-login-\(session).txt").path
        let text = """
        Lucas WeChat ClawBot QR placeholder
        session: \(session)
        reason: \(reason)
        base: \(Self.ilinkBaseURL)/\(ILinkPath.getBotQRCode)
        Scan is not available until iLink returns a real QR image.
        """
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func presentQRImage(at path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [path]
        try? process.run()
    }

    private func redactConnectionSummary(_ row: JSONValue) -> JSONValue {
        var out: [String: JSONValue] = [
            "id": .string(row["id"]?.stringValue ?? ""),
            "state": .string(row["state"]?.stringValue ?? ""),
            "updatedAt": .string(row["updatedAt"]?.stringValue ?? ""),
        ]
        if let event = row["record"]?["event"]?.stringValue {
            out["event"] = .string(event)
        }
        // Explicitly omit tokens / WeChat ids / QR payloads.
        return .object(out)
    }
}

public enum ChannelError: Error, LocalizedError, Sendable {
    case invalidArgument(String)
    case notConnected(String)
    case needsAuth(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let m), .notConnected(let m), .needsAuth(let m):
            return m
        }
    }
}
