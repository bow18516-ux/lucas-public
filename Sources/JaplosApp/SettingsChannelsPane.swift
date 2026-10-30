import AppKit
import SwiftUI
import UniformTypeIdentifiers
import JaplosProtocol
import JaplosClient

struct ChannelsSettingsPane: View {
    @ObservedObject var model: AppModel
    @State private var feishuAppID = ""
    @State private var feishuAppSecret = ""
    @State private var feishuVerificationToken = ""
    @State private var mailPreset = "gmail"
    @State private var mailEmail = ""
    @State private var mailDisplayName = ""
    @State private var mailPassword = ""
    @State private var mailImapHost = "imap.gmail.com"
    @State private var mailImapPort = "993"
    @State private var mailSmtpHost = "smtp.gmail.com"
    @State private var mailSmtpPort = "465"
    @State private var busy = false
    @State private var banner: String?

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(
                title: "通道",
                subtitle: "微信 / 飞书 / 邮箱（IMAP·SMTP）。无密钥时不会伪造已连接；外发默认草稿闸门。",
                model: model
            )

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    if let banner {
                        Text(banner)
                            .font(.system(size: SettingsMetrics.captionSize))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                    wechatCard
                    feishuCard
                    mailCard
                }
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.bottom, 24)
            }
        }
        .task {
            await model.refreshChannelStatus()
        }
    }

    private var wechatCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "message.fill")
                    .foregroundStyle(Theme.textSecondary)
                Text("微信")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                statusPill(model.wechatStatusLabel)
            }

            Text(model.wechatStatusDetail)
                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    Task {
                        busy = true
                        defer { busy = false }
                        banner = await model.wechatConnect()
                        await model.refreshChannelStatus()
                    }
                } label: {
                    Text("连接（扫码）")
                        .font(.system(size: SettingsMetrics.bodySize, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(busy)

                Button {
                    Task {
                        busy = true
                        defer { busy = false }
                        banner = await model.wechatDisconnect()
                        await model.refreshChannelStatus()
                    }
                } label: {
                    Text("断开")
                        .font(.system(size: SettingsMetrics.bodySize))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(busy)

                Button {
                    Task { await model.refreshChannelStatus() }
                } label: {
                    Text("刷新状态")
                        .font(.system(size: SettingsMetrics.bodySize))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.pressable)
            }

            Toggle(isOn: Binding(
                get: { model.wechatApprovalPushEnabled },
                set: { enabled in
                    Task {
                        busy = true
                        defer { busy = false }
                        banner = await model.setWechatApprovalPushEnabled(enabled)
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("审批推送到微信")
                        .font(.system(size: SettingsMetrics.bodySize))
                        .foregroundStyle(Theme.textPrimary)
                    Text("工具需审批时发微信文案；回复「同意」或「拒绝」（多笔用「同意 AB12」）。未连接时仍仅桌面卡片；默认开启。")
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(busy)

            if let note = model.wechatStatus["approvalPushLastNote"]?.stringValue, !note.isEmpty {
                Text(note)
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("官方 ClawBot / iLink（ilinkai.weixin.qq.com）。不需要 AppID。真实扫码连通需老板现场扫码验证。硬阻塞：无 live iLink 令牌时审批推送不会伪造送达，桌面审批卡仍可用。超时：桌面约 120s；尝试微信推送时约 300s，超时默认拒绝。")
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

    private var feishuCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "airplane")
                    .foregroundStyle(Theme.textSecondary)
                Text("飞书")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                statusPill(model.feishuStatusLabel)
            }

            Text(model.feishuStatusDetail)
                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                .foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 10) {
                labeledField("App ID", text: $feishuAppID, secure: false)
                labeledField("App Secret", text: $feishuAppSecret, secure: true)
                labeledField("Verification Token（可选）", text: $feishuVerificationToken, secure: true)
            }

            HStack(spacing: 10) {
                Button {
                    Task {
                        busy = true
                        defer { busy = false }
                        banner = await model.feishuConfigure(
                            appID: feishuAppID,
                            appSecret: feishuAppSecret,
                            verificationToken: feishuVerificationToken
                        )
                        feishuAppSecret = ""
                        feishuVerificationToken = ""
                        await model.refreshChannelStatus()
                    }
                } label: {
                    Text("保存凭据")
                        .font(.system(size: SettingsMetrics.bodySize, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(busy)

                Button {
                    Task {
                        busy = true
                        defer { busy = false }
                        banner = await model.feishuConnect()
                        await model.refreshChannelStatus()
                    }
                } label: {
                    Text("连接")
                        .font(.system(size: SettingsMetrics.bodySize))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(busy)

                Button {
                    Task {
                        busy = true
                        defer { busy = false }
                        banner = await model.feishuDisconnect()
                        await model.refreshChannelStatus()
                    }
                } label: {
                    Text("断开")
                        .font(.system(size: SettingsMetrics.bodySize))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.pressable)
                .disabled(busy)
            }

            Text("凭据写入 SecretStore 与 feishu/credentials/auth.sqlite，界面与状态接口不回显密钥。")
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }


    private var mailCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "envelope.fill")
                    .foregroundStyle(Theme.textSecondary)
                Text("邮箱账户")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                statusPill(model.mailStatusLabel)
            }

            Text(model.mailStatusDetail)
                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Presets
            HStack(spacing: 8) {
                ForEach(["gmail", "163", "qq", "exmail", "custom"], id: \.self) { id in
                    let title: String = {
                        switch id {
                        case "gmail": return "Gmail"
                        case "163": return "163"
                        case "qq": return "QQ"
                        case "exmail": return "企业"
                        default: return "自定义"
                        }
                    }()
                    Button {
                        mailPreset = id
                        applyMailPreset(id)
                    } label: {
                        Text(title)
                            .font(.system(size: SettingsMetrics.captionSize, weight: .medium))
                            .foregroundStyle(mailPreset == id ? Color.black.opacity(0.85) : Theme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                mailPreset == id ? Theme.accent : Color.white.opacity(0.06),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                labeledField("邮箱地址", text: $mailEmail, secure: false)
                labeledField("显示名（可选）", text: $mailDisplayName, secure: false)
                labeledField("应用密码 / 授权码", text: $mailPassword, secure: true)
                if mailPreset == "custom" {
                    labeledField("IMAP 主机", text: $mailImapHost, secure: false)
                    labeledField("IMAP 端口", text: $mailImapPort, secure: false)
                    labeledField("SMTP 主机", text: $mailSmtpHost, secure: false)
                    labeledField("SMTP 端口", text: $mailSmtpPort, secure: false)
                } else {
                    Text("IMAP \(mailImapHost):\(mailImapPort) · SMTP \(mailSmtpHost):\(mailSmtpPort)")
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.textSecondary.opacity(0.85))
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task {
                        busy = true
                        defer { busy = false }
                        banner = await model.mailConfigure(
                            preset: mailPreset,
                            email: mailEmail,
                            displayName: mailDisplayName,
                            password: mailPassword,
                            imapHost: mailImapHost,
                            imapPort: mailImapPort,
                            smtpHost: mailSmtpHost,
                            smtpPort: mailSmtpPort
                        )
                        mailPassword = ""
                        await model.refreshChannelStatus()
                        hydrateMailFromStatus()
                    }
                } label: {
                    Text("保存账户")
                        .font(.system(size: SettingsMetrics.bodySize, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(busy)

                Button {
                    Task {
                        busy = true
                        defer { busy = false }
                        banner = await model.mailConnect()
                        await model.refreshChannelStatus()
                    }
                } label: {
                    Text("连接（IMAP 探测）")
                        .font(.system(size: SettingsMetrics.bodySize))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(busy)

                Button {
                    Task {
                        busy = true
                        defer { busy = false }
                        banner = await model.mailDisconnect()
                        await model.refreshChannelStatus()
                    }
                } label: {
                    Text("断开")
                        .font(.system(size: SettingsMetrics.bodySize))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.pressable)
                .disabled(busy)

                Button {
                    Task {
                        busy = true
                        defer { busy = false }
                        banner = await model.mailClearSecrets()
                        await model.refreshChannelStatus()
                    }
                } label: {
                    Text("清除密码")
                        .font(.system(size: SettingsMetrics.bodySize))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.pressable)
                .disabled(busy)
            }

            Text("对齐 OpenClaw：应用密码进 SecretStore/Keychain，不进 git；连接前 IMAP LOGIN 探测。外发工具 mail.send 默认 draft_only，需 confirm=true 才 SMTP 实发。")
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
        .onAppear {
            hydrateMailFromStatus()
        }
    }

    private func applyMailPreset(_ id: String) {
        switch id {
        case "gmail":
            mailImapHost = "imap.gmail.com"; mailImapPort = "993"
            mailSmtpHost = "smtp.gmail.com"; mailSmtpPort = "465"
        case "163":
            mailImapHost = "imap.163.com"; mailImapPort = "993"
            mailSmtpHost = "smtp.163.com"; mailSmtpPort = "465"
        case "qq":
            mailImapHost = "imap.qq.com"; mailImapPort = "993"
            mailSmtpHost = "smtp.qq.com"; mailSmtpPort = "465"
        case "exmail":
            mailImapHost = "imap.exmail.qq.com"; mailImapPort = "993"
            mailSmtpHost = "smtp.exmail.qq.com"; mailSmtpPort = "465"
        default:
            break
        }
    }

    private func hydrateMailFromStatus() {
        if let email = model.mailStatus["email"]?.stringValue, !email.isEmpty {
            mailEmail = email
        }
        if let preset = model.mailStatus["preset"]?.stringValue, !preset.isEmpty {
            mailPreset = preset
        }
        if let host = model.mailStatus["imapHost"]?.stringValue, !host.isEmpty {
            mailImapHost = host
        }
        if let port = model.mailStatus["imapPort"]?.intValue {
            mailImapPort = String(port)
        }
        if let host = model.mailStatus["smtpHost"]?.stringValue, !host.isEmpty {
            mailSmtpHost = host
        }
        if let port = model.mailStatus["smtpPort"]?.intValue {
            mailSmtpPort = String(port)
        }
        if let name = model.mailStatus["displayName"]?.stringValue {
            mailDisplayName = name
        }
    }

    private func statusPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: SettingsMetrics.captionSize, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.06), in: Capsule())
    }

    private func labeledField(_ title: String, text: Binding<String>, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary)
            Group {
                if secure {
                    SecureField(title, text: text)
                } else {
                    TextField(title, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: SettingsMetrics.bodySize))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
        }
    }
}

// MARK: - Updates settings
