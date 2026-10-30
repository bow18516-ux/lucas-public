import AppKit
import SwiftUI
import UniformTypeIdentifiers
import JaplosProtocol
import JaplosClient

/// One typographic + spacing scale for every settings page.
enum SettingsMetrics {
    /// Page chrome title in the detail pane (e.g. 「Skill 列表」).
    static let pageTitleSize: CGFloat = 26
    static let pageSubtitleSize: CGFloat = 14
    /// Top-level sidebar group label (e.g. 「设置」).
    static let navSize: CGFloat = 15
    static let navIconSize: CGFloat = 16
    /// Nested sidebar items under a top-level group (one point below former flat nav = 15).
    static let navItemSize: CGFloat = 14
    static let navItemIconSize: CGFloat = 14
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
    /// Shared top inset for the whole settings chrome (left nav + right header) so both
    /// columns sit on the same horizontal line under the transparent titlebar.
    /// Kept tight (was ~54/60) so the layout is not top-heavy.
    static let chromeTopPadding: CGFloat = 36
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

/// Knowledge library filters (used inside the 知识库 pane; deep-linkable via LUCAS_SETTINGS_SECTION).
enum KnowledgeNav: String, CaseIterable, Identifiable {
    case company = "公司资料"
    case client = "客户与往来"
    case all = "全部文件"

    var id: String { rawValue }

    var libraryID: String {
        switch self {
        case .company: return "company"
        case .client: return "client"
        case .all: return "all"
        }
    }

    var icon: String {
        switch self {
        case .company: return "building.2"
        case .client: return "person.2"
        case .all: return "doc.text"
        }
    }

    var subtitle: String {
        switch self {
        case .company: return "公司介绍、产品、SOP 等必读材料"
        case .client: return "客户资料与往来邮件/聊天记录"
        case .all: return "全部知识文件；可用类型标签筛选"
        }
    }
}


struct SettingsScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: SpeechOutput
    /// Sidebar destination under the single L1 「设置」 group (settings panes + 记忆 + 知识库).
    private enum SidebarDestination: Equatable {
        case settings(SettingsSection)
        case memory
        case knowledge(KnowledgeNav)
    }

    @State private var destination: SidebarDestination
    /// Top-level 「设置」 group — default expanded so panes (incl. 记忆/知识库) stay one click away.
    @State private var settingsGroupExpanded = true
    @ObservedObject private var updateService = UpdateService.shared

    init(model: AppModel, voice: SpeechOutput) {
        self.model = model
        self.voice = voice
        let requested = ProcessInfo.processInfo.environment["LUCAS_SETTINGS_SECTION"] ?? ""
        let lower = requested.lowercased()
        if requested == "记忆" || lower == "memory" {
            _destination = State(initialValue: .memory)
        } else if requested == "知识库" || lower == "knowledge" || requested == "全部文件" || requested == "全部文档" {
            _destination = State(initialValue: .knowledge(.all))
        } else if requested == "公司资料" || lower == "company" {
            _destination = State(initialValue: .knowledge(.company))
        } else if requested == "客户与往来" || lower == "client" {
            _destination = State(initialValue: .knowledge(.client))
        } else if let kn = KnowledgeNav.allCases.first(where: { $0.rawValue == requested }) {
            _destination = State(initialValue: .knowledge(kn))
        } else {
            let section = SettingsSection.allCases.first { $0.rawValue == requested } ?? .model
            _destination = State(initialValue: .settings(section))
        }
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
            VStack(alignment: .leading, spacing: 4) {
                // Top-level group: 「设置」
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        settingsGroupExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: settingsGroupExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 12)
                        Image(systemName: "gearshape")
                            .font(.system(size: SettingsMetrics.navIconSize))
                            .frame(width: 22)
                        Text("设置")
                            .font(.system(size: SettingsMetrics.navSize, weight: .semibold))
                        Spacer()
                        if !settingsGroupExpanded && updateService.updateAvailable {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.pressable)

                if settingsGroupExpanded {
                    VStack(spacing: 2) {
                        ForEach(SettingsSection.allCases) { item in
                            let selected: Bool = {
                                if case .settings(let section) = destination { return section == item }
                                return false
                            }()
                            Button {
                                destination = .settings(item)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: item.icon)
                                        .font(.system(size: SettingsMetrics.navItemIconSize))
                                        .frame(width: 20)
                                    Text(item.rawValue)
                                        .font(.system(size: SettingsMetrics.navItemSize))
                                    Spacer()
                                    if selected {
                                        Circle()
                                            .fill(Theme.accent)
                                            .frame(width: 4, height: 4)
                                    } else if item == .updates && updateService.updateAvailable {
                                        Circle()
                                            .fill(Theme.accent)
                                            .frame(width: 6, height: 6)
                                    }
                                }
                                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                                .padding(.leading, 28)
                                .padding(.trailing, 12)
                                .padding(.vertical, 9)
                                .background(
                                    selected ? Theme.accent.opacity(0.10) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                                .overlay(alignment: .leading) {
                                    if selected {
                                        Rectangle()
                                            .fill(Theme.accent)
                                            .frame(width: 2)
                                            .padding(.vertical, 6)
                                            .padding(.leading, 16)
                                    }
                                }
                            }
                            .buttonStyle(.pressable)
                        }

                        // L2 under 「设置」: 记忆 / 知识库 (no longer peer L1 groups)
                        sidebarNavItem(
                            title: "记忆",
                            icon: "brain.head.profile",
                            selected: destination == .memory
                        ) {
                            destination = .memory
                        }

                        sidebarNavItem(
                            title: "知识库",
                            icon: "books.vertical",
                            selected: {
                                if case .knowledge = destination { return true }
                                return false
                            }()
                        ) {
                            destination = .knowledge(.all)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, SettingsMetrics.chromeTopPadding)

            Spacer(minLength: 12)

            // Bottom-left: LUCAS identity card + 「返回主界面」 button card stacked under it.
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LUCAS")
                        .font(.system(size: SettingsMetrics.cardSubtitleSize, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(Theme.textPrimary.opacity(0.85))
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.panelBorder, lineWidth: 0.8)
                )

                Button {
                    model.settingsPresented = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: SettingsMetrics.labelSize, weight: .medium))
                        Text("返回主界面")
                            .font(.system(size: SettingsMetrics.bodySize, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 0.8)
                    )
                }
                .buttonStyle(.pressable)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel.opacity(0.35))
    }

    private func sidebarNavItem(
        title: String,
        icon: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: SettingsMetrics.navItemIconSize))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: SettingsMetrics.navItemSize))
                Spacer()
                if selected {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 4, height: 4)
                }
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.leading, 28)
            .padding(.trailing, 12)
            .padding(.vertical, 9)
            .background(
                selected ? Theme.accent.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 2)
                        .padding(.vertical, 6)
                        .padding(.leading, 16)
                }
            }
        }
        .buttonStyle(.pressable)
    }

    @ViewBuilder
    private var content: some View {
        switch destination {
        case .memory:
            MemorySettingsPane(model: model)
        case .knowledge(let kind):
            KnowledgeLibraryPane(nav: kind, model: model)
        case .settings(.model):
            ModelSettingsPane(model: model)
        case .settings(.tools):
            ToolsSettingsPane(model: model)
        case .settings(.skills):
            SkillsSettingsPane(model: model)
        case .settings(.voice):
            VoiceSettingsPane(model: model, voice: voice)
        case .settings(.alarms):
            AlarmsSettingsPane(model: model)
        case .settings(.channels):
            ChannelsSettingsPane(model: model)
        case .settings(.mcp):
            MCPSettingsPane(model: model)
        case .settings(.updates):
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
                    .buttonStyle(.pressable)
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(subtitle)
                .font(.system(size: SettingsMetrics.bodySize))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, SettingsMetrics.pagePadding)
        .padding(.top, SettingsMetrics.chromeTopPadding)
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
                .buttonStyle(.pressable)
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
            .buttonStyle(.pressable)
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
                    .buttonStyle(.pressable)
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.accent)
                Button {
                    Task { await model.loadTools() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: SettingsMetrics.cardSubtitleSize))
                }
                .buttonStyle(.pressable)
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
                        .buttonStyle(.pressable)
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
                    .buttonStyle(.pressable)
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
            .buttonStyle(.pressable)
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
                .buttonStyle(.pressable)
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
                .buttonStyle(.pressable)
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
                .buttonStyle(.pressable)
                .help("复制工具名")
                Button {
                    if isOpen { expanded.remove(tool.name) } else { expanded.insert(tool.name) }
                } label: {
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.pressable)
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
                .buttonStyle(.pressable)
                .foregroundStyle(Theme.accent)
                Button {
                    NSWorkspace.shared.open(BuiltinSkillCatalog.supportSkillsRoot())
                } label: {
                    Label("打开目录", systemImage: "folder")
                        .font(.system(size: SettingsMetrics.captionSize))
                }
                .buttonStyle(.pressable)
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
                                .buttonStyle(.pressable)
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
            .buttonStyle(.pressable)
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
                    .buttonStyle(.pressable)
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



// MARK: - Memory / knowledge backup

struct MemoryKnowledgeBackupCard: View {
    @ObservedObject var model: AppModel
    var scopeLabel: String = "记忆 + 知识库"
    @State private var note: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "externaldrive.badge.timemachine")
                    .font(.system(size: SettingsMetrics.bodySize))
                    .foregroundStyle(Theme.textSecondary)
                Text("备份")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(scopeLabel)
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
            }

            Text("导出到本机指定文件夹，或从备份目录导入。包含记忆、知识库文档正文，以及 KnowledgeFiles 原件副本；按 id 合并，可往返。")
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    exportBackup()
                } label: {
                    Text(busy ? "处理中…" : "导出到文件夹…")
                        .font(.system(size: SettingsMetrics.cardSubtitleSize))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.pressable)
                .disabled(busy)

                Button {
                    importBackup()
                } label: {
                    Text("从备份导入…")
                        .font(.system(size: SettingsMetrics.cardSubtitleSize))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
                }
                .buttonStyle(.pressable)
                .disabled(busy)
            }

            if let note {
                Text(note)
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

    private func exportBackup() {
        guard let folder = MemoryKnowledgeBackup.pickExportFolder() else { return }
        busy = true
        note = "正在导出…"
        Task {
            let result = await model.exportMemoryKnowledgeBackup(toParent: folder)
            note = result
            busy = false
        }
    }

    private func importBackup() {
        guard let folder = MemoryKnowledgeBackup.pickImportFolder() else { return }
        busy = true
        note = "正在导入…"
        Task {
            let result = await model.importMemoryKnowledgeBackup(from: folder)
            note = result
            busy = false
        }
    }
}

// MARK: - Alarms settings

struct MemorySettingsPane: View {
    @ObservedObject var model: AppModel
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(
                title: "记忆",
                subtitle: "持久化短笔记（memory.list / upsert / delete），与会话聊天分开存放",
                model: model
            )

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: SettingsMetrics.bodySize))
                                .foregroundStyle(Theme.textSecondary)
                            Text("记一条")
                                .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("\(model.memoryNotes.count) 条")
                                .font(.system(size: SettingsMetrics.captionSize, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                        }

                        HStack(spacing: 10) {
                            TextField("写下要长期记住的内容…", text: $draft, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: SettingsMetrics.bodySize))
                                .lineLimit(2...4)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
                            Button("保存") {
                                let text = draft
                                draft = ""
                                Task {
                                    await model.rememberNote(text, reloadScopedToCurrentSession: false)
                                }
                            }
                            .buttonStyle(.pressable)
                            .font(.system(size: SettingsMetrics.cardSubtitleSize))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        Button("记上条用户发言") {
                            Task {
                                await model.rememberLatestUserMessage()
                                await model.loadMemories(scopedToCurrentSession: false)
                            }
                        }
                        .buttonStyle(.pressable)
                        .font(.system(size: SettingsMetrics.cardSubtitleSize))
                        .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .panel(padding: SettingsMetrics.cardPadding)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("已保存")
                            .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)

                        if model.memoryNotes.isEmpty {
                            Text("暂无持久化记忆。在上方写入后点「保存」。")
                                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            ForEach(model.memoryNotes) { note in
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(note.content)
                                            .font(.system(size: SettingsMetrics.labelSize))
                                            .foregroundStyle(Theme.textPrimary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        HStack(spacing: 8) {
                                            Text(note.kind)
                                                .font(.system(size: SettingsMetrics.captionSize))
                                                .foregroundStyle(Theme.textSecondary)
                                            if !note.sessionID.isEmpty {
                                                Text("会话 \(note.sessionID.prefix(8))")
                                                    .font(.system(size: SettingsMetrics.captionSize, design: .monospaced))
                                                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                                            }
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Button {
                                        Task {
                                            await model.deleteMemory(id: note.id, reloadScopedToCurrentSession: false)
                                        }
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: SettingsMetrics.captionSize))
                                            .foregroundStyle(Color.red.opacity(0.8))
                                    }
                                    .buttonStyle(.pressable)
                                }
                                .padding(.vertical, 6)
                                if note.id != model.memoryNotes.last?.id {
                                    Divider().overlay(Theme.panelBorder.opacity(0.6))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .panel(padding: SettingsMetrics.cardPadding)

                    MemoryKnowledgeBackupCard(model: model, scopeLabel: "记忆 + 知识库")
                }
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.bottom, 28)
            }
        }
        .task {
            await model.loadMemories(limit: 100, scopedToCurrentSession: false)
        }
    }
}

struct KnowledgeLibraryPane: View {
    /// Initial library from sidebar / deep-link; user can switch via in-pane chips.
    let nav: KnowledgeNav
    @ObservedObject var model: AppModel
    @State private var selectedLibrary: KnowledgeNav
    @State private var titleDraft = ""
    @State private var bodyDraft = ""
    @State private var typeFilter: String = "全部"
    @State private var importNote: String?

    init(nav: KnowledgeNav, model: AppModel) {
        self.nav = nav
        self.model = model
        _selectedLibrary = State(initialValue: nav)
    }

    private static let typeFilters = ["全部", "md", "txt", "pdf", "csv", "xlsx", "pptx", "chat", "其他"]

    private var visibleDocs: [AppModel.KnowledgeDocument] {
        model.knowledgeDocuments.filter { doc in
            if selectedLibrary.libraryID != "all", doc.library != selectedLibrary.libraryID {
                return false
            }
            if typeFilter == "全部" { return true }
            let ft = doc.fileType.lowercased()
            if typeFilter == "其他" {
                return !["md", "txt", "pdf", "csv", "xlsx", "pptx", "chat", "markdown"].contains(ft)
            }
            if typeFilter == "md" {
                return ft == "md" || ft == "markdown"
            }
            return ft == typeFilter
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(
                title: "知识库",
                subtitle: selectedLibrary.subtitle + " · 上传后参与每轮检索；类型/库标签可筛选",
                model: model
            )

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: SettingsMetrics.bodySize))
                                .foregroundStyle(Theme.textSecondary)
                            Text("上传文件")
                                .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("\(visibleDocs.count) 篇")
                                .font(.system(size: SettingsMetrics.captionSize, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                        }

                        Text("支持 md / txt / pdf / csv / xlsx / pptx（OOXML 正文尽力抽取）。聊天导出可用 txt / md / json。")
                            .font(.system(size: SettingsMetrics.captionSize))
                            .foregroundStyle(Theme.textSecondary)

                        HStack(spacing: 10) {
                            Button("选择本地文件…") {
                                pickAndImport()
                            }
                            .buttonStyle(.pressable)
                            .font(.system(size: SettingsMetrics.cardSubtitleSize))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))

                            if let importNote {
                                Text(importNote)
                                    .font(.system(size: SettingsMetrics.captionSize))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .panel(padding: SettingsMetrics.cardPadding)

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: SettingsMetrics.bodySize))
                                .foregroundStyle(Theme.textSecondary)
                            Text("手动添加")
                                .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }

                        TextField("标题", text: $titleDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: SettingsMetrics.bodySize))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))

                        TextField("正文…", text: $bodyDraft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: SettingsMetrics.bodySize))
                            .lineLimit(3...8)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))

                        HStack {
                            Spacer()
                            Button("保存") {
                                let title = titleDraft
                                let body = bodyDraft
                                titleDraft = ""
                                bodyDraft = ""
                                Task {
                                    await model.upsertKnowledgeDocument(
                                        title: title,
                                        body: body,
                                        library: selectedLibrary.libraryID == "all" ? "all" : selectedLibrary.libraryID,
                                        fileType: "note"
                                    )
                                }
                            }
                            .buttonStyle(.pressable)
                            .font(.system(size: SettingsMetrics.cardSubtitleSize))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                            .disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .panel(padding: SettingsMetrics.cardPadding)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("已入库")
                                .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(KnowledgeNav.allCases) { lib in
                                    let selected = selectedLibrary == lib
                                    Button(lib.rawValue) {
                                        selectedLibrary = lib
                                        Task {
                                            await model.loadKnowledgeDocuments(
                                                library: lib.libraryID == "all" ? nil : lib.libraryID
                                            )
                                        }
                                    }
                                    .buttonStyle(.pressable)
                                    .font(.system(size: SettingsMetrics.captionSize, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Color.black.opacity(0.85) : Theme.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        selected ? Theme.accent : Color.white.opacity(0.06),
                                        in: Capsule()
                                    )
                                }
                            }
                        }

                        if selectedLibrary == .all {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(Self.typeFilters, id: \.self) { tag in
                                        let selected = typeFilter == tag
                                        Button(tag) { typeFilter = tag }
                                            .buttonStyle(.pressable)
                                            .font(.system(size: SettingsMetrics.captionSize, weight: selected ? .semibold : .regular))
                                            .foregroundStyle(selected ? Color.black.opacity(0.85) : Theme.textSecondary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(
                                                selected ? Theme.accent : Color.white.opacity(0.06),
                                                in: Capsule()
                                            )
                                    }
                                }
                            }
                        }

                        if visibleDocs.isEmpty {
                            Text("暂无文档。上传本地文件或手动添加标题与正文。")
                                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            ForEach(visibleDocs) { doc in
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 8) {
                                            Text(doc.title)
                                                .font(.system(size: SettingsMetrics.labelSize, weight: .medium))
                                                .foregroundStyle(Theme.textPrimary)
                                            Text(libraryLabel(doc.library))
                                                .font(.system(size: SettingsMetrics.captionSize))
                                                .foregroundStyle(Theme.textSecondary)
                                            if !doc.fileType.isEmpty {
                                                Text(doc.fileType)
                                                    .font(.system(size: SettingsMetrics.captionSize, design: .monospaced))
                                                    .foregroundStyle(Theme.textSecondary.opacity(0.85))
                                            }
                                        }
                                        if doc.extractStatus != "ok" && !doc.extractStatus.isEmpty {
                                            Text(extractStatusLabel(doc))
                                                .font(.system(size: SettingsMetrics.captionSize))
                                                .foregroundStyle(Color.orange.opacity(0.9))
                                        }
                                        if !doc.body.isEmpty {
                                            Text(doc.body)
                                                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                                                .foregroundStyle(Theme.textSecondary)
                                                .lineLimit(3)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Button {
                                        Task { await model.deleteKnowledgeDocument(id: doc.id) }
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: SettingsMetrics.captionSize))
                                            .foregroundStyle(Color.red.opacity(0.8))
                                    }
                                    .buttonStyle(.pressable)
                                }
                                .padding(.vertical, 6)
                                if doc.id != visibleDocs.last?.id {
                                    Divider().overlay(Theme.panelBorder.opacity(0.6))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .panel(padding: SettingsMetrics.cardPadding)

                    MemoryKnowledgeBackupCard(model: model, scopeLabel: "记忆 + 知识库")
                }
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.bottom, 28)
            }
        }
        .task {
            await model.loadKnowledgeDocuments(library: selectedLibrary.libraryID == "all" ? nil : selectedLibrary.libraryID)
        }
    }

    private func libraryLabel(_ id: String) -> String {
        switch id {
        case "company": return "公司"
        case "client": return "客户"
        default: return "全部"
        }
    }

    private func extractStatusLabel(_ doc: AppModel.KnowledgeDocument) -> String {
        switch doc.extractStatus {
        case "partial":
            return "正文抽取不完整" + (doc.extractNote.isEmpty ? "" : "：\(doc.extractNote)")
        case "unsupported":
            return "此格式暂不支持正文抽取，已登记文件" + (doc.extractNote.isEmpty ? "" : "：\(doc.extractNote)")
        case "empty":
            return "未读出正文"
        default:
            return doc.extractNote
        }
    }

    private func pickAndImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "选择要加入「\(selectedLibrary.rawValue)」的本地文件"
        var types: [UTType] = [.plainText, .utf8PlainText, .text, .pdf, .commaSeparatedText]
        for ext in ["md", "markdown", "json", "csv", "xlsx", "xls", "pptx", "ppt", "txt"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }
        importNote = "正在导入 \(urls.count) 个文件…"
        Task {
            let result = await model.importKnowledgeFiles(
                urls: urls,
                library: selectedLibrary.libraryID == "all" ? "all" : selectedLibrary.libraryID
            )
            importNote = result
            await model.loadKnowledgeDocuments(library: selectedLibrary.libraryID == "all" ? nil : selectedLibrary.libraryID)
        }
    }
}

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
                            .buttonStyle(.pressable)
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
                                    .buttonStyle(.pressable)
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
    var trustReadOnly: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, command, args, enabled, url
        case oauthClientID, oauthToken, oauthAuthURL, trustReadOnly
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
        oauthAuthURL: String = "",
        trustReadOnly: Bool = false
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
        self.trustReadOnly = trustReadOnly
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
        trustReadOnly = try container.decodeIfPresent(Bool.self, forKey: .trustReadOnly) ?? false
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
                .buttonStyle(.pressable)
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
                .buttonStyle(.pressable)
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.accent)
                Button("HTTP 示例") {
                    applyPresetHTTP()
                }
                .buttonStyle(.pressable)
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
                .buttonStyle(.pressable)
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
                        .buttonStyle(.pressable)
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
                .buttonStyle(.pressable)
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
                                Toggle("信任只读", isOn: bindingTrustReadOnly(for: server))
                                    .font(.system(size: SettingsMetrics.captionSize))
                                    .toggleStyle(.checkbox)
                                    .help("仅当该服务的工具声明 readOnlyHint 时才免审批。默认仍要审批。")
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
                                    .buttonStyle(.pressable)
                                    .help("OAuth")
                                }
                                Button {
                                    Task { await reconnect(server) }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: SettingsMetrics.captionSize))
                                        .foregroundStyle(Theme.accent)
                                }
                                .buttonStyle(.pressable)
                                .help("重新连接")
                                Button {
                                    Task { await removeServer(server) }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: SettingsMetrics.captionSize))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                .buttonStyle(.pressable)
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
                .buttonStyle(.pressable)
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
            .buttonStyle(.pressable)
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

    private func bindingTrustReadOnly(for server: MCPServerDraft) -> Binding<Bool> {
        Binding(
            get: { servers.first(where: { $0.id == server.id })?.trustReadOnly ?? false },
            set: { value in
                if let idx = servers.firstIndex(where: { $0.id == server.id }) {
                    servers[idx].trustReadOnly = value
                    Task { await persist() }
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
