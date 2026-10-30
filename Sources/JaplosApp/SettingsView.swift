import AppKit
import SwiftUI
import JaplosProtocol

/// One typographic + spacing scale for every settings page.
enum SettingsMetrics {
    /// Page chrome title in the detail pane (e.g. 「Skill 列表」).
    static let pageTitleSize: CGFloat = 26
    static let pageSubtitleSize: CGFloat = 14
    static let navSize: CGFloat = 15
    static let navIconSize: CGFloat = 16
    /// Section / card titles — one point above `bodySize`.
    static let cardTitleSize: CGFloat = 15
    /// Secondary lines under titles / helper copy.
    static let cardSubtitleSize: CGFloat = 13
    static let labelSize: CGFloat = 14
    /// Primary body copy across every settings detail pane.
    static let bodySize: CGFloat = 14
    static let captionSize: CGFloat = 12
    static let microSize: CGFloat = 11
    static let metricSize: CGFloat = 24

    static let sidebarWidth: CGFloat = 268
    /// Detail pane fills remaining window width; horizontal inset is `pagePadding` only.
    static let cardPadding: CGFloat = 22
    static let cardSpacing: CGFloat = 18
    static let rowSpacing: CGFloat = 14
    static let labelWidth: CGFloat = 104
    /// Even left/right inset inside the settings detail pane (from sidebar divider and window edge).
    static let pagePadding: CGFloat = 20
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case model = "大模型设置"
    case voice = "语音设置"
    case alarms = "提醒"
    case channels = "通道"
    case mcp = "MCP 服务"
    case skills = "Skill 列表"
    case tools = "工具列表"
    case updates = "在线更新"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .model: return "cpu"
        case .voice: return "waveform"
        case .alarms: return "bell"
        case .channels: return "antenna.radiowaves.left.and.right"
        case .mcp: return "globe.asia.australia"
        case .skills: return "square.stack.3d.up"
        case .tools: return "wrench.and.screwdriver"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }
}

struct SettingsScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: SpeechOutput
    @State private var section: SettingsSection
    @ObservedObject private var updateService = UpdateService.shared

    init(model: AppModel, voice: SpeechOutput) {
        self.model = model
        self.voice = voice
        let requested = ProcessInfo.processInfo.environment["LUCAS_SETTINGS_SECTION"] ?? ""
        _section = State(initialValue: SettingsSection.allCases.first { $0.rawValue == requested } ?? .model)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: SettingsMetrics.sidebarWidth)
            Rectangle()
                .fill(Theme.panelBorder)
                .frame(width: 0.8)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.background.ignoresSafeArea())
        .onExitCommand { model.settingsPresented = false }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.settingsPresented = false
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: SettingsMetrics.labelSize, weight: .medium))
                    Text("返回主界面")
                        .font(.system(size: SettingsMetrics.bodySize))
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 18)
            .padding(.top, 54)
            .padding(.bottom, 22)

            Text("设置")
                .font(.system(size: SettingsMetrics.pageTitleSize, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 18)
                .padding(.bottom, 16)

            VStack(spacing: 4) {
                ForEach(SettingsSection.allCases) { item in
                    Button {
                        section = item
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.icon)
                                .font(.system(size: SettingsMetrics.cardTitleSize))
                                .frame(width: 22)
                            Text(item.rawValue)
                                .font(.system(size: SettingsMetrics.cardTitleSize))
                            Spacer()
                            if section == item {
                                Circle()
                                    .fill(Theme.accent)
                                    .frame(width: 4, height: 4)
                            } else if item == .updates && updateService.updateAvailable {
                                Circle()
                                    .fill(Theme.accent)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .foregroundStyle(section == item ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(
                            section == item ? Theme.accent.opacity(0.10) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .overlay(alignment: .leading) {
                            if section == item {
                                Rectangle()
                                    .fill(Theme.accent)
                                    .frame(width: 2)
                                    .padding(.vertical, 6)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            VStack(alignment: .leading, spacing: 2) {
                Text("LUCAS")
                    .font(.system(size: SettingsMetrics.cardSubtitleSize, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(Theme.textPrimary.opacity(0.8))
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel.opacity(0.35))
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .model:
            ModelSettingsPane(model: model)
        case .tools:
            ToolsSettingsPane(model: model)
        case .skills:
            SkillsSettingsPane(model: model)
        case .voice:
            VoiceSettingsPane(model: model, voice: voice)
        case .alarms:
            AlarmsSettingsPane(model: model)
        case .channels:
            ChannelsSettingsPane(model: model)
        case .mcp:
            MCPSettingsPane(model: model)
        case .updates:
            UpdatesSettingsPane(updates: UpdateService.shared, model: model)
        }
    }
}

// MARK: - Header

struct SettingsHeader: View {
    let title: String
    let subtitle: String
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: SettingsMetrics.pageTitleSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Esc 返回") { model.settingsPresented = false }
                    .buttonStyle(.borderless)
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(subtitle)
                .font(.system(size: SettingsMetrics.bodySize))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, SettingsMetrics.pagePadding)
        .padding(.top, 60)
        .padding(.bottom, 20)
    }
}

// MARK: - Model settings

struct ModelSettingsPane: View {
    @ObservedObject var model: AppModel
    @State private var protocolName = "Chat Completions"
    @State private var savedNote = "配置已同步"
    @State private var savedRoutes: [JSONValue] = []

    private let protocols = ["Chat Completions", "Responses"]

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: "大模型设置", subtitle: "管理模型服务、连接与默认对话模型", model: model)

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    currentCard
                    configuredCard
                    routesCard
                    connectionCard
                }
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.bottom, 20)
            }

            bottomBar
        }
        .task { await reloadRoutes() }
    }

    private func reloadRoutes() async {
        savedRoutes = await model.listModelRoutes()
    }

    private var routesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("路由历史")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(savedRoutes.count)")
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    Task { await reloadRoutes() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: SettingsMetrics.cardSubtitleSize))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
            }

            if savedRoutes.isEmpty {
                Text("保存连接后会出现在这里（写入 custom_model_routes）。")
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(Array(savedRoutes.enumerated()), id: \.offset) { _, route in
                    ModelRouteRow(route: route) { title in
                        let record = route["record"]
                        if let base = record?["baseURL"]?.stringValue { model.settings.baseURL = base }
                        if let m = record?["model"]?.stringValue { model.settings.model = m }
                        if let temp = record?["temperature"]?.doubleValue { model.settings.temperature = temp }
                        if let name = record?["displayName"]?.stringValue { model.settings.displayName = name }
                        savedNote = "已填入 \(title)，确认 Key 后点保存"
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

    private var currentCard: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("当前使用")
                    .font(.system(size: SettingsMetrics.labelSize, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .font(.system(size: SettingsMetrics.cardTitleSize))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.hasStoredConnection && !model.settings.model.isEmpty ? model.settings.model : "未配置")
                            .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                        Text(model.hasStoredConnection ? providerLabel : "尚未选择服务商")
                            .font(.system(size: SettingsMetrics.cardSubtitleSize))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Text("保存配置后用于后续模型调用；连接可用性以实际调用结果为准。")
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
            }
            Spacer()
            Button {
                Task { await model.testModel() }
            } label: {
                Text(model.isTestingModel ? "检查中…" : "检查当前配置")
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.borderless)
            .disabled(model.isTestingModel || !model.hasStoredConnection)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

    private var configuredCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("已配置服务")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(model.hasStoredConnection ? "1" : "0")
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("新增连接") {
                    model.settings = ModelConnection(
                        baseURL: "https://api.deepseek.com/v1",
                        model: "",
                        apiKey: "",
                        temperature: 0.3,
                        displayName: ""
                    )
                    model.hasStoredConnection = false
                    savedNote = "已清空表单，填写后点保存并使用"
                }
                    .buttonStyle(.borderless)
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.accent)
                Button {
                    Task { await model.loadTools() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: SettingsMetrics.cardSubtitleSize))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
            }

            if model.hasStoredConnection {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Text(providerLabel)
                                .font(.system(size: SettingsMetrics.bodySize, weight: .medium))
                            Text("当前使用")
                                .font(.system(size: SettingsMetrics.microSize))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.12), in: Capsule())
                        }
                        Text(model.settings.baseURL)
                            .font(.system(size: SettingsMetrics.cardSubtitleSize, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.shield")
                                .font(.system(size: SettingsMetrics.captionSize))
                            Text(model.storedAPIKey.isEmpty ? "凭据未配置" : "凭据已保存")
                        }
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.textSecondary.opacity(0.85))
                    }
                    Spacer()
                    Button("选择并使用模型") {
                        Task {
                            await model.refreshModels()
                            if model.availableModels.isEmpty {
                                savedNote = "未能拉取模型列表，请检查 Base URL / Key"
                            } else if model.settings.model.isEmpty,
                                      let first = model.availableModels.first {
                                await model.switchModel(first)
                                savedNote = "已选用 \(first)"
                            } else if !model.settings.model.isEmpty {
                                let ok = await model.saveSettings()
                                savedNote = ok ? "已保存并使用 \(model.settings.model)" : "保存失败"
                            }
                        }
                    }
                        .buttonStyle(.borderless)
                        .font(.system(size: SettingsMetrics.cardSubtitleSize))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(10)
                .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.panelBorder, style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                    .frame(height: 92)
                    .overlay {
                        VStack(spacing: 4) {
                            Text("还没有配置模型连接")
                                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                                .foregroundStyle(Theme.textPrimary)
                            Text("填写下方 Base URL、API Key 和模型，然后保存并使用")
                                .font(.system(size: SettingsMetrics.captionSize))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("连接配置")
                .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            field("服务商") {
                darkMenu(selection: providerSelection, options: ["DeepSeek", "MiMo", "OpenAI", "OpenAI 兼容", "Pollinations 测试", "自定义"], width: 200)
            }

            field("Base URL") {
                TextField("https://api.deepseek.com/v1", text: $model.settings.baseURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsMetrics.labelSize, design: .monospaced))
                    .padding(9)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
            }

            HStack(alignment: .firstTextBaseline) {
                Text("API Key")
                    .font(.system(size: SettingsMetrics.labelSize))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: SettingsMetrics.captionSize))
                    Text(model.storedAPIKey.isEmpty ? "未保存" : "已保存")
                }
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary)
            }
            SecureField("输入新 Key 可替换，留空保持不变", text: $model.settings.apiKey)
                .textFieldStyle(.plain)
                .font(.system(size: SettingsMetrics.labelSize))
                .padding(9)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
            Text("已保存的密钥不会回填到输入框。")
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary.opacity(0.7))

            HStack(alignment: .firstTextBaseline) {
                Text("对话模型")
                    .font(.system(size: SettingsMetrics.labelSize))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                HStack(spacing: 10) {
                    Menu {
                        if model.availableModels.isEmpty {
                            Text("先点“刷新列表”")
                        } else {
                            ForEach(model.availableModels, id: \.self) { id in
                                Button(id) { model.settings.model = id }
                            }
                        }
                    } label: {
                        Text("选择模型…")
                            .font(.system(size: SettingsMetrics.captionSize))
                            .foregroundStyle(Theme.accent)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Button("刷新列表") {
                        Task { await model.refreshModels() }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
                }
            }
            TextField("例如 deepseek-chat", text: $model.settings.model)
                .textFieldStyle(.plain)
                .font(.system(size: SettingsMetrics.bodySize, design: .monospaced))
                .padding(8)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
            Text("填写供应商 API 使用的完整模型 ID，保存后会保留在列表中。")
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary.opacity(0.7))

            field("连接名称（可选）") {
                TextField("例如 DeepSeek 主连接", text: $model.settings.displayName)
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsMetrics.labelSize))
                    .padding(9)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
            }

            field("温度") {
                HStack(spacing: 12) {
                    Slider(value: $model.settings.temperature, in: 0...1.5, step: 0.05)
                        .tint(Theme.accent)
                    Text(String(format: "%.2f", model.settings.temperature))
                        .font(.system(size: SettingsMetrics.cardSubtitleSize, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text("API 协议")
                    .font(.system(size: SettingsMetrics.labelSize))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            darkMenu(selection: $protocolName, options: protocols, width: 160)
            Text(protocolName == "Responses" ? "Responses 协议尚未接入，当前请求仍走 Chat Completions。" : "当前请求走 OpenAI 兼容 Chat Completions。")
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary.opacity(0.7))

            if let result = model.testResult {
                Text(result)
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(result.hasPrefix("连接成功") ? Theme.success : Color.red.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

    private var bottomBar: some View {
        HStack {
            Text(savedNote)
                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button {
                savedNote = "保存中…"
                Task {
                    let ok = await model.saveSettings()
                    savedNote = ok ? "配置已同步" : "保存失败"
                    if ok { await reloadRoutes() }
                }
            } label: {
                Text("保存并使用")
                    .font(.system(size: SettingsMetrics.labelSize, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, SettingsMetrics.pagePadding)
        .padding(.vertical, 12)
        .background(Theme.panel.opacity(0.5))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.panelBorder).frame(height: 0.8)
        }
    }

    private var providerSelection: Binding<String> {
        Binding(
            get: {
                let url = model.settings.baseURL.lowercased()
                if url.contains("deepseek") { return "DeepSeek" }
                if url.contains("xiaomimimo") { return "MiMo" }
                if url.contains("api.openai.com") { return "OpenAI" }
                if url.contains("pollinations") { return "Pollinations 测试" }
                if url.contains("your-api.example") { return "OpenAI 兼容" }
                return "自定义"
            },
            set: { value in
                switch value {
                case "DeepSeek":
                    model.settings.baseURL = "https://api.deepseek.com/v1"
                    if model.settings.model.isEmpty { model.settings.model = "deepseek-chat" }
                    if model.settings.displayName.isEmpty { model.settings.displayName = "DeepSeek" }
                case "MiMo":
                    model.settings.baseURL = "https://api.xiaomimimo.com/v1"
                    if model.settings.model.isEmpty { model.settings.model = "mimo-v2.5" }
                    if model.settings.displayName.isEmpty { model.settings.displayName = "MiMo" }
                case "OpenAI":
                    model.settings.baseURL = "https://api.openai.com/v1"
                    if model.settings.model.isEmpty { model.settings.model = "gpt-4o-mini" }
                    if model.settings.displayName.isEmpty { model.settings.displayName = "OpenAI" }
                case "OpenAI 兼容":
                    model.settings.baseURL = "https://your-api.example/v1"
                    if model.settings.displayName.isEmpty { model.settings.displayName = "OpenAI 兼容" }
                case "Pollinations 测试":
                    model.settings.baseURL = "https://text.pollinations.ai/openai"
                    model.settings.model = "openai"
                    if model.settings.displayName.isEmpty { model.settings.displayName = "Pollinations" }
                    if model.settings.apiKey.isEmpty && model.storedAPIKey.isEmpty {
                        model.settings.apiKey = "anonymous"
                    }
                default:
                    break
                }
            }
        )
    }

    private var providerLabel: String {
        if !model.settings.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            return model.settings.displayName
        }
        let url = model.settings.baseURL.lowercased()
        if url.contains("deepseek") { return "DeepSeek" }
        if url.contains("xiaomimimo") { return "MiMo" }
        if url.contains("openai.com") { return "OpenAI" }
        if url.contains("pollinations") { return "Pollinations" }
        if let host = URL(string: model.settings.baseURL)?.host, !host.isEmpty { return host }
        return "自定义"
    }

    private func darkMenu(selection: Binding<String>, options: [String], width: CGFloat) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(option) { selection.wrappedValue = option }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selection.wrappedValue)
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: SettingsMetrics.microSize))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(width: width)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: SettingsMetrics.labelSize))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }
}

// MARK: - Tools settings



private struct ModelRouteRow: View {
    let route: JSONValue
    let onSelect: (String) -> Void

    private var routeID: String { route["routeID"]?.stringValue ?? "—" }
    private var record: JSONValue? { route["record"] }
    private var title: String {
        record?["displayName"]?.stringValue
            ?? record?["model"]?.stringValue
            ?? routeID
    }
    private var subtitle: String { record?["baseURL"]?.stringValue ?? "" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: SettingsMetrics.bodySize, weight: .medium))
                Text(subtitle)
                    .font(.system(size: SettingsMetrics.cardSubtitleSize, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("选用") { onSelect(title) }
                .buttonStyle(.borderless)
                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                .foregroundStyle(Theme.accent)
        }
        .padding(10)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
    }
}

struct ToolsSettingsPane: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var source = "全部来源"
    @State private var riskFilter = "全部风险"
    @State private var expanded: Set<String> = []

    private var filtered: [AppModel.ToolSummary] {
        model.tools.filter { tool in
            if source != "全部来源", tool.sourceLabel != source { return false }
            if riskFilter != "全部风险", tool.risk.lowercased() != riskFilter.lowercased() { return false }
            if query.isEmpty { return true }
            let hay = "\(tool.name) \(tool.title) \(tool.summary) \(tool.capability) \(tool.provider)"
            return hay.localizedCaseInsensitiveContains(query)
        }
    }

    private var kernelCount: Int { model.tools.filter { $0.sourceLabel == "Kernel" }.count }
    private var mcpCount: Int { model.tools.filter { $0.sourceLabel == "MCP" }.count }

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: "工具列表", subtitle: "浏览本地服务注册的工具与能力", model: model)

            HStack(spacing: 10) {
                TextField("搜索工具名称、说明或能力", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsMetrics.bodySize))
                    .padding(8)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
                Picker("", selection: $source) {
                    Text("全部来源").tag("全部来源")
                    Text("Kernel").tag("Kernel")
                    Text("MCP").tag("MCP")
                }
                .labelsHidden()
                .frame(width: 120)
                Picker("", selection: $riskFilter) {
                    Text("全部风险").tag("全部风险")
                    Text("low").tag("low")
                    Text("medium").tag("medium")
                    Text("high").tag("high")
                }
                .labelsHidden()
                .frame(width: 110)
                Button {
                    Task { await model.loadTools() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: SettingsMetrics.captionSize))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, SettingsMetrics.pagePadding)

            Text("Kernel \(kernelCount) · MCP \(mcpCount) · 当前显示 \(filtered.count)")
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.top, 12)

            if filtered.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: SettingsMetrics.metricSize, weight: .light))
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                    Text(model.tools.isEmpty ? "暂无已注册工具" : "没有匹配的工具")
                        .font(.system(size: SettingsMetrics.bodySize, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("这里显示本地服务的注册目录与 MCP 工具。运行时按需提供的系统能力不包含在此目录中。")
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(filtered) { tool in
                            toolRow(tool)
                        }
                    }
                    .padding(.horizontal, SettingsMetrics.pagePadding)
                    .padding(.vertical, 12)
                }
            }
        }
        .task { await model.loadTools() }
    }

    @ViewBuilder
    private func toolRow(_ tool: AppModel.ToolSummary) -> some View {
        let isOpen = expanded.contains(tool.name)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(tool.risk.uppercased())
                    .font(.system(size: SettingsMetrics.microSize, weight: .semibold))
                    .foregroundStyle(riskColor(tool.risk))
                    .frame(width: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(tool.name)
                            .font(.system(size: SettingsMetrics.bodySize, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                        Text(tool.sourceLabel)
                            .font(.system(size: SettingsMetrics.microSize, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                    }
                    Text(tool.title.isEmpty ? "（无标题）" : tool.title)
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tool.name, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.borderless)
                .help("复制工具名")
                Button {
                    if isOpen { expanded.remove(tool.name) } else { expanded.insert(tool.name) }
                } label: {
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.borderless)
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    if !tool.summary.isEmpty {
                        Text(tool.summary)
                            .font(.system(size: SettingsMetrics.captionSize))
                            .foregroundStyle(Theme.textPrimary.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        metaChip("能力", tool.capability.isEmpty ? "—" : tool.capability)
                        metaChip("提供方", tool.provider.isEmpty ? "—" : tool.provider)
                        metaChip("风险", tool.risk)
                    }
                }
                .padding(.leading, 62)
            }
        }
        .padding(9)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.panelBorder, lineWidth: 0.6))
    }

    private func metaChip(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .font(.system(size: SettingsMetrics.microSize, design: .monospaced))
    }

    private func riskColor(_ risk: String) -> Color {
        switch risk.lowercased() {
        case "high": return Color.red.opacity(0.9)
        case "medium": return Color.orange.opacity(0.9)
        default: return Theme.textSecondary
        }
    }
}


struct SkillsSettingsPane: View {
    @ObservedObject var model: AppModel
    @State private var skills: [BuiltinSkill] = []
    @State private var query = ""
    @State private var selected: BuiltinSkill?

    private var filtered: [BuiltinSkill] {
        guard !query.isEmpty else { return skills }
        return skills.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: "Skill 列表", subtitle: "内置技能包（Japlos SoT），可在 Application Support 覆盖", model: model)

            HStack(spacing: 10) {
                TextField("搜索技能名称或说明", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsMetrics.bodySize))
                    .padding(8)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
                Button {
                    reload()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: SettingsMetrics.captionSize))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
                Button {
                    NSWorkspace.shared.open(BuiltinSkillCatalog.supportSkillsRoot())
                } label: {
                    Label("打开目录", systemImage: "folder")
                        .font(.system(size: SettingsMetrics.captionSize))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, SettingsMetrics.pagePadding)

            Text("已装技能 · \(filtered.count) 个")
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.top, 12)

            if filtered.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: SettingsMetrics.metricSize, weight: .light))
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                    Text(skills.isEmpty ? "暂无技能包" : "没有匹配的技能")
                        .font(.system(size: SettingsMetrics.bodySize, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("启动 lucasd 后会把内置 BuiltinSkills 种子拷到 ~/Library/Application Support/Lucas/BuiltinSkills。")
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                Spacer()
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(filtered) { skill in
                                Button {
                                    selected = skill
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "sparkles.rectangle.stack")
                                            .font(.system(size: SettingsMetrics.cardSubtitleSize))
                                            .foregroundStyle(Theme.accent)
                                            .frame(width: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(skill.name)
                                                .font(.system(size: SettingsMetrics.bodySize, weight: .medium, design: .monospaced))
                                                .foregroundStyle(Theme.textPrimary)
                                            Text(skill.summaryLine)
                                                .font(.system(size: SettingsMetrics.captionSize))
                                                .foregroundStyle(Theme.textSecondary)
                                                .lineLimit(2)
                                        }
                                        Spacer()
                                        Text(skill.source)
                                            .font(.system(size: SettingsMetrics.microSize))
                                            .foregroundStyle(Theme.textSecondary.opacity(0.8))
                                    }
                                    .padding(9)
                                    .background(
                                        (selected?.name == skill.name ? Theme.accent.opacity(0.10) : Color.white.opacity(0.025)),
                                        in: RoundedRectangle(cornerRadius: 7)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7)
                                            .strokeBorder(
                                                selected?.name == skill.name ? Theme.accent.opacity(0.5) : Theme.panelBorder,
                                                lineWidth: 0.6
                                            )
                                    )
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.horizontal, SettingsMetrics.pagePadding)
                        .padding(.vertical, 12)
                    }
                    .frame(maxWidth: selected == nil ? .infinity : 380)

                    if let selected {
                        Divider()
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(selected.name)
                                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(selected.description)
                                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                                    .foregroundStyle(Theme.textSecondary)
                                Text(selected.directory.path)
                                    .font(.system(size: SettingsMetrics.microSize, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                                    .textSelection(.enabled)
                                Divider()
                                Text(selected.body)
                                    .font(.system(size: SettingsMetrics.bodySize))
                                    .foregroundStyle(Theme.textPrimary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(SettingsMetrics.pagePadding)
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        var extras: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("BuiltinSkills", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            extras.append(bundled)
        }
        skills = BuiltinSkillCatalog.load(additionalRoots: extras)
        if let selected, let match = skills.first(where: { $0.name == selected.name }) {
            self.selected = match
        } else {
            self.selected = skills.first
        }
    }
}


// MARK: - Placeholder

struct PlaceholderPane: View {
    let section: SettingsSection
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: section.rawValue, subtitle: "该模块尚未实现", model: model)
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: SettingsMetrics.metricSize, weight: .light))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                Text("开发中")
                    .font(.system(size: SettingsMetrics.bodySize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("这一页会在后续版本接入，当前可以继续使用主界面与模型设置。")
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
    }
}


// MARK: - Channels (微信 / 飞书)

struct ChannelsSettingsPane: View {
    @ObservedObject var model: AppModel
    @State private var feishuAppID = ""
    @State private var feishuAppSecret = ""
    @State private var feishuVerificationToken = ""
    @State private var busy = false
    @State private var banner: String?

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(
                title: "通道",
                subtitle: "微信 ClawBot（扫码）与飞书 Open API。无密钥时不会伪造已连接。",
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
                .buttonStyle(.borderless)
            }

            Text("官方 ClawBot / iLink（ilinkai.weixin.qq.com）。不需要 AppID。真实扫码连通需老板现场扫码验证。")
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
                .buttonStyle(.borderless)
                .disabled(busy)
            }

            Text("凭据写入 SecretStore 与 feishu/credentials/auth.sqlite，界面与状态接口不回显密钥。")
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
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

struct UpdatesSettingsPane: View {
    @ObservedObject var updates: UpdateService
    @ObservedObject var model: AppModel

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: "在线更新", subtitle: "查看当前版本、检查更新与了解新版功能", model: model)

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    currentCard
                    if let latest = updates.latestVersion {
                        latestCard(latest)
                    }
                    automaticCard
#if DEBUG
                    storeHealthCard
#endif
                }
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.bottom, 24)
            }
        }
        .task {
            updates.refresh()
            await updates.refreshFeed()
#if DEBUG
            await model.loadStoreStats()
#endif
        }
    }

    private var currentCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.textSecondary)
                Text("当前版本")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(updates.version)
                    .font(.system(size: SettingsMetrics.metricSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }

            Rectangle()
                .fill(Theme.panelBorder)
                .frame(height: 0.8)

            HStack(spacing: 12) {
                statusLabel
                Spacer()
                Button {
                    updates.checkForUpdates()
                    Task { await updates.refreshFeed() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: SettingsMetrics.microSize))
                        Text("检查更新")
                            .font(.system(size: SettingsMetrics.bodySize, weight: .medium))
                    }
                    .foregroundStyle(updates.updateAvailable ? Color.black.opacity(0.88) : Theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(updates.updateAvailable ? Theme.accent : Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(!updates.isAvailable)
                .opacity(updates.isAvailable ? 1 : 0.45)
            }

            Text("上次检查：\(lastCheckText)")
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if !updates.isAvailable {
            Text(updates.unavailableReason)
                .font(.system(size: SettingsMetrics.bodySize))
                .foregroundStyle(Theme.textSecondary)
        } else if updates.updateAvailable, let latest = updates.latestVersion {
            Label("发现新版本 \(latest)", systemImage: "arrow.down.circle.fill")
                .font(.system(size: SettingsMetrics.bodySize))
                .foregroundStyle(Theme.accent)
        } else if updates.isCheckingFeed {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("正在检查…")
                    .font(.system(size: SettingsMetrics.bodySize))
                    .foregroundStyle(Theme.textSecondary)
            }
        } else {
            Label("当前已是最新版本", systemImage: "checkmark.circle.fill")
                .font(.system(size: SettingsMetrics.bodySize))
                .foregroundStyle(Theme.success)
        }
    }

    private func latestCard(_ latest: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("最新版本 \(latest)")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if updates.updateAvailable {
                    Label("可更新", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.accent)
                }
            }

            Text("新版功能与改进")
                .font(.system(size: SettingsMetrics.labelSize, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            Text(updates.releaseNotes ?? "此版本暂未提供更新说明。")
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

    private var automaticCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.textSecondary)
                Text("自动更新")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("启动后定期检查新版本")
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.textSecondary)
            }

            Toggle(isOn: Binding(
                get: { updates.automaticallyChecks },
                set: { updates.setAutomaticallyChecks($0) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("自动检查更新")
                        .font(.system(size: SettingsMetrics.bodySize))
                        .foregroundStyle(Theme.textPrimary)
                    Text("发现新版本时会提示，确认后下载并安装。")
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!updates.isAvailable)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

#if DEBUG
    private var storeHealthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive")
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.textSecondary)
                Text("内核存储 / 自愈")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(model.storeTableCounts.count) 张表")
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
            }

            if let event = model.lastSelfHealingEvent {
                Text("最近事件：\(event.kind) · \(Self.dateFormatter.string(from: event.createdAt))")
                    .font(.system(size: SettingsMetrics.bodySize))
                    .foregroundStyle(Theme.textPrimary)
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            } else {
                Text("尚无自愈事件（daemon 启动后会出现 boot）")
                    .font(.system(size: SettingsMetrics.bodySize))
                    .foregroundStyle(Theme.textSecondary)
            }

            if !model.storeTableCounts.isEmpty {
                let nonempty = model.storeTableCounts.filter { $0.count > 0 }
                let preview = nonempty.prefix(8)
                Text(preview.map { "\($0.name)=\($0.count)" }.joined(separator: " · "))
                    .font(.system(size: SettingsMetrics.microSize, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if nonempty.count > preview.count {
                    Text("另有 \(nonempty.count - preview.count) 张非空表…")
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Button {
                Task { await model.loadStoreStats() }
            } label: {
                Label("刷新统计", systemImage: "arrow.clockwise")
                    .font(.system(size: SettingsMetrics.bodySize))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

#endif

    private var lastCheckText: String {
        guard let date = updates.lastCheck else { return "尚未检查" }
        return Self.dateFormatter.string(from: date)
    }
}

// MARK: - Voice settings

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
            if voice.provider == .volcengine {
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
                    .buttonStyle(.borderless)
                }
                Text(voice.volcengineConfigured
                     ? "已配置火山凭证；未填完整或合成失败时仍用系统语音。"
                     : "未配置时仍用系统语音。凭证经 SecretStore 保存，不会写入 SQLite。")
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
                    .buttonStyle(.borderless)

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
                    .buttonStyle(.borderless)
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.accent)
                    if voice.isSpeaking {
                        Button("停止播报") { voice.stop() }
                            .buttonStyle(.borderless)
                            .font(.system(size: SettingsMetrics.cardSubtitleSize))
                            .foregroundStyle(Color.red.opacity(0.85))
                    }
                }
            }
            Text("改动会同步到 speech_profiles；火山凭证走 SecretStore。未配置或失败时自动回退系统语音。")
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


// MARK: - Alarms settings

struct AlarmsSettingsPane: View {
    @ObservedObject var model: AppModel
    @State private var title = ""
    @State private var fireAt = Date().addingTimeInterval(3600)

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: "提醒", subtitle: "本地闹钟列表（轻量端口，不含系统通知投递）", model: model)

            ScrollView {
                HStack(alignment: .top, spacing: SettingsMetrics.cardSpacing) {
                    // Left: create — compact date + time fields (popover calendar, no analog clock).
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "bell")
                                .font(.system(size: SettingsMetrics.bodySize))
                                .foregroundStyle(Theme.textSecondary)
                            Text("新建提醒")
                                .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        HStack(spacing: 12) {
                            TextField("标题", text: $title)
                                .textFieldStyle(.plain)
                                .font(.system(size: SettingsMetrics.bodySize))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
                                .frame(maxWidth: .infinity)
                            Button("添加") {
                                Task {
                                    await model.upsertAlarm(title: title, fireAt: fireAt)
                                    title = ""
                                    fireAt = Date().addingTimeInterval(3600)
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: SettingsMetrics.cardSubtitleSize))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Text("日期")
                                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 36, alignment: .leading)
                                DatePicker("", selection: $fireAt, displayedComponents: [.date])
                                    .datePickerStyle(.compact)
                                    .labelsHidden()
                                    .environment(\.locale, Locale.current)
                                Spacer(minLength: 0)
                            }
                            HStack(spacing: 10) {
                                Text("时间")
                                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 36, alignment: .leading)
                                DatePicker("", selection: $fireAt, displayedComponents: [.hourAndMinute])
                                    .datePickerStyle(.compact)
                                    .labelsHidden()
                                    .environment(\.locale, Locale.current)
                                Spacer(minLength: 0)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                    .panel(padding: SettingsMetrics.cardPadding)

                    // Right: saved list — equal width with create card.
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("已保存")
                                .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("\(model.alarms.count)")
                                .font(.system(size: SettingsMetrics.captionSize, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        if model.alarms.isEmpty {
                            Text("暂无提醒。")
                                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer(minLength: 0)
                        } else {
                            ForEach(model.alarms) { alarm in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(alarm.title)
                                            .font(.system(size: SettingsMetrics.labelSize))
                                            .foregroundStyle(Theme.textPrimary)
                                        Text(alarm.fireAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.system(size: SettingsMetrics.captionSize))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                    Spacer()
                                    Text(alarm.enabled ? "开" : "关")
                                        .font(.system(size: SettingsMetrics.captionSize))
                                        .foregroundStyle(Theme.textSecondary)
                                    Button {
                                        Task { await model.deleteAlarm(id: alarm.id) }
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: SettingsMetrics.captionSize))
                                            .foregroundStyle(Color.red.opacity(0.8))
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.vertical, 4)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                    .panel(padding: SettingsMetrics.cardPadding)
                }
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.bottom, 24)
            }
        }
        .task { await model.loadAlarms() }
    }
}

// MARK: - MCP settings

struct MCPServerDraft: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var command: String
    var args: [String]
    var enabled: Bool
    var url: String?
    var oauthClientID: String
    var oauthToken: String
    var oauthAuthURL: String

    private enum CodingKeys: String, CodingKey {
        case id, name, command, args, enabled, url
        case oauthClientID, oauthToken, oauthAuthURL
    }

    init(
        id: String,
        name: String,
        command: String,
        args: [String],
        enabled: Bool,
        url: String?,
        oauthClientID: String = "",
        oauthToken: String = "",
        oauthAuthURL: String = ""
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.enabled = enabled
        self.url = url
        self.oauthClientID = oauthClientID
        self.oauthToken = oauthToken
        self.oauthAuthURL = oauthAuthURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        url = try container.decodeIfPresent(String.self, forKey: .url)
        oauthClientID = try container.decodeIfPresent(String.self, forKey: .oauthClientID) ?? ""
        oauthToken = try container.decodeIfPresent(String.self, forKey: .oauthToken) ?? ""
        oauthAuthURL = try container.decodeIfPresent(String.self, forKey: .oauthAuthURL) ?? ""
    }

    var isHTTP: Bool {
        if let url, !url.isEmpty { return true }
        return false
    }
}

struct MCPSettingsPane: View {
    @ObservedObject var model: AppModel
    @State private var servers: [MCPServerDraft] = []
    @State private var statuses: [String: (state: String, tools: Int)] = [:]
    @State private var name = ""
    @State private var url = ""
    @State private var command = "python3"
    @State private var arguments = ""
    @State private var oauthClientID = ""
    @State private var oauthToken = ""
    @State private var oauthAuthURL = ""
    @State private var busy = false
    @State private var message: String?
    @State private var expandedServerID: String?

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: "MCP 服务", subtitle: "stdio / HTTP MCP；预设可一键加入，刷新后并进对话工具", model: model)

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    addCard
                    listCard
                    eventsCard
                }
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.bottom, 20)
            }
        }
        .task {
            await reload()
            await model.loadMCPEvents()
        }
    }

    private var eventsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近事件")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("只读")
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    Task { await model.loadMCPEvents() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: SettingsMetrics.cardSubtitleSize))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
            }

            if model.mcpEvents.isEmpty {
                Text("暂无 mcp.events 记录")
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.mcpEvents.prefix(10))) { event in
                        HStack(spacing: 8) {
                            Text(event.serverID.isEmpty ? "—" : event.serverID)
                                .font(.system(size: SettingsMetrics.captionSize, design: .monospaced))
                                .foregroundStyle(Theme.accent.opacity(0.9))
                                .frame(width: 100, alignment: .leading)
                                .lineLimit(1)
                            Text(event.event)
                                .font(.system(size: SettingsMetrics.captionSize))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(Self.shortTime(event.createdAt))
                                .font(.system(size: SettingsMetrics.microSize, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 16)
    }

    private static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加服务")
                .font(.system(size: SettingsMetrics.bodySize, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: 8) {
                Text("预设")
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
                Button("Echo (stdio)") {
                    applyPresetEcho()
                }
                .buttonStyle(.borderless)
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.accent)
                Button("HTTP 示例") {
                    applyPresetHTTP()
                }
                .buttonStyle(.borderless)
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.accent)
            }

            HStack(spacing: 10) {
                TextField("名称", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsMetrics.bodySize))
                    .padding(7)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .frame(width: 110)
                TextField("HTTP URL（可选，填了就忽略命令）", text: $url)
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsMetrics.bodySize, design: .monospaced))
                    .padding(7)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .frame(width: 260)
                TextField("参数（空格分隔）", text: $arguments)
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsMetrics.bodySize, design: .monospaced))
                    .padding(7)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                Button {
                    Task { await addServer() }
                } label: {
                    Text("添加")
                        .font(.system(size: SettingsMetrics.cardSubtitleSize))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.borderless)
                .disabled(busy || name.isEmpty || (url.isEmpty && command.isEmpty))
            }

            HStack(spacing: 10) {
                TextField("stdio 命令（HTTP 模式留空）", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsMetrics.bodySize, design: .monospaced))
                    .padding(7)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .frame(width: 240)
                Spacer()
            }

            if !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("HTTP OAuth（可选）")
                        .font(.system(size: SettingsMetrics.captionSize, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 10) {
                        TextField("Client ID", text: $oauthClientID)
                            .textFieldStyle(.plain)
                            .font(.system(size: SettingsMetrics.bodySize))
                            .padding(7)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                            .frame(width: 160)
                        TextField("授权页 URL", text: $oauthAuthURL)
                            .textFieldStyle(.plain)
                            .font(.system(size: SettingsMetrics.bodySize, design: .monospaced))
                            .padding(7)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        Button("打开授权页") {
                            openAuthURL(oauthAuthURL)
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.accent)
                        .disabled(oauthAuthURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    SecureField("Access Token", text: $oauthToken)
                        .textFieldStyle(.plain)
                        .font(.system(size: SettingsMetrics.bodySize, design: .monospaced))
                        .padding(7)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            if let message {
                Text(message)
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 16)
    }

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已配置服务")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(servers.count)")
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: SettingsMetrics.cardSubtitleSize))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
            }

            if servers.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.panelBorder, style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                    .frame(height: 120)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "globe.asia.australia")
                                .font(.system(size: SettingsMetrics.metricSize, weight: .light))
                                .foregroundStyle(Theme.textSecondary.opacity(0.7))
                            Text("还没有配置 MCP 服务")
                                .font(.system(size: SettingsMetrics.labelSize))
                                .foregroundStyle(Theme.textPrimary)
                            Text("填入命令和参数，例如 python3 /path/to/server.py")
                                .font(.system(size: SettingsMetrics.captionSize))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
            } else {
                VStack(spacing: 8) {
                    ForEach(servers) { server in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(statusColor(server.id))
                                    .frame(width: 6, height: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name)
                                        .font(.system(size: SettingsMetrics.labelSize, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(serverSubtitle(server))
                                        .font(.system(size: SettingsMetrics.captionSize, design: .monospaced))
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Toggle("", isOn: bindingEnabled(for: server))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .tint(Theme.accent)
                                    .controlSize(.mini)
                                Text(statusLabel(server.id))
                                    .font(.system(size: SettingsMetrics.captionSize))
                                    .foregroundStyle(Theme.textSecondary)
                                if server.isHTTP {
                                    Button {
                                        withAnimation {
                                            expandedServerID = expandedServerID == server.id ? nil : server.id
                                        }
                                    } label: {
                                        Image(systemName: "key")
                                            .font(.system(size: SettingsMetrics.captionSize))
                                            .foregroundStyle(Theme.accent)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("OAuth")
                                }
                                Button {
                                    Task { await reconnect(server) }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: SettingsMetrics.captionSize))
                                        .foregroundStyle(Theme.accent)
                                }
                                .buttonStyle(.borderless)
                                .help("重新连接")
                                Button {
                                    Task { await removeServer(server) }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: SettingsMetrics.captionSize))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                .buttonStyle(.borderless)
                            }

                            if server.isHTTP, expandedServerID == server.id {
                                oauthEditor(for: server)
                            }
                        }
                        .padding(9)
                        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.panelBorder, lineWidth: 0.6))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 16)
    }

    private func statusColor(_ id: String) -> Color {
        switch statuses[id]?.state {
        case "ready": return Theme.success
        case "error": return Color.red.opacity(0.85)
        default: return Theme.textSecondary.opacity(0.5)
        }
    }

    private func statusLabel(_ id: String) -> String {
        guard let status = statuses[id] else { return "未启动" }
        if status.state == "ready" { return "\(status.tools) 个工具" }
        return "连接失败"
    }

    private func serverSubtitle(_ server: MCPServerDraft) -> String {
        if let url = server.url, !url.isEmpty {
            return "HTTP · \(url)"
        }
        return ([server.command] + server.args).joined(separator: " ")
    }

    private func applyPresetEcho() {
        let candidates = [
            "/Users/w/Desktop/japlosv2/clone/scripts/mcp_echo_server.py",
            FileManager.default.currentDirectoryPath + "/scripts/mcp_echo_server.py",
        ]
        let script = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
        name = "echo"
        url = ""
        command = "python3"
        arguments = script
        message = "已填入 Echo 预设，点添加后生效"
    }

    private func applyPresetHTTP() {
        name = "http-echo"
        url = "http://127.0.0.1:8765/mcp"
        command = ""
        arguments = ""
        message = "已填入 HTTP 示例；请先本地跑起 mcp_http_server.py 再添加"
    }

    private func openAuthURL(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), !trimmed.isEmpty else { return }
        NSWorkspace.shared.open(url)
    }

    @ViewBuilder
    private func oauthEditor(for server: MCPServerDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OAuth")
                .font(.system(size: SettingsMetrics.captionSize, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                TextField("Client ID", text: bindingOAuth(server.id, keyPath: \.oauthClientID))
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsMetrics.bodySize))
                    .padding(6)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                TextField("授权页 URL", text: bindingOAuth(server.id, keyPath: \.oauthAuthURL))
                    .textFieldStyle(.plain)
                    .font(.system(size: SettingsMetrics.bodySize, design: .monospaced))
                    .padding(6)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                Button("打开授权页") {
                    if let idx = servers.firstIndex(where: { $0.id == server.id }) {
                        openAuthURL(servers[idx].oauthAuthURL)
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.accent)
            }
            SecureField("Access Token", text: bindingOAuth(server.id, keyPath: \.oauthToken))
                .textFieldStyle(.plain)
                .font(.system(size: SettingsMetrics.bodySize, design: .monospaced))
                .padding(6)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
            Button("保存 OAuth") {
                Task { await persist() }
            }
            .buttonStyle(.borderless)
            .font(.system(size: SettingsMetrics.captionSize))
            .foregroundStyle(Theme.accent)
        }
        .padding(.top, 2)
    }

    private func bindingOAuth(_ id: String, keyPath: WritableKeyPath<MCPServerDraft, String>) -> Binding<String> {
        Binding(
            get: { servers.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: { value in
                if let idx = servers.firstIndex(where: { $0.id == id }) {
                    servers[idx][keyPath: keyPath] = value
                }
            }
        )
    }

    private func bindingEnabled(for server: MCPServerDraft) -> Binding<Bool> {
        Binding(
            get: { servers.first(where: { $0.id == server.id })?.enabled ?? true },
            set: { value in
                if let idx = servers.firstIndex(where: { $0.id == server.id }) {
                    servers[idx].enabled = value
                    Task { await persist() }
                }
            }
        )
    }

    private func reconnect(_ server: MCPServerDraft) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await model.client.callAsync(.mcpRefresh, arguments: .object([:]), timeout: 60)
            await reload()
            message = "已刷新 \(server.name)"
        } catch {
            message = (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    private func reload() async {
        do {
            let list = try await model.client.callAsync(.configurationList, arguments: .object([:]))
            if let entry = list.arrayValue?.first(where: { $0["path"]?.stringValue == "mcp.servers" }),
               let value = entry["value"],
               let data = try? ProtocolCoding.encode(value) {
                servers = (try? ProtocolCoding.decode([MCPServerDraft].self, from: data)) ?? []
            }
            let status = try await model.client.callAsync(.mcpStatus, arguments: .object([:]))
            var map: [String: (String, Int)] = [:]
            for item in status["servers"]?.arrayValue ?? [] {
                guard let id = item["id"]?.stringValue else { continue }
                map[id] = (
                    item["state"]?.stringValue ?? "unknown",
                    item["toolCount"]?.intValue ?? 0
                )
            }
            statuses = map
            await model.loadMCPEvents()
        } catch {
            message = (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    private func addServer() async {
        busy = true
        defer { busy = false }
        let isHTTP = !url.trimmingCharacters(in: .whitespaces).isEmpty
        let draft = MCPServerDraft(
            id: "srv-\(UUID().uuidString.prefix(8).lowercased())",
            name: name.isEmpty ? (isHTTP ? url : command) : name,
            command: isHTTP ? "" : command,
            args: isHTTP ? [] : arguments.split(separator: " ").map(String.init),
            enabled: true,
            url: isHTTP ? url.trimmingCharacters(in: .whitespaces) : nil,
            oauthClientID: isHTTP ? oauthClientID : "",
            oauthToken: isHTTP ? oauthToken : "",
            oauthAuthURL: isHTTP ? oauthAuthURL : ""
        )
        servers.append(draft)
        await persist()
        name = ""
        arguments = ""
        url = ""
        oauthClientID = ""
        oauthToken = ""
        oauthAuthURL = ""
    }

    private func removeServer(_ server: MCPServerDraft) async {
        servers.removeAll { $0.id == server.id }
        await persist()
    }

    private func persist() async {
        do {
            let value = try ProtocolCoding.decode(
                JSONValue.self,
                from: ProtocolCoding.encode(servers)
            )
            _ = try await model.client.callAsync(.configurationSet, arguments: .object([
                "path": .string("mcp.servers"),
                "value": value,
            ]))
            _ = try await model.client.callAsync(.mcpRefresh, arguments: .object([:]), timeout: 60)
            await reload()
        } catch {
            message = (error as? ClientError)?.description ?? String(describing: error)
        }
    }
}
