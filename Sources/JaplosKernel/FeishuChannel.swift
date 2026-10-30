import Foundation
import JaplosProtocol


/// Feishu (Lark) channel — Open API + local auth_profile_store (Japlos-shaped).
/// Without app_id/app_secret: connect returns needs_auth / awaitingConfiguration; never fabricates connected.
public final class FeishuChannel: @unchecked Sendable {
    public static let openAPIBaseURL = "https://open.feishu.cn"

    public enum State: String {
        case disconnected
        case awaitingConfiguration = "awaiting_configuration"
        case connecting
        case connected
        case needsAuth = "needs_auth"
        case error
    }

    private let store: KernelStore
    private let supportDirectory: URL
    private let lock = NSLock()
    private var sessionActive = false
    private var lastError: String?
    private var awaitingConfiguration = false

    public init(store: KernelStore, supportDirectory: URL? = nil) {
        self.store = store
        if let supportDirectory {
            self.supportDirectory = supportDirectory
        } else {
            self.supportDirectory = URL(fileURLWithPath: store.path).deletingLastPathComponent()
        }
        Self.ensureDirectories(self.supportDirectory)
        try? FeishuAuthStore.ensureSchema(at: Self.authSQLiteURL(under: self.supportDirectory))
    }

    public static func ensureDirectories(_ support: URL) {
        let fm = FileManager.default
        let paths = [
            support.appendingPathComponent("feishu", isDirectory: true),
            support.appendingPathComponent("feishu/credentials", isDirectory: true),
        ]
        for url in paths {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    public static func authSQLiteURL(under support: URL) -> URL {
        support.appendingPathComponent("feishu/credentials/auth.sqlite")
    }

    private var authURL: URL {
        Self.authSQLiteURL(under: supportDirectory)
    }

    // MARK: - Ops

    public func status() throws -> JSONValue {
        let appIDConfigured = store.secrets.secret(for: KernelStore.feishuAppIDAccount)?.isEmpty == false
        let appSecretConfigured = store.secrets.secret(for: KernelStore.feishuAppSecretAccount)?.isEmpty == false
        let tokenConfigured = store.secrets.secret(for: KernelStore.feishuVerificationTokenAccount)?.isEmpty == false
        let profileCount = (try? FeishuAuthStore(path: authURL.path).count()) ?? 0

        let state: State
        if sessionActive && appIDConfigured && appSecretConfigured {
            state = .connected
        } else if awaitingConfiguration {
            state = .awaitingConfiguration
        } else if !appIDConfigured || !appSecretConfigured {
            state = .needsAuth
        } else if profileCount > 0 {
            state = .needsAuth // credentials present but session not established this run
        } else {
            state = .disconnected
        }

        var object: [String: JSONValue] = [
            "channel": .string("feishu"),
            "state": .string(state.rawValue),
            "connected": .bool(state == .connected),
            "awaitingConfiguration": .bool(state == .awaitingConfiguration),
            "appIdConfigured": .bool(appIDConfigured),
            "appSecretConfigured": .bool(appSecretConfigured),
            "verificationTokenConfigured": .bool(tokenConfigured),
            "authProfileCount": .number(Double(profileCount)),
            "openAPIBaseURL": .string(Self.openAPIBaseURL),
            "authSQLite": .string(authURL.path),
            "hardBlock": .string("Live Feishu requires boss-pasted app_id + app_secret (and optional verification_token); websocket long-connection not started without them."),
        ]
        if let lastError {
            object["lastError"] = .string(lastError)
        }
        if state == .needsAuth || state == .awaitingConfiguration {
            object["action"] = .string("在设置 → 通道 填写飞书 App ID / App Secret，然后点连接；切勿在对话中粘贴 Secret。")
        }
        // Never include secret values.
        return .object(object)
    }

    public func configure(appID: String?, appSecret: String?, verificationToken: String?) throws -> JSONValue {
        let id = appID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secret = appSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = verificationToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !id.isEmpty {
            try store.secrets.setSecret(id, for: KernelStore.feishuAppIDAccount)
            try FeishuAuthStore(path: authURL.path).upsert(reference: "app_id", secret: id)
        }
        if !secret.isEmpty {
            try store.secrets.setSecret(secret, for: KernelStore.feishuAppSecretAccount)
            try FeishuAuthStore(path: authURL.path).upsert(reference: "app_secret", secret: secret)
        }
        if !token.isEmpty {
            try store.secrets.setSecret(token, for: KernelStore.feishuVerificationTokenAccount)
            try FeishuAuthStore(path: authURL.path).upsert(reference: "verification_token", secret: token)
        }

        awaitingConfiguration = false
        return try status().merging(object: [
            "ok": .bool(true),
            "configured": .bool(true),
            "message": .string("飞书凭据已写入 SecretStore 与 feishu/credentials/auth.sqlite（不会回显密钥）。"),
        ])
    }

    public func openConfiguration() throws -> JSONValue {
        awaitingConfiguration = true
        return .object([
            "ok": .bool(true),
            "state": .string(State.awaitingConfiguration.rawValue),
            "awaitingConfiguration": .bool(true),
            "event": .string("feishu.configuration.open"),
            "message": .string("请在设置页填写飞书 App ID 与 App Secret。配置进行中不等于已连接。"),
        ])
    }

    public func cancelConfiguration() throws -> JSONValue {
        awaitingConfiguration = false
        return .object([
            "ok": .bool(true),
            "state": .string(State.disconnected.rawValue),
            "awaitingConfiguration": .bool(false),
            "event": .string("feishu.configuration.cancel"),
        ])
    }

    public func connect() async throws -> JSONValue {
        let appID = store.secrets.secret(for: KernelStore.feishuAppIDAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appSecret = store.secrets.secret(for: KernelStore.feishuAppSecretAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !appID.isEmpty, !appSecret.isEmpty else {
            awaitingConfiguration = true
            return .object([
                "ok": .bool(false),
                "state": .string(State.needsAuth.rawValue),
                "needsAuth": .bool(true),
                "awaitingConfiguration": .bool(true),
                "missing": .array([
                    appID.isEmpty ? .string("feishu.app_id") : nil,
                    appSecret.isEmpty ? .string("feishu.app_secret") : nil,
                ].compactMap { $0 }),
                "event": .string("feishu.connection.failed"),
                "message": .string("缺少飞书 App ID / App Secret。请在设置 → 通道 配置，勿在聊天中粘贴密钥。"),
            ])
        }

        // Attempt tenant access token (Open API). Failure → not connected.
        let tokenResult = await fetchTenantAccessToken(appID: appID, appSecret: appSecret)
        if tokenResult.ok, let access = tokenResult.token, !access.isEmpty {
            // Persist opaque session marker only (not the raw token in status).
            try store.secrets.setSecret(access, for: KernelStore.feishuTenantAccessTokenAccount)
            try FeishuAuthStore(path: authURL.path).upsert(reference: "tenant_access_token", secret: access)
            sessionActive = true
            lastError = nil
            awaitingConfiguration = false
            // Optional: ledger row in feishu_messages for connection event
            _ = try? store.upsertRuntimeLedger(
                table: "feishu_messages",
                id: "session-\(UUID().uuidString)",
                record: .object([
                    "event": .string("feishu.connection"),
                    "at": .string(ISO8601.string(from: Date())),
                    "ok": .bool(true),
                ])
            )
            return .object([
                "ok": .bool(true),
                "state": .string(State.connected.rawValue),
                "connected": .bool(true),
                "event": .string("feishu.connection"),
                "message": .string("飞书 tenant_access_token 已获取，通道标记为已连接。长连接/事件订阅仍可按需扩展。"),
            ])
        }

        sessionActive = false
        lastError = tokenResult.error ?? "token_failed"
        return .object([
            "ok": .bool(false),
            "state": .string(State.error.rawValue),
            "connected": .bool(false),
            "event": .string("feishu.connection.failed"),
            "error": .string(lastError ?? "unknown"),
            "message": .string("飞书凭据已配置，但获取 tenant_access_token 失败。请核对 App ID/Secret 与网络。"),
            "endpoint": .string("\(Self.openAPIBaseURL)/open-apis/auth/v3/tenant_access_token/internal"),
        ])
    }

    public func disconnect() throws -> JSONValue {
        sessionActive = false
        awaitingConfiguration = false
        lastError = nil
        store.secrets.removeSecret(for: KernelStore.feishuTenantAccessTokenAccount)
        try? FeishuAuthStore(path: authURL.path).delete(reference: "tenant_access_token")
        return .object([
            "ok": .bool(true),
            "state": .string(State.disconnected.rawValue),
            "connected": .bool(false),
            "event": .string("feishu.connection.disconnect"),
            "message": .string("已断开飞书会话（App ID/Secret 仍保留在本地密钥库）。"),
        ])
    }

    public func session() throws -> JSONValue {
        let st = try status()
        return .object([
            "session": st,
            "idempotencyPrefix": .string("runtime.feishu.session:"),
        ])
    }

    public func sendText(text: String, receiveID: String? = nil, receiveIDType: String = "open_id") throws -> JSONValue {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw ChannelError.invalidArgument("text is required")
        }
        guard sessionActive,
              let token = store.secrets.secret(for: KernelStore.feishuTenantAccessTokenAccount),
              !token.isEmpty else {
            return .object([
                "ok": .bool(false),
                "delivered": .bool(false),
                "state": .string(State.disconnected.rawValue),
                "error": .string("not_connected"),
                "event": .string("feishu.message.failed"),
                "message": .string("飞书未连接，无法发送。请先配置并连接。"),
            ])
        }
        guard let receiveID, !receiveID.isEmpty else {
            return .object([
                "ok": .bool(false),
                "delivered": .bool(false),
                "error": .string("receive_id_required"),
                "event": .string("feishu.message.failed"),
                "message": .string("需要 receive_id（open_id/chat_id 等）。Lucas 不会猜测收件人。"),
            ])
        }

        // Synchronous-ish send via URLSession semaphore alternative — use async bridge from caller.
        // Here we perform a blocking-friendly async pattern via continuation is not available;
        // KernelCore will call sendTextAsync.
        return .object([
            "ok": .bool(false),
            "delivered": .bool(false),
            "error": .string("use_send_text_async"),
            "message": .string("内部：请走 sendTextAsync。"),
        ])
    }

    public func sendTextAsync(text: String, receiveID: String?, receiveIDType: String = "open_id") async throws -> JSONValue {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw ChannelError.invalidArgument("text is required")
        }
        guard sessionActive,
              let token = store.secrets.secret(for: KernelStore.feishuTenantAccessTokenAccount),
              !token.isEmpty else {
            return .object([
                "ok": .bool(false),
                "delivered": .bool(false),
                "error": .string("not_connected"),
                "event": .string("feishu.message.failed"),
                "message": .string("飞书未连接，无法发送。"),
            ])
        }
        guard let receiveID, !receiveID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .object([
                "ok": .bool(false),
                "delivered": .bool(false),
                "error": .string("receive_id_required"),
                "event": .string("feishu.message.failed"),
                "message": .string("需要 receive_id。"),
            ])
        }

        let urlString = "\(Self.openAPIBaseURL)/open-apis/im/v1/messages?receive_id_type=\(receiveIDType)"
        guard let url = URL(string: urlString) else {
            throw ChannelError.invalidArgument("invalid feishu URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "receive_id": receiveID,
            "msg_type": "text",
            "content": String(data: try JSONSerialization.data(withJSONObject: ["text": body]), encoding: .utf8) ?? "{\"text\":\"\"}",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let okHTTP = (200...299).contains(code)
            var apiCode: Int = -1
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                apiCode = obj["code"] as? Int ?? -1
            }
            let delivered = okHTTP && apiCode == 0
            _ = try? store.upsertRuntimeLedger(
                table: "feishu_messages",
                id: nil,
                record: .object([
                    "direction": .string("outbound"),
                    "ok": .bool(delivered),
                    "http": .number(Double(code)),
                    "apiCode": .number(Double(apiCode)),
                    "at": .string(ISO8601.string(from: Date())),
                    // no message body / token logged
                ])
            )
            return .object([
                "ok": .bool(delivered),
                "delivered": .bool(delivered),
                "httpStatus": .number(Double(code)),
                "apiCode": .number(Double(apiCode)),
                "event": .string(delivered ? "feishu.reply" : "feishu.message.failed"),
                "message": .string(delivered ? "已发送" : "发送失败（不回显响应体，避免泄露）。"),
            ])
        } catch {
            return .object([
                "ok": .bool(false),
                "delivered": .bool(false),
                "event": .string("feishu.message.failed"),
                "error": .string(error.localizedDescription),
            ])
        }
    }

    public func importKnowledgeStub() -> JSONValue {
        .object([
            "ok": .bool(false),
            "stub": .bool(true),
            "operation": .string("runtime.knowledge.import_feishu"),
            "message": .string("飞书知识导入为占位：需已连接飞书并指定文档/知识空间；尚未实现抓取流水线。"),
        ])
    }

    // MARK: - Token

    private struct TokenResult {
        var ok: Bool
        var token: String?
        var error: String?
    }

    private func fetchTenantAccessToken(appID: String, appSecret: String) async -> TokenResult {
        guard let url = URL(string: "\(Self.openAPIBaseURL)/open-apis/auth/v3/tenant_access_token/internal") else {
            return TokenResult(ok: false, error: "invalid_url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let payload = ["app_id": appID, "app_secret": appSecret]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return TokenResult(ok: false, error: "ilink_http_\(code)_bad_json".replacingOccurrences(of: "ilink", with: "feishu"))
            }
            let apiCode = obj["code"] as? Int ?? -1
            if apiCode == 0, let token = obj["tenant_access_token"] as? String, !token.isEmpty {
                return TokenResult(ok: true, token: token)
            }
            let msg = obj["msg"] as? String ?? "api_code_\(apiCode)"
            // Do not include app_secret in error.
            return TokenResult(ok: false, error: "feishu_token: http=\(code) \(msg)")
        } catch {
            return TokenResult(ok: false, error: "feishu_network: \(error.localizedDescription)")
        }
    }
}

// MARK: - auth.sqlite (Japlos SoT schema)

public final class FeishuAuthStore {
    private let path: String

    public init(path: String) {
        self.path = path
    }

    public static func ensureSchema(at url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: url.path)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS auth_profile_store(
            reference TEXT PRIMARY KEY NOT NULL,
            secret TEXT NOT NULL
        );
        """)
        _ = db
    }

    public func count() throws -> Int {
        let db = try SQLiteDatabase(path: path)
        return try db.scalarInt("SELECT COUNT(*) FROM auth_profile_store;")
    }

    public func upsert(reference: String, secret: String) throws {
        let db = try SQLiteDatabase(path: path)
        try db.execute("""
        INSERT INTO auth_profile_store(reference, secret) VALUES (?, ?)
        ON CONFLICT(reference) DO UPDATE SET secret = excluded.secret;
        """, [reference, secret])
    }

    public func delete(reference: String) throws {
        let db = try SQLiteDatabase(path: path)
        try db.execute("DELETE FROM auth_profile_store WHERE reference = ?;", [reference])
    }
}

private extension JSONValue {
    func merging(object extras: [String: JSONValue]) -> JSONValue {
        var base = self.objectValue ?? [:]
        for (k, v) in extras { base[k] = v }
        return .object(base)
    }
}
