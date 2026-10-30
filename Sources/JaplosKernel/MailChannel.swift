import Foundation
import JaplosProtocol

/// IMAP/SMTP email channel — OpenClaw-shaped (local credentials + live IMAP probe),
/// not MCP and not Gmail Pub/Sub.
///
/// App password → SecretStore / Keychain. Account metadata → `mail/account.json` (0600).
/// Outbound defaults to draft-only; live SMTP needs `confirm=true` and `draft_only=false`.
public final class MailChannel: @unchecked Sendable {
    public enum Preset: String, CaseIterable, Sendable {
        case gmail
        case netease163 = "163"
        case qq
        case exmail
        case custom

        public var title: String {
            switch self {
            case .gmail: return "Gmail"
            case .netease163: return "163 邮箱"
            case .qq: return "QQ 邮箱"
            case .exmail: return "企业邮箱 (腾讯)"
            case .custom: return "自定义"
            }
        }

        public var imapHost: String {
            switch self {
            case .gmail: return "imap.gmail.com"
            case .netease163: return "imap.163.com"
            case .qq: return "imap.qq.com"
            case .exmail: return "imap.exmail.qq.com"
            case .custom: return ""
            }
        }

        public var imapPort: Int { 993 }

        public var smtpHost: String {
            switch self {
            case .gmail: return "smtp.gmail.com"
            case .netease163: return "smtp.163.com"
            case .qq: return "smtp.qq.com"
            case .exmail: return "smtp.exmail.qq.com"
            case .custom: return ""
            }
        }

        public var smtpPort: Int { 465 }
    }

    public struct Account: Codable, Sendable, Equatable {
        public var preset: String
        public var email: String
        public var displayName: String
        public var imapHost: String
        public var imapPort: Int
        public var smtpHost: String
        public var smtpPort: Int
        public var connected: Bool
        public var lastProbeOK: Bool
        public var lastProbeAt: String?
        public var lastError: String?
        public var sendGateDefault: String

        public init(
            preset: String = Preset.gmail.rawValue,
            email: String = "",
            displayName: String = "",
            imapHost: String = Preset.gmail.imapHost,
            imapPort: Int = 993,
            smtpHost: String = Preset.gmail.smtpHost,
            smtpPort: Int = 465,
            connected: Bool = false,
            lastProbeOK: Bool = false,
            lastProbeAt: String? = nil,
            lastError: String? = nil,
            sendGateDefault: String = "draft_only"
        ) {
            self.preset = preset
            self.email = email
            self.displayName = displayName
            self.imapHost = imapHost
            self.imapPort = imapPort
            self.smtpHost = smtpHost
            self.smtpPort = smtpPort
            self.connected = connected
            self.lastProbeOK = lastProbeOK
            self.lastProbeAt = lastProbeAt
            self.lastError = lastError
            self.sendGateDefault = sendGateDefault
        }
    }

    private let store: KernelStore
    private let supportDirectory: URL
    private let lock = NSLock()

    public init(store: KernelStore, supportDirectory: URL) {
        self.store = store
        self.supportDirectory = supportDirectory
        try? FileManager.default.createDirectory(at: mailDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: draftsDir, withIntermediateDirectories: true)
    }

    private var mailDir: URL {
        supportDirectory.appendingPathComponent("mail", isDirectory: true)
    }

    private var accountURL: URL {
        mailDir.appendingPathComponent("account.json")
    }

    public var draftsDir: URL {
        mailDir.appendingPathComponent("drafts", isDirectory: true)
    }

    public func loadAccount() -> Account {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: accountURL),
              let account = try? JSONDecoder().decode(Account.self, from: data) else {
            return Account()
        }
        return account
    }

    private func saveAccount(_ account: Account) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: mailDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(account)
        let tmp = accountURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try? FileManager.default.removeItem(at: accountURL)
        try FileManager.default.moveItem(at: tmp, to: accountURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accountURL.path)
    }

    private var hasPassword: Bool {
        !(store.secrets.secret(for: KernelStore.mailAppPasswordAccount) ?? "").isEmpty
    }

    public func status() throws -> JSONValue {
        let account = loadAccount()
        let passwordSet = hasPassword
        let emailOK = !account.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let state: String
        if account.connected && account.lastProbeOK && passwordSet && emailOK {
            state = "connected"
        } else if emailOK || passwordSet {
            state = "configured"
        } else {
            state = "disconnected"
        }
        var object: [String: JSONValue] = [
            "state": .string(state),
            "preset": .string(account.preset),
            "email": .string(account.email),
            "displayName": .string(account.displayName),
            "imapHost": .string(account.imapHost),
            "imapPort": .number(Double(account.imapPort)),
            "smtpHost": .string(account.smtpHost),
            "smtpPort": .number(Double(account.smtpPort)),
            "passwordConfigured": .bool(passwordSet),
            "connected": .bool(account.connected && account.lastProbeOK),
            "lastProbeOK": .bool(account.lastProbeOK),
            "sendGateDefault": .string(account.sendGateDefault),
            "draftsDir": .string(draftsDir.path),
            "presets": .array(Preset.allCases.map { .object([
                "id": .string($0.rawValue),
                "title": .string($0.title),
            ]) }),
        ]
        if let at = account.lastProbeAt {
            object["lastProbeAt"] = .string(at)
        }
        if let err = account.lastError, !err.isEmpty {
            object["lastError"] = .string(err)
            object["message"] = .string(err)
        } else if state == "connected" {
            object["message"] = .string("邮箱已连接（IMAP 探测通过）。外发默认草稿闸门，需 confirm 才 SMTP 实发。")
        } else if state == "configured" {
            object["message"] = .string("已填写账户，点「连接」做 IMAP 登录探测。")
            object["action"] = .string("在设置 → 通道 → 邮箱 点连接；应用密码不会回显。")
        } else {
            object["message"] = .string("尚未配置邮箱。选预设（Gmail/163/QQ/企业/自定义），填地址与应用密码。")
            object["action"] = .string("设置 → 通道 → 邮箱账户")
        }
        return .object(object)
    }

    public func configure(
        preset: String?,
        email: String?,
        displayName: String?,
        password: String?,
        imapHost: String?,
        imapPort: Int?,
        smtpHost: String?,
        smtpPort: Int?
    ) throws -> JSONValue {
        var account = loadAccount()
        let pRaw = (preset ?? account.preset).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = Preset(rawValue: pRaw) ?? .custom
        account.preset = resolved.rawValue

        if let email, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            account.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let displayName {
            account.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if resolved != .custom {
            account.imapHost = resolved.imapHost
            account.imapPort = resolved.imapPort
            account.smtpHost = resolved.smtpHost
            account.smtpPort = resolved.smtpPort
        }
        if let imapHost, !imapHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            account.imapHost = imapHost.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let imapPort, imapPort > 0 { account.imapPort = imapPort }
        if let smtpHost, !smtpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            account.smtpHost = smtpHost.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let smtpPort, smtpPort > 0 { account.smtpPort = smtpPort }

        if let password {
            let cleaned = password
                .replacingOccurrences(of: " ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                try store.secrets.setSecret(cleaned, for: KernelStore.mailAppPasswordAccount)
            }
        }

        account.connected = false
        account.lastProbeOK = false
        account.lastError = nil
        try saveAccount(account)

        return try status().mergingMail([
            "ok": .bool(true),
            "configured": .bool(true),
            "message": .string("邮箱账户已保存（密码进 SecretStore/Keychain；元数据在 mail/account.json）。点连接做 IMAP 探测。"),
        ])
    }

    public func connect() async throws -> JSONValue {
        var account = loadAccount()
        let email = account.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = (store.secrets.secret(for: KernelStore.mailAppPasswordAccount) ?? "")
            .replacingOccurrences(of: " ", with: "")
        guard !email.isEmpty else {
            return try status().mergingMail([
                "ok": .bool(false),
                "message": .string("缺少邮箱地址。请先在设置 → 通道 → 邮箱 保存账户。"),
            ])
        }
        guard !password.isEmpty else {
            return try status().mergingMail([
                "ok": .bool(false),
                "message": .string("缺少应用密码。请先保存密码（不会回显）。"),
            ])
        }
        guard !account.imapHost.isEmpty else {
            return try status().mergingMail([
                "ok": .bool(false),
                "message": .string("缺少 IMAP 主机。选预设或填自定义 host。"),
            ])
        }

        do {
            let result: JSONValue = try await Task.detached {
                let session = try IMAPSession.connect(
                    host: account.imapHost,
                    port: account.imapPort,
                    timeout: 20
                )
                defer { session.close() }
                try session.login(user: email, password: password)
                session.logout()
                return .object(["ok": .bool(true)])
            }.value
            _ = result
            account.connected = true
            account.lastProbeOK = true
            account.lastProbeAt = ISO8601.string(from: Date())
            account.lastError = nil
            try saveAccount(account)
            return try status().mergingMail([
                "ok": .bool(true),
                "message": .string("IMAP 登录探测成功，邮箱已连接。"),
            ])
        } catch {
            account.connected = false
            account.lastProbeOK = false
            account.lastProbeAt = ISO8601.string(from: Date())
            account.lastError = error.localizedDescription
            try? saveAccount(account)
            return try status().mergingMail([
                "ok": .bool(false),
                "message": .string("IMAP 探测失败：\(error.localizedDescription)"),
            ])
        }
    }

    public func disconnect() throws -> JSONValue {
        var account = loadAccount()
        account.connected = false
        account.lastProbeOK = false
        account.lastError = nil
        try saveAccount(account)
        return try status().mergingMail([
            "ok": .bool(true),
            "message": .string("已断开连接标记。凭证仍保留；要清除密码请点「清除密码」。"),
        ])
    }

    public func clearSecrets() throws -> JSONValue {
        store.secrets.removeSecret(for: KernelStore.mailAppPasswordAccount)
        var account = loadAccount()
        account.connected = false
        account.lastProbeOK = false
        account.lastError = nil
        try saveAccount(account)
        return try status().mergingMail([
            "ok": .bool(true),
            "message": .string("应用密码已从 SecretStore 删除。"),
        ])
    }

    public func listMessages(folder: String, limit: Int, unreadOnly: Bool) async throws -> JSONValue {
        let creds = try requireCreds()
        return try await Task.detached {
            let session = try IMAPSession.connect(host: creds.imapHost, port: creds.imapPort, timeout: 30)
            defer { session.close() }
            try session.login(user: creds.email, password: creds.password)
            let box = folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "INBOX" : folder
            try session.select(mailbox: box)
            let uids = try session.searchUIDs(unreadOnly: unreadOnly)
            let take = Array(uids.suffix(max(1, min(limit, 50))).reversed())
            var items: [JSONValue] = []
            for uid in take {
                let headers = try session.fetchHeaders(uid: uid)
                items.append(.object([
                    "uid": .string(String(uid)),
                    "from": .string(headers["from"] ?? ""),
                    "to": .string(headers["to"] ?? ""),
                    "subject": .string(headers["subject"] ?? ""),
                    "date": .string(headers["date"] ?? ""),
                    "messageId": .string(headers["message-id"] ?? ""),
                ]))
            }
            session.logout()
            return .object([
                "ok": .bool(true),
                "folder": .string(box),
                "count": .number(Double(items.count)),
                "items": .array(items),
            ])
        }.value
    }

    public func readMessage(uid: String, folder: String) async throws -> JSONValue {
        let creds = try requireCreds()
        guard let n = Int(uid), n > 0 else {
            throw MailError.invalidArgument("uid must be a positive IMAP UID")
        }
        return try await Task.detached {
            let session = try IMAPSession.connect(host: creds.imapHost, port: creds.imapPort, timeout: 30)
            defer { session.close() }
            try session.login(user: creds.email, password: creds.password)
            let box = folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "INBOX" : folder
            try session.select(mailbox: box)
            let raw = try session.fetchRFC822(uid: n)
            let parsed = MailMIME.parse(raw)
            session.logout()
            return .object([
                "ok": .bool(true),
                "uid": .string(uid),
                "folder": .string(box),
                "from": .string(parsed.from),
                "to": .string(parsed.to),
                "subject": .string(parsed.subject),
                "date": .string(parsed.date),
                "text": .string(parsed.text),
                "bytes": .number(Double(raw.utf8.count)),
            ])
        }.value
    }

    /// Send-gate: default draft_only. Live SMTP only when confirm=true AND draft_only=false.
    public func send(
        to: String,
        subject: String,
        body: String,
        cc: String?,
        draftOnly: Bool,
        confirm: Bool
    ) throws -> JSONValue {
        let toTrim = to.trimmingCharacters(in: .whitespacesAndNewlines)
        let subjectTrim = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toTrim.isEmpty else { throw MailError.invalidArgument("to is required") }
        guard !subjectTrim.isEmpty else { throw MailError.invalidArgument("subject is required") }

        let account = loadAccount()
        let from = account.email
        let draftID = UUID().uuidString
        let gateBlocked = draftOnly || !confirm
        let draft: [String: JSONValue] = [
            "id": .string(draftID),
            "to": .string(toTrim),
            "cc": .string(cc ?? ""),
            "subject": .string(subjectTrim),
            "body": .string(body),
            "from": .string(from),
            "createdAt": .string(ISO8601.string(from: Date())),
            "sendGate": .string(gateBlocked ? "draft_only" : "live_requested"),
        ]

        try FileManager.default.createDirectory(at: draftsDir, withIntermediateDirectories: true)
        let draftURL = draftsDir.appendingPathComponent("\(draftID).json")
        if let encoded = try? ProtocolCoding.encode(JSONValue.object(draft)) {
            try encoded.write(to: draftURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: draftURL.path)
        }

        if gateBlocked {
            return .object([
                "ok": .bool(true),
                "sent": .bool(false),
                "draft_only": .bool(true),
                "draft_id": .string(draftID),
                "draft_path": .string(draftURL.path),
                "to": .string(toTrim),
                "subject": .string(subjectTrim),
                "message": .string("已写入草稿（send-gate）。实发需 draft_only=false 且 confirm=true。"),
                "next": .string("再次调用 mail.send，传入相同字段并设 draft_only=false, confirm=true。"),
            ])
        }

        let creds = try requireCreds()
        let fromAddr = from.isEmpty ? creds.email : from
        let raw = MailMIME.build(from: fromAddr, to: toTrim, cc: cc, subject: subjectTrim, body: body)
        var recipients = toTrim.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if let cc, !cc.isEmpty {
            recipients.append(contentsOf: cc.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        try SMTPClient.send(
            host: creds.smtpHost,
            port: creds.smtpPort,
            user: creds.email,
            password: creds.password,
            from: fromAddr,
            recipients: recipients,
            data: raw,
            timeout: 30
        )
        return .object([
            "ok": .bool(true),
            "sent": .bool(true),
            "draft_only": .bool(false),
            "draft_id": .string(draftID),
            "draft_path": .string(draftURL.path),
            "to": .string(toTrim),
            "subject": .string(subjectTrim),
            "message": .string("已通过 SMTP 实发（confirm=true）。草稿副本仍保留备查。"),
        ])
    }

    private struct Creds {
        let email: String
        let password: String
        let imapHost: String
        let imapPort: Int
        let smtpHost: String
        let smtpPort: Int
    }

    private func requireCreds() throws -> Creds {
        let account = loadAccount()
        let email = account.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = (store.secrets.secret(for: KernelStore.mailAppPasswordAccount) ?? "")
            .replacingOccurrences(of: " ", with: "")
        guard !email.isEmpty, !password.isEmpty else {
            throw MailError.notConfigured("邮箱未配置。设置 → 通道 → 邮箱 填写地址与应用密码后点连接。")
        }
        guard !account.imapHost.isEmpty else {
            throw MailError.notConfigured("IMAP 主机未设置。")
        }
        return Creds(
            email: email,
            password: password,
            imapHost: account.imapHost,
            imapPort: account.imapPort,
            smtpHost: account.smtpHost.isEmpty ? account.imapHost : account.smtpHost,
            smtpPort: account.smtpPort > 0 ? account.smtpPort : 465
        )
    }
}

private extension JSONValue {
    func mergingMail(_ extras: [String: JSONValue]) -> JSONValue {
        guard case .object(var obj) = self else { return .object(extras) }
        for (k, v) in extras { obj[k] = v }
        return .object(obj)
    }
}
