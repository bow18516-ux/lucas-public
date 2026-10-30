import AppKit
import SwiftUI
import UniformTypeIdentifiers
import JaplosProtocol
import JaplosClient

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
