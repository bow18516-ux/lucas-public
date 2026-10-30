import AppKit
import SwiftUI
import UniformTypeIdentifiers
import JaplosProtocol
import JaplosClient

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
