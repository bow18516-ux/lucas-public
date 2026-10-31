import AppKit
import SwiftUI
import UniformTypeIdentifiers
import JaplosProtocol
import JaplosClient

struct VoiceSettingsPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: SpeechOutput
    @State private var devices: [AudioDevices.Input] = []

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: "语音设置", subtitle: "输入设备、语音识别与声音偏好", model: model)

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    Text("修改后自动检查并保存")
                        .font(.system(size: SettingsMetrics.cardSubtitleSize))
                        .foregroundStyle(Theme.textSecondary)

                    microphoneCard
                    recognitionCard
                    synthesisCard
                    agentVoiceCard
                }
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.bottom, 24)
            }
        }
        .task {
            devices = AudioDevices.inputs()
            await model.loadSpeechProfile()
        }
        .onChange(of: voice.voiceIdentifier) { _ in Task { await model.syncSpeechProfile(from: voice) } }
        .onChange(of: voice.languageCode) { _ in Task { await model.syncSpeechProfile(from: voice) } }
        .onChange(of: voice.rate) { _ in Task { await model.syncSpeechProfile(from: voice) } }
        .onChange(of: voice.pitch) { _ in Task { await model.syncSpeechProfile(from: voice) } }
        .onChange(of: voice.inputDeviceUID) { _ in Task { await model.syncSpeechProfile(from: voice) } }
        .onChange(of: voice.provider) { _ in Task { await model.syncSpeechProfile(from: voice) } }
        .onChange(of: voice.volcengineVoiceType) { _ in Task { await model.syncSpeechProfile(from: voice) } }
        .onChange(of: voice.volcengineCluster) { _ in Task { await model.syncSpeechProfile(from: voice) } }
        .onChange(of: voice.doubaoSpeaker) { _ in Task { await model.syncSpeechProfile(from: voice) } }
    }

    // MARK: Cards

    private var microphoneCard: some View {
        card(icon: "mic", title: "麦克风", subtitle: "选择语音输入设备") {
            row("输入设备") {
                Menu {
                    Button("跟随系统默认") { voice.inputDeviceUID = "" }
                    Divider()
                    ForEach(devices) { device in
                        Button(device.name) { voice.inputDeviceUID = device.id }
                    }
                } label: {
                    fieldLabel(currentDeviceName)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var recognitionCard: some View {
        card(icon: "waveform", title: "语音识别", subtitle: "将你的声音转换为文字") {
            row("识别服务") { staticField("系统语音识别 · Apple") }
            row("语言") {
                Menu {
                    Button("中文（普通话）") { voice.languageCode = "zh-CN" }
                    Button("English (US)") { voice.languageCode = "en-US" }
                } label: {
                    fieldLabel(voice.languageCode == "en-US" ? "English (US)" : "中文（普通话）")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(maxWidth: .infinity)
            }
            row("API Key") {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.success)
                    Text("系统服务，无需配置 Key")
                        .font(.system(size: SettingsMetrics.cardSubtitleSize))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var synthesisCard: some View {
        card(icon: "speaker.wave.2", title: "语音合成", subtitle: "选择回复的声音、语速与音高") {
            row("合成服务") {
                Menu {
                    ForEach(SpeechOutput.Provider.allCases) { item in
                        Button(item.label) { voice.provider = item }
                    }
                } label: {
                    fieldLabel(voice.provider.label)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(maxWidth: .infinity)
            }
            if voice.provider == .doubaoRealtime {
                row("API Key") {
                    SecureField(voice.doubaoConfigured ? "已保存，输入新 Key 可覆盖" : "火山/豆包 realtime API Key", text: $voice.doubaoAPIKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: SettingsMetrics.bodySize))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
                }
                row("音色") {
                    TextField("如 zh_female_vv_jupiter_bigtts", text: $voice.doubaoSpeaker)
                        .textFieldStyle(.plain)
                        .font(.system(size: SettingsMetrics.bodySize))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
                }
                row("凭证") {
                    HStack(spacing: 10) {
                        Button {
                            Task { await model.syncSpeechProfile(from: voice) }
                        } label: {
                            Text("保存 Key")
                                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                                .foregroundStyle(Color.black.opacity(0.85))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.pressable)
                        Button {
                            voice.speak("你好，我是 Lucas。豆包 realtime 试听。")
                        } label: {
                            Text("测试连接")
                                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.pressable)
                    }
                }
                Text(voice.doubaoConfigured
                     ? "已保存豆包 Key；选用「豆包 realtime」后朗读走 openspeech realtime dialogue。失败时回落系统语音并显示原因。"
                     : "请自行在火山引擎控制台开通豆包端到端实时语音并填入 API Key。软件不会预填或写入任何 Key。")
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary.opacity(0.85))
                if let err = voice.lastCloudError, !err.isEmpty {
                    Text("最近云端错误：\(err)")
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Color.orange.opacity(0.9))
                }
            } else if voice.provider == .volcengine {
                row("App ID") {
                    TextField("火山 App ID", text: $voice.volcengineAppID)
                        .textFieldStyle(.plain)
                        .font(.system(size: SettingsMetrics.bodySize))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
                }
                row("Token") {
                    SecureField(voice.volcengineConfigured ? "已保存，输入新 Token 可覆盖" : "火山 Access Token", text: $voice.volcengineToken)
                        .textFieldStyle(.plain)
                        .font(.system(size: SettingsMetrics.bodySize))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
                }
                row("音色 ID") {
                    TextField("如 BV001_streaming", text: $voice.volcengineVoiceType)
                        .textFieldStyle(.plain)
                        .font(.system(size: SettingsMetrics.bodySize))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
                }
                row("凭证") {
                    Button {
                        Task { await model.syncSpeechProfile(from: voice) }
                    } label: {
                        Text("保存 App ID / Token")
                            .font(.system(size: SettingsMetrics.cardSubtitleSize))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.pressable)
                }
                Text("旧路径：需 AppID+Token 的火山 HTTP TTS。新产品请改用上方「豆包 realtime」（只填 Key）。未配置或失败时回落系统语音。")
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary.opacity(0.85))
                if let err = voice.lastCloudError, !err.isEmpty {
                    Text("最近云端错误：\(err)")
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Color.orange.opacity(0.9))
                }
            } else if voice.provider == .openaiCompatible {
                Text("OpenAI 兼容 TTS 仅为占位，当前仍走系统语音。")
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary.opacity(0.85))
            }
            if voice.provider == .system {
                row("音色") { voiceMenu }
            }
            row("语速") {
                HStack(spacing: 12) {
                    Slider(value: $voice.rate, in: 0.35...0.65)
                        .tint(Theme.accent)
                    Text("\(Int((voice.rate * 360).rounded()))")
                        .font(.system(size: SettingsMetrics.cardSubtitleSize, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            row("音高") {
                HStack(spacing: 12) {
                    Slider(value: $voice.pitch, in: 0.5...2.0)
                        .tint(Theme.accent)
                    Text(String(format: "%.2f", voice.pitch))
                        .font(.system(size: SettingsMetrics.cardSubtitleSize, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            row("试听") {
                HStack(spacing: 10) {
                    Button {
                        voice.speak("你好，我是 Lucas。有什么可以帮你？")
                    } label: {
                        Text("播放示例")
                            .font(.system(size: SettingsMetrics.cardSubtitleSize))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.pressable)

                    if voice.isSpeaking {
                        HStack(spacing: 5) {
                            Circle().fill(Theme.accent).frame(width: 5, height: 5)
                            Text("正在播报")
                                .font(.system(size: SettingsMetrics.captionSize))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var agentVoiceCard: some View {
        card(icon: "slider.horizontal.3", title: "智能体音色", subtitle: "播报开关与快速调音") {
            row("自动播报回复") {
                Toggle("", isOn: $voice.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
            }
            row("快捷") {
                HStack(spacing: 10) {
                    Button("重置语速/音高") {
                        voice.rate = 0.50
                        voice.pitch = 1.0
                    }
                    .buttonStyle(.pressable)
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.accent)
                    if voice.isSpeaking {
                        Button("停止播报") { voice.stop() }
                            .buttonStyle(.pressable)
                            .font(.system(size: SettingsMetrics.cardSubtitleSize))
                            .foregroundStyle(Color.red.opacity(0.85))
                    }
                }
            }
            Text("改动会同步到 speech_profiles；豆包 Key / 火山凭证走 SecretStore，不会写入仓库。未配置或失败时自动回退系统语音并显示原因。")
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary.opacity(0.75))
        }
    }

    // MARK: Building blocks

    private func card<Content: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: SettingsMetrics.bodySize))
                    .foregroundStyle(Theme.textSecondary)
                Text(title)
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder control: () -> Content) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .font(.system(size: SettingsMetrics.labelSize))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: SettingsMetrics.labelWidth, alignment: .leading)
            control()
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: SettingsMetrics.labelSize))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
    }

    private func staticField(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: SettingsMetrics.labelSize))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
    }

    private var voiceMenu: some View {
        Menu {
            Button("系统默认") { voice.voiceIdentifier = "" }
            if !SpeechOutput.chineseVoices.isEmpty {
                Divider()
                Text("中文")
                ForEach(SpeechOutput.chineseVoices, id: \.identifier) { item in
                    Button("\(item.name) · \(item.language)") { voice.voiceIdentifier = item.identifier }
                }
            }
            if !SpeechOutput.englishVoices.isEmpty {
                Divider()
                Text("English")
                ForEach(SpeechOutput.englishVoices.prefix(40), id: \.identifier) { item in
                    Button("\(item.name) · \(item.language)") { voice.voiceIdentifier = item.identifier }
                }
            }
        } label: {
            fieldLabel(currentVoiceName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
    }

    private var currentVoiceName: String {
        guard !voice.voiceIdentifier.isEmpty else { return "系统默认" }
        let all = SpeechOutput.chineseVoices + SpeechOutput.englishVoices
        if let item = all.first(where: { $0.identifier == voice.voiceIdentifier }) {
            return "\(item.name) · \(item.language)"
        }
        return voice.voiceIdentifier
    }

    private var currentDeviceName: String {
        if voice.inputDeviceUID.isEmpty { return "跟随系统默认" }
        return devices.first(where: { $0.id == voice.inputDeviceUID })?.name ?? "跟随系统默认"
    }
}



// MARK: - Memory / knowledge backup
