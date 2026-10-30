import Foundation
import JaplosProtocol

/// Bridges tool-approval requests to WeChat (ClawBot / iLink) so the user can
/// approve/deny while away from the Mac. Desktop socket approvals remain the
/// primary path; WeChat is a side channel.
///
/// Hard block: without a live iLink session token, WeChat delivery will not
/// fabricate delivery — it reports `needsLiveILink` / `not_connected` clearly.
public final class WeChatApprovalBridge: @unchecked Sendable {
    public static let configPath = "channels.wechat.approvalPush"
    /// Desktop-only wait (seconds).
    public static let desktopTimeout: TimeInterval = 120
    /// Longer wait when a WeChat push was attempted (user may be away from Mac).
    public static let wechatPushTimeout: TimeInterval = 300

    private struct Entry {
        let shortId: String
        let title: String
        let name: String
        let resolve: (Bool) -> Void
    }

    /// Remembered decision so a late WeChat reply cannot re-fire the tool
    /// and can still get a brief already-decided ack.
    public struct Settled: Equatable {
        public let callID: String
        public let shortId: String
        public let approved: Bool
        public let source: String
        public let at: Date
    }

    private let store: KernelStore
    private let wechat: WeChatChannel
    private let lock = NSLock()
    private var byCallID: [String: Entry] = [:]
    private var callIDByShortId: [String: String] = [:]
    private var settledByCallID: [String: Settled] = [:]
    private var settledByShortId: [String: Settled] = [:]
    private var pushedAtByShortId: [String: Date] = [:]
    private var seenCursors: Set<String> = []
    private var lastPushNote: String?

    public init(store: KernelStore, wechat: WeChatChannel) {
        self.store = store
        self.wechat = wechat
    }

    // MARK: - Settings

    /// Default **on** when unset (push when WeChat appears connected).
    public func isPushEnabled() -> Bool {
        guard let value = try? store.configurationValue(Self.configPath) else {
            return true
        }
        if let flag = value.boolValue { return flag }
        if let object = value.objectValue, let flag = object["enabled"]?.boolValue {
            return flag
        }
        return true
    }

    public func setPushEnabled(_ enabled: Bool, updatedBy: String = "settings") throws {
        try store.setConfiguration(
            path: Self.configPath,
            value: .object([
                "enabled": .bool(enabled),
                "updatedAt": .string(ISO8601.string(from: Date())),
            ]),
            updatedBy: updatedBy
        )
    }

    /// True when the toggle is on and WeChat ledger reports connected.
    /// Still does not guarantee live iLink delivery.
    public func statusExtras() -> [String: JSONValue] {
        let enabled = isPushEnabled()
        var extras: [String: JSONValue] = [
            "approvalPushEnabled": .bool(enabled),
            "approvalPushConfigPath": .string(Self.configPath),
            "approvalPushWillAttempt": .bool(false),
            "approvalPushDesktopTimeoutSec": .number(Self.desktopTimeout),
            "approvalPushWeChatTimeoutSec": .number(Self.wechatPushTimeout),
            "approvalPushReplyHint": .string("回复「同意」或「拒绝」；多笔待批时用「同意 AB12」/「拒绝 AB12」。"),
            "approvalPushHardBlock": .string(
                "Live delivery needs ClawBot QR scan + iLink session token. Without it, push reports not_connected/needsLiveILink and desktop card remains fallback."
            ),
        ]
        if let lastPushNote {
            extras["approvalPushLastNote"] = .string(lastPushNote)
        }
        lock.lock()
        let pendingCount = byCallID.count
        let settledCount = settledByCallID.count
        lock.unlock()
        extras["approvalPushPendingCount"] = .number(Double(pendingCount))
        extras["approvalPushSettledCount"] = .number(Double(settledCount))
        extras["approvalPushSyncNote"] = .string(
            "Desktop and WeChat share one ApprovalBroker decision; late WeChat replies get already-decided ack."
        )
        return extras
    }

    // MARK: - Registry

    public static let senderPath = "channels.wechat.approvalSender"

    public static func makeShortId(for callID: String) -> String {
        let hex = callID.replacingOccurrences(of: "-", with: "").uppercased()
        if hex.count >= 6 {
            return String(hex.prefix(6))
        }
        return String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).uppercased()
    }

    /// Account allowed to approve over WeChat. Unset means inbound text never approves.
    public func boundApprovalSender() -> String? {
        guard let value = try? store.configurationValue(Self.senderPath) else { return nil }
        if let text = value.stringValue, !text.isEmpty { return text }
        if let object = value.objectValue, let text = object["sender"]?.stringValue, !text.isEmpty {
            return text
        }
        return nil
    }

    public func register(
        callID: String,
        shortId: String,
        title: String,
        name: String,
        onResolve: @escaping (Bool) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        // Avoid shortId collisions while both are pending.
        var sid = shortId
        if let existing = callIDByShortId[sid], existing != callID {
            sid = Self.makeShortId(for: UUID().uuidString)
        }
        byCallID[callID] = Entry(shortId: sid, title: title, name: name, resolve: onResolve)
        callIDByShortId[sid] = callID
        pushedAtByShortId[sid.uppercased()] = Date()
    }

    /// Remove without invoking the resolve callback (socket path already resumed).
    /// Prefer `settle` so late WeChat replies can still ack.
    public func clear(callID: String) {
        lock.lock()
        defer { lock.unlock() }
        if let entry = byCallID.removeValue(forKey: callID) {
            callIDByShortId.removeValue(forKey: entry.shortId)
        }
    }

    public func clearAll() {
        lock.lock()
        byCallID.removeAll()
        callIDByShortId.removeAll()
        settledByCallID.removeAll()
        settledByShortId.removeAll()
        lock.unlock()
    }

    public func settled(callID: String) -> Settled? {
        lock.lock()
        defer { lock.unlock() }
        return settledByCallID[callID]
    }

    public func settled(shortId: String) -> Settled? {
        lock.lock()
        defer { lock.unlock() }
        return settledByShortId[shortId.uppercased()]
    }

    /// Mark decided without re-invoking the tool continuation.
    /// Desktop / timeout paths call this after resuming the broker.
    /// Idempotent: first decision wins; later calls only refresh TTL bookkeeping.
    @discardableResult
    public func settle(
        callID: String,
        approved: Bool,
        source: String,
        notifyWeChat: Bool = true
    ) -> Settled? {
        lock.lock()
        pruneSettledLocked(now: Date())
        if let existing = settledByCallID[callID] {
            // First decision wins — do not re-notify or flip.
            lock.unlock()
            return existing
        }
        var shortId = WeChatApprovalBridge.makeShortId(for: callID)
        if let entry = byCallID.removeValue(forKey: callID) {
            callIDByShortId.removeValue(forKey: entry.shortId)
            shortId = entry.shortId
        }
        let record = Settled(
            callID: callID,
            shortId: shortId,
            approved: approved,
            source: source,
            at: Date()
        )
        settledByCallID[callID] = record
        settledByShortId[shortId] = record
        lock.unlock()
        if notifyWeChat {
            sendSettledAck(record)
        }
        return record
    }

    /// Ask the registered broker callback to resolve. Does **not** settle here —
    /// `ApprovalBroker.resolve` is the single winner (continuation + settle + UI event).
    /// Returns true only when this call newly settled the request.
    @discardableResult
    public func resolve(callID: String, approved: Bool) -> Bool {
        lock.lock()
        pruneSettledLocked(now: Date())
        if settledByCallID[callID] != nil {
            lock.unlock()
            return false
        }
        guard let entry = byCallID[callID] else {
            lock.unlock()
            return false
        }
        lock.unlock()
        entry.resolve(approved)
        lock.lock()
        let won = settledByCallID[callID] != nil
        lock.unlock()
        return won
    }

    @discardableResult
    public func resolve(shortId: String, approved: Bool) -> Bool {
        lock.lock()
        let callID = callIDByShortId[shortId.uppercased()]
        lock.unlock()
        guard let callID else { return false }
        return resolve(callID: callID, approved: approved)
    }

    // MARK: - Inbound

    /// Parse approve/deny from WeChat. Requires the bound sender, a message time
    /// at or after the push, a fresh cursor, and a 6-character approval id.
    @discardableResult
    public func handleInboundText(
        _ text: String,
        sender: String? = nil,
        sentAt: Date? = nil,
        cursor: String? = nil
    ) -> Bool {
        guard let bound = boundApprovalSender(), !bound.isEmpty else { return false }
        guard let sender, sender == bound else { return false }
        if let cursor {
            lock.lock()
            let seen = seenCursors.contains(cursor)
            lock.unlock()
            if seen { return false }
        }
        guard let decision = Self.parseDecision(text), let shortId = decision.shortId else { return false }
        lock.lock()
        let pushed = pushedAtByShortId[shortId.uppercased()]
        lock.unlock()
        guard let sentAt, let pushed, sentAt >= pushed else { return false }
        let accepted = resolve(shortId: shortId, approved: decision.approved)
            || ackIfAlreadySettled(shortId: shortId)
        if accepted, let cursor {
            lock.lock()
            seenCursors.insert(cursor)
            lock.unlock()
        }
        return accepted
    }

    /// Returns true when the shortId was already decided (message consumed).
    @discardableResult
    public func ackIfAlreadySettled(shortId: String) -> Bool {
        lock.lock()
        let record = settledByShortId[shortId.uppercased()]
        lock.unlock()
        guard let record else { return false }
        sendAlreadyDecidedAck(record, lateReply: true)
        return true
    }

    // MARK: - Parsing (testable)

    public struct Decision: Equatable {
        public let approved: Bool
        public let shortId: String?
    }

    /// Accepts 同意 / 拒绝 / 批准 / 允许 / approve / deny only when followed by
    /// a 6-character hex id. `ok`, `y`, `yes`, `no` and a bare 同意 are ignored.
    public static func parseDecision(_ raw: String) -> Decision? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed
            .replacingOccurrences(of: "：", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "　", with: " ")
        let lower = normalized.lowercased()

        let approveTokens = ["允许执行", "同意", "批准", "允许", "approve"]
        let denyTokens = ["不允许", "拒绝", "deny"]

        func match(tokens: [String]) -> String? {
            for token in tokens {
                let t = token.lowercased()
                let rest: String
                if lower.hasPrefix(t + " ") {
                    rest = normalized.dropFirst(token.count).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if token.count >= 2, lower.hasPrefix(t), lower.count > t.count {
                    rest = String(normalized.dropFirst(token.count))
                } else {
                    continue
                }
                if let sid = extractShortId(from: rest) {
                    return sid
                }
            }
            return nil
        }

        if let shortId = match(tokens: denyTokens) {
            return Decision(approved: false, shortId: shortId)
        }
        if let shortId = match(tokens: approveTokens) {
            return Decision(approved: true, shortId: shortId)
        }
        return nil
    }

    private static func extractShortId(from rest: String) -> String? {
        let hex = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
        guard hex.count >= 6 else { return nil }
        let candidate = String(hex.prefix(6))
        guard candidate.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789ABCDEF").contains($0) }) else {
            return nil
        }
        return candidate
    }

    // MARK: - Settled acks

    private func pruneSettledLocked(now: Date) {
        let ttl = Self.wechatPushTimeout + 120
        let staleCallIDs = settledByCallID.compactMap { id, record -> String? in
            now.timeIntervalSince(record.at) > ttl ? id : nil
        }
        for id in staleCallIDs {
            if let record = settledByCallID.removeValue(forKey: id) {
                settledByShortId.removeValue(forKey: record.shortId)
            }
        }
    }

    private func sendSettledAck(_ record: Settled) {
        guard isPushEnabled() else { return }
        let verdict = record.approved ? "已通过" : "已拒绝"
        let whereFrom: String
        switch record.source {
        case "desktop":
            whereFrom = "桌面"
        case "wechat":
            whereFrom = "微信"
        case "timeout":
            whereFrom = "超时默认"
        default:
            whereFrom = record.source
        }
        let body: String
        if record.source == "wechat" {
            body = "【Lucas】\(record.shortId) \(verdict)（微信），开始按该决定执行。桌面卡片已同步。"
        } else if record.source == "timeout" {
            body = "【Lucas】\(record.shortId) 已超时默认拒绝。桌面与微信两侧均已收口。"
        } else {
            body = "【Lucas】\(record.shortId) \(verdict)（\(whereFrom)）。微信侧无需再回；迟回复将提示已处理。"
        }
        _ = try? wechat.sendText(text: body, suppressAck: true)
        lastPushNote = body
    }

    private func sendAlreadyDecidedAck(_ record: Settled, lateReply: Bool) {
        guard isPushEnabled() else { return }
        let verdict = record.approved ? "已通过" : "已拒绝"
        let whereFrom: String
        switch record.source {
        case "desktop": whereFrom = "桌面"
        case "wechat": whereFrom = "微信"
        case "timeout": whereFrom = "超时"
        default: whereFrom = record.source
        }
        let prefix = lateReply ? "无需重复操作：" : ""
        let body = "【Lucas】\(record.shortId) \(prefix)\(verdict)（\(whereFrom)），本次回复已忽略。"
        _ = try? wechat.sendText(text: body, suppressAck: true)
        lastPushNote = body
    }

    private static func compactSummary(_ arguments: JSONValue) -> String {
        let text = (try? arguments.encodedString()) ?? ""
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        if oneLine.count <= 280 { return oneLine }
        return String(oneLine.prefix(280)) + "…"
    }
}
