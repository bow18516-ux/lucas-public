import Combine
import Foundation
import JaplosProtocol
import JaplosClient
import PDFKit
import AppKit

@MainActor
extension AppModel {
    // MARK: - Channels (微信 / 飞书)

    var wechatStatusLabel: String {
        let state = wechatStatus["state"]?.stringValue ?? "unknown"
        switch state {
        case "connected": return "已连接"
        case "awaiting_scan": return "待扫码"
        case "verification_required": return "需验证码"
        case "needs_auth": return "需授权"
        case "disconnected": return "未连接"
        case "unavailable": return "不可用"
        default: return state
        }
    }

    var wechatStatusDetail: String {
        if let msg = wechatStatus["message"]?.stringValue, !msg.isEmpty { return msg }
        if let action = wechatStatus["action"]?.stringValue, !action.isEmpty { return action }
        if let err = wechatStatus["lastError"]?.stringValue, !err.isEmpty { return err }
        let count = wechatStatus["connectedAccountCount"]?.intValue ?? 0
        return "账号数 \(count) · 状态 \(wechatStatus["state"]?.stringValue ?? "—")"
    }

    var feishuStatusLabel: String {
        let state = feishuStatus["state"]?.stringValue ?? "unknown"
        switch state {
        case "connected": return "已连接"
        case "awaiting_configuration": return "待配置"
        case "needs_auth": return "需凭据"
        case "disconnected": return "未连接"
        case "connecting": return "连接中"
        case "error": return "错误"
        default: return state
        }
    }

    var feishuStatusDetail: String {
        if let msg = feishuStatus["message"]?.stringValue, !msg.isEmpty { return msg }
        if let action = feishuStatus["action"]?.stringValue, !action.isEmpty { return action }
        let app = feishuStatus["appIdConfigured"]?.boolValue == true
        let secret = feishuStatus["appSecretConfigured"]?.boolValue == true
        return "App ID \(app ? "已配置" : "未配置") · Secret \(secret ? "已配置" : "未配置")"
    }

    func refreshChannelStatus() async {
        do {
            wechatStatus = try await client.callAsync(.runtimeWeChatStatus, arguments: .object([:]))
            if let enabled = wechatStatus["approvalPushEnabled"]?.boolValue {
                wechatApprovalPushEnabled = enabled
            }
        } catch {
            wechatStatus = .object([
                "state": .string("unavailable"),
                "message": .string((error as? ClientError)?.description ?? String(describing: error)),
            ])
        }
        do {
            feishuStatus = try await client.callAsync(.runtimeFeishuStatus, arguments: .object([:]))
        } catch {
            feishuStatus = .object([
                "state": .string("unavailable"),
                "message": .string((error as? ClientError)?.description ?? String(describing: error)),
            ])
        }
        do {
            mailStatus = try await client.callAsync(.runtimeMailStatus, arguments: .object([:]))
        } catch {
            mailStatus = .object([
                "state": .string("unavailable"),
                "message": .string((error as? ClientError)?.description ?? String(describing: error)),
            ])
        }
    }

    func wechatConnect() async -> String {
        do {
            let result = try await client.callAsync(.runtimeWeChatConnect, arguments: .object([:]), timeout: 30)
            wechatStatus = result
            return result["message"]?.stringValue
                ?? (result["ok"]?.boolValue == true ? "已启动扫码登录" : (result["error"]?.stringValue ?? "连接未完成"))
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func wechatDisconnect() async -> String {
        do {
            let result = try await client.callAsync(.runtimeWeChatDisconnect, arguments: .object([:]))
            wechatStatus = result
            return result["message"]?.stringValue ?? "已断开"
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func setWechatApprovalPushEnabled(_ enabled: Bool) async -> String {
        wechatApprovalPushEnabled = enabled
        do {
            _ = try await client.callAsync(.configurationSet, arguments: .object([
                "path": .string("channels.wechat.approvalPush"),
                "value": .object([
                    "enabled": .bool(enabled),
                ]),
            ]))
            await refreshChannelStatus()
            return enabled ? "已开启：审批将尝试推送到微信" : "已关闭：审批仅桌面卡片"
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }


    func feishuConfigure(appID: String, appSecret: String, verificationToken: String) async -> String {
        var args: [String: JSONValue] = [:]
        if !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["app_id"] = .string(appID.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !appSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["app_secret"] = .string(appSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !verificationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["verification_token"] = .string(verificationToken.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do {
            let result = try await client.callAsync(.feishuConnectionConfigure, arguments: .object(args))
            feishuStatus = result
            return result["message"]?.stringValue ?? "已保存"
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func feishuConnect() async -> String {
        do {
            let result = try await client.callAsync(.runtimeFeishuConnect, arguments: .object([:]), timeout: 30)
            feishuStatus = result
            return result["message"]?.stringValue
                ?? (result["ok"]?.boolValue == true ? "已连接" : (result["error"]?.stringValue ?? "连接失败"))
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func feishuDisconnect() async -> String {
        do {
            let result = try await client.callAsync(.runtimeFeishuDisconnect, arguments: .object([:]))
            feishuStatus = result
            return result["message"]?.stringValue ?? "已断开"
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }


    var mailStatusLabel: String {
        let state = mailStatus["state"]?.stringValue ?? "unknown"
        switch state {
        case "connected": return "已连接"
        case "configured": return "已配置"
        case "disconnected": return "未连接"
        case "unavailable": return "不可用"
        default: return state
        }
    }

    var mailStatusDetail: String {
        if let msg = mailStatus["message"]?.stringValue, !msg.isEmpty { return msg }
        if let action = mailStatus["action"]?.stringValue, !action.isEmpty { return action }
        let email = mailStatus["email"]?.stringValue ?? ""
        let pwd = mailStatus["passwordConfigured"]?.boolValue == true
        return "\(email.isEmpty ? "未填地址" : email) · 密码 \(pwd ? "已存" : "未存")"
    }

    func mailConfigure(
        preset: String,
        email: String,
        displayName: String,
        password: String,
        imapHost: String,
        imapPort: String,
        smtpHost: String,
        smtpPort: String
    ) async -> String {
        var args: [String: JSONValue] = [
            "preset": .string(preset),
        ]
        if !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["email"] = .string(email.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["displayName"] = .string(displayName.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !password.isEmpty {
            args["password"] = .string(password)
        }
        if !imapHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["imapHost"] = .string(imapHost.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let p = Int(imapPort.trimmingCharacters(in: .whitespacesAndNewlines)), p > 0 {
            args["imapPort"] = .number(Double(p))
        }
        if !smtpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["smtpHost"] = .string(smtpHost.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let p = Int(smtpPort.trimmingCharacters(in: .whitespacesAndNewlines)), p > 0 {
            args["smtpPort"] = .number(Double(p))
        }
        do {
            let result = try await client.callAsync(.runtimeMailConfigure, arguments: .object(args))
            mailStatus = result
            return result["message"]?.stringValue ?? "已保存"
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func mailConnect() async -> String {
        do {
            let result = try await client.callAsync(.runtimeMailConnect, arguments: .object([:]), timeout: 35)
            mailStatus = result
            return result["message"]?.stringValue
                ?? (result["ok"]?.boolValue == true ? "已连接" : "连接失败")
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func mailDisconnect() async -> String {
        do {
            let result = try await client.callAsync(.runtimeMailDisconnect, arguments: .object([:]))
            mailStatus = result
            return result["message"]?.stringValue ?? "已断开"
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func mailClearSecrets() async -> String {
        do {
            let result = try await client.callAsync(.runtimeMailClearSecrets, arguments: .object([:]))
            mailStatus = result
            return result["message"]?.stringValue ?? "已清除密码"
        } catch {
            return (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func dismissError() {
        errorText = nil
    }

    static func approvalSummary(_ arguments: JSONValue?) -> String {
        ApprovalPresentation.summary(arguments)
    }
}
