import JaplosProtocol
import AppKit
import SwiftUI

// MARK: - Theme

/// One coordinate system for the dashboard: outer margins, column widths,
/// gutters and the conversation measure all come from here.
enum DashboardLayout {
    static let outerMargin: CGFloat = 24
    static let columnWidth: CGFloat = 284
    static let gutter: CGFloat = 24
    static let conversationWidth: CGFloat = 680
    static let topBarHeight: CGFloat = 58
    static let topBarTopPadding: CGFloat = 22
    static let contentTopPadding: CGFloat = 8
}

enum Theme {
    static let background = Color(red: 0.035, green: 0.039, blue: 0.041)
    static let panel = Color(red: 0.072, green: 0.072, blue: 0.083)
    static let panelBorder = Color.white.opacity(0.065)
    static let accent = Color(red: 0.82, green: 0.65, blue: 0.38)
    static let textPrimary = Color(red: 0.93, green: 0.93, blue: 0.95)
    static let textSecondary = Color(red: 0.55, green: 0.55, blue: 0.60)
    static let success = Color(red: 0.44, green: 0.85, blue: 0.55)

    static let backgroundNSColor = NSColor(calibratedRed: 0.035, green: 0.039, blue: 0.041, alpha: 1)
}

extension View {
    func panel(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.panelBorder, lineWidth: 0.8)
            )
    }
}

private extension View {
    func sectionTitle() -> some View {
        self.font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
    }
}

// MARK: - Root

struct CoreSurfaceView: View {
    @ObservedObject var model: AppModel
    @State private var draft = ""
    @State private var showTools = false

    var body: some View {
        Group {
            if model.settingsPresented {
                SettingsScreen(model: model, voice: model.voice)
                    .transition(.opacity)
            } else {
                mainSurface
            }
        }
        .overlay {
            if model.onboardingPresented {
                OnboardingView(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: model.settingsPresented)
        .animation(.easeInOut(duration: 0.18), value: model.onboardingPresented)
        .sheet(isPresented: $showTools) {
            ToolCatalogSheet(model: model)
        }
        .alert("出错了", isPresented: Binding(
            get: { model.errorText != nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            Button("好", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorText ?? "")
        }
    }

    private var mainSurface: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            RadialGradient(
                colors: [Theme.accent.opacity(0.06), .clear],
                center: UnitPoint(x: 0.5, y: 0.30),
                startRadius: 10,
                endRadius: 480
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(model: model)
                HStack(alignment: .top, spacing: DashboardLayout.gutter) {
                    ScrollView(.vertical, showsIndicators: false) {
                        LeftColumn(model: model)
                            .frame(width: DashboardLayout.columnWidth)
                    }
                    .frame(width: DashboardLayout.columnWidth)
                    CenterColumn(model: model, draft: $draft, showTools: $showTools, voice: model.voice)
                    RightColumn(model: model, showTools: $showTools)
                        .frame(width: DashboardLayout.columnWidth)
                }
                .padding(.horizontal, DashboardLayout.outerMargin)
                .padding(.top, DashboardLayout.contentTopPadding)
                .padding(.bottom, 18)
            }
        }
        .frame(minWidth: 1120, minHeight: 720)
        .alert("需要确认", isPresented: Binding(
            get: { model.pendingApproval != nil },
            set: { if !$0 { model.resolveApproval(false) } }
        )) {
            Button("允许执行", role: .destructive) { model.resolveApproval(true) }
            Button("拒绝", role: .cancel) { model.resolveApproval(false) }
        } message: {
            Text(approvalMessage)
        }
    }

    private var approvalMessage: String {
        guard let approval = model.pendingApproval else { return "" }
        return "\(approval.title)\n\(approval.name)\n\n\(approval.summary)"
    }
}

// MARK: - Top bar

struct TopBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var updateService = UpdateService.shared

    private var modelPicker: some View {
        Menu {
            if model.hasStoredConnection {
                if model.availableModels.isEmpty {
                    Text("暂无模型列表，先刷新")
                } else {
                    ForEach(model.availableModels, id: \.self) { id in
                        Button {
                            Task { await model.switchModel(id) }
                        } label: {
                            if id == model.settings.model {
                                Label(id, systemImage: "checkmark")
                            } else {
                                Text(id)
                            }
                        }
                    }
                }
                Divider()
                Button("刷新模型列表") {
                    Task { await model.refreshModels() }
                }
                Button("打开模型设置…") {
                    model.settingsPresented = true
                }
            } else {
                Button("配置模型…") {
                    model.onboardingPresented = true
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                Text(model.hasStoredConnection
                     ? (model.settings.model.isEmpty ? "选择模型" : model.settings.model)
                     : "未配置模型")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(model.hasStoredConnection ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.panelBorder, lineWidth: 0.8))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("切换对话模型")
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(LinearGradient(
                    colors: [Theme.accent, Theme.accent.opacity(0.35)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: 3, height: 20)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("LUCAS")
                    .font(.system(size: 14, weight: .bold))
                    .tracking(3.5)
                    .foregroundStyle(Theme.textPrimary)

                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
            }

            Button {
                model.settingsPresented = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.borderless)
            .padding(.leading, 4)
            .overlay(alignment: .topTrailing) {
                if updateService.updateAvailable {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                        .offset(x: 3, y: -2)
                }
            }

            Spacer()

            modelPicker

            HStack(spacing: 7) {
                Circle()
                    .fill(model.connected ? Theme.success : Color.orange)
                    .frame(width: 6, height: 6)
                Text(model.connected ? "已连接本地服务" : "未连接")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.panelBorder, lineWidth: 0.8))

            Button {
                Task { await model.bootstrap() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, DashboardLayout.outerMargin)
        .padding(.top, DashboardLayout.topBarTopPadding)
        .frame(height: DashboardLayout.topBarHeight)
    }
}

// MARK: - Left column

struct LeftColumn: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            ModelCard(model: model)
            MemoryCard(model: model)
            KnowledgeCard(model: model)
            CalendarCard(model: model)
            Spacer(minLength: 0)
        }
    }
}

struct ModelCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 8) {
                Text("大语言模型")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(model.settings.model.isEmpty ? "未配置" : model.settings.model)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(model.hasStoredConnection ? providerName : "尚未选择服务商")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            VStack(spacing: 20) {
                HStack(alignment: .top, spacing: 0) {
                    stat("注册扩展", "\(model.tools.count)")
                    stat("记忆", "\(model.sessions.count)")
                    stat("知识库", "\(knowledgeCount)")
                }
                HStack(alignment: .top, spacing: 0) {
                    stat("技能", "\(skillCount)")
                    stat("MCP", "\(mcpToolCount)")
                    stat("社交媒体", "0")
                }
            }

            Divider().overlay(Theme.panelBorder)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("已连接")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Text("暂无社交媒体连接")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.accent.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 18)
    }

    private var mcpToolCount: Int {
        model.tools.filter { $0.sourceLabel == "MCP" }.count
    }

    private var knowledgeCount: Int {
        model.knowledgeDocuments.count
    }

    private var skillCount: Int {
        BuiltinSkillCatalog.load().count
    }

    private var providerName: String {
        let url = model.settings.baseURL.lowercased()
        if url.contains("deepseek") { return "DeepSeek" }
        if url.contains("xiaomimimo") { return "MiMo" }
        if let host = URL(string: model.settings.baseURL)?.host { return host }
        return "自定义连接"
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MemoryCard: View {
    @ObservedObject var model: AppModel
    @State private var draft = ""

    private var displayItems: [(id: String, text: String)] {
        if !model.memoryNotes.isEmpty {
            return model.memoryNotes.prefix(6).map { ($0.id, $0.content) }
        }
        var items: [(String, String)] = []
        for session in model.sessions.prefix(6) {
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            items.append((session.id, title.isEmpty ? "会话 \(session.id.prefix(8))" : title))
        }
        if items.isEmpty {
            for message in model.messages.reversed() where message.role == "user" {
                let clip = message.text.replacingOccurrences(of: "\n", with: " ")
                if clip.isEmpty { continue }
                items.append((message.id.uuidString, String(clip.prefix(36))))
                if items.count >= 5 { break }
            }
        }
        return items
    }

    private var excerptCount: Int {
        model.messages.filter { $0.role == "assistant" && !$0.text.isEmpty }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("记忆")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(model.memoryNotes.isEmpty ? "会话回退" : "已持久化")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.05), in: Capsule())
            }

            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.panelBorder, style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                .frame(minHeight: 150)
                .overlay(alignment: .topLeading) {
                    if displayItems.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 7, height: 7)
                            Text("暂无记忆")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary.opacity(0.7))
                            Text("点「记一条」保存短笔记")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.textSecondary.opacity(0.55))
                        }
                        .padding(12)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(displayItems, id: \.id) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(Theme.accent.opacity(0.85))
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 3)
                                    Text(item.text)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.textPrimary.opacity(0.9))
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(12)
                    }
                }

            HStack(spacing: 8) {
                TextField("记一条…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                Button("保存") {
                    let text = draft
                    draft = ""
                    Task { await model.rememberNote(text) }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("记上条") {
                    Task { await model.rememberLatestUserMessage() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 12) {
                Label("记忆 \(displayItems.count)", systemImage: "square")
                Label("知识摘录 \(excerptCount)", systemImage: "square")
                Spacer()
            }
            .font(.system(size: 9))
            .foregroundStyle(Theme.textSecondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 18)
        .task { await model.loadMemories() }
    }
}


struct KnowledgeCard: View {
    @ObservedObject var model: AppModel
    @State private var titleDraft = ""
    @State private var bodyDraft = ""

    private var items: [AppModel.KnowledgeDocument] {
        Array(model.knowledgeDocuments.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("知识库")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(model.knowledgeDocuments.count) 篇")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.05), in: Capsule())
            }

            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.panelBorder, style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                .frame(minHeight: 120)
                .overlay(alignment: .topLeading) {
                    if items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 7, height: 7)
                            Text("暂无文档")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary.opacity(0.7))
                            Text("标题 + 正文保存到 knowledge.documents")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.textSecondary.opacity(0.55))
                        }
                        .padding(12)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(items) { doc in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(Theme.accent.opacity(0.85))
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 3)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(doc.title)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(Theme.textPrimary.opacity(0.95))
                                            .lineLimit(1)
                                        if !doc.body.isEmpty {
                                            Text(doc.body)
                                                .font(.system(size: 9))
                                                .foregroundStyle(Theme.textSecondary.opacity(0.85))
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Button {
                                        Task { await model.deleteKnowledgeDocument(id: doc.id) }
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 9))
                                            .foregroundStyle(Theme.textSecondary.opacity(0.7))
                                    }
                                    .buttonStyle(.borderless)
                                    .help("删除")
                                }
                            }
                        }
                        .padding(12)
                    }
                }

            VStack(alignment: .leading, spacing: 6) {
                TextField("标题", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                TextField("正文…", text: $bodyDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Spacer()
                    Button("添加") {
                        let title = titleDraft
                        let body = bodyDraft
                        titleDraft = ""
                        bodyDraft = ""
                        Task { await model.upsertKnowledgeDocument(title: title, body: body) }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                    .disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 18)
        .task { await model.loadKnowledgeDocuments() }
    }
}

struct CalendarCard: View {
    @ObservedObject var model: AppModel
    @State private var monthOffset = 0

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        calendar.firstWeekday = 2
        return calendar
    }

    private var monthDate: Date {
        calendar.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: monthDate)
    }

    private var activeDays: Set<Int> {
        let comps = calendar.dateComponents([.year, .month], from: monthDate)
        var days = Set<Int>()
        for session in model.sessions {
            let c = calendar.dateComponents([.year, .month, .day], from: session.updatedAt)
            if c.year == comps.year, c.month == comps.month, let day = c.day {
                days.insert(day)
            }
        }
        for message in model.messages {
            let c = calendar.dateComponents([.year, .month, .day], from: message.createdAt)
            if c.year == comps.year, c.month == comps.month, let day = c.day {
                days.insert(day)
            }
        }
        return days
    }

    private var days: [Int?] {
        guard
            let range = calendar.range(of: .day, in: .month, for: monthDate),
            let first = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate))
        else { return [] }
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var result: [Int?] = Array(repeating: nil, count: leading)
        result.append(contentsOf: range.map { Optional($0) })
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(monthTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                HStack(spacing: 12) {
                    Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left") }
                    Button { monthOffset = 0 } label: { Text("今天") }
                    Button { monthOffset += 1 } label: { Image(systemName: "chevron.right") }
                }
                .font(.system(size: 10))
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 0) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { day in
                    Text(day)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 8) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    dayCell(day)
                }
            }

            HStack {
                HStack(spacing: 4) {
                    Circle().fill(Theme.accent).frame(width: 3, height: 3)
                    Text(activeDays.isEmpty ? "有会话的日期会点亮" : "本月有活动 \(activeDays.count) 天")
                }
                Spacer()
                Text("北京时间")
            }
            .font(.system(size: 9))
            .foregroundStyle(Theme.textSecondary.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 18)
    }

    private func dayCell(_ day: Int?) -> some View {
        Group {
            if let day {
                let isToday = monthOffset == 0 && calendar.component(.day, from: Date()) == day
                let hasActivity = activeDays.contains(day)
                VStack(spacing: 2) {
                    Text("\(day)")
                        .font(.system(size: 11, weight: isToday ? .semibold : .regular))
                        .foregroundStyle(isToday ? Color.black.opacity(0.85) : Theme.textPrimary.opacity(0.85))
                        .frame(width: 28, height: 28)
                        .background(
                            isToday ? Theme.accent : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    Circle()
                        .fill(hasActivity ? Theme.accent : Color.clear)
                        .frame(width: 3, height: 3)
                }
            } else {
                Color.clear.frame(height: 34)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Center column

struct CenterColumn: View {
    @ObservedObject var model: AppModel
    @Binding var draft: String
    @Binding var showTools: Bool
    @ObservedObject var voice: SpeechOutput
    @StateObject private var speech = SpeechInput()

    /// ImageRenderer cannot rasterise ScrollView content, so snapshots render
    /// the same content without the scroll container.
    private var isSnapshot: Bool {
        ProcessInfo.processInfo.environment["LUCAS_SNAPSHOT"] != nil
    }

    var body: some View {
        GeometryReader { proxy in
            content(in: proxy.size)
        }
    }

    private func content(in size: CGSize) -> some View {
        let orbHeight = max(200, min(380, size.height * 0.42))
        let orbWidth = min(420, size.width)
        let topInset = max(6, min(40, size.height * 0.045))
        return VStack(spacing: 0) {
            OrbView()
                .frame(width: orbWidth, height: orbHeight)
                .padding(.top, topInset)

            Text("Lucas.ai")
                .font(.system(size: 21, weight: .medium, design: .monospaced))
                .tracking(8)
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 18)

            conversation

            composer
                .frame(maxWidth: 620)
                .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: speech.errorText) { value in
            if let value {
                model.errorText = value
                speech.errorText = nil
            }
        }
    }

    private var conversation: some View {
        Group {
            if isSnapshot {
                conversationBody
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        conversationBody
                    }
                    .scrollIndicators(.never)
                    .onChange(of: model.messages.count) { _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            if model.isSending {
                                proxy.scrollTo("thinking", anchor: .bottom)
                            } else if let last = model.messages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conversationBody: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            if model.messages.isEmpty {
                emptyState
            }
            ForEach(model.messages) { message in
                TurnRow(message: message)
                    .id(message.id)
            }
            if model.isSending {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("思考中…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .id("thinking")
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
        .frame(maxWidth: DashboardLayout.conversationWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("从一句话开始")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("打开应用、执行命令、读写文件、截屏。先到设置里填好模型连接。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 8)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Button {
                showTools = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.05), in: Circle())
            }
            .buttonStyle(.borderless)

            if speech.isRecording {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 5, height: 5)
                    Text(speech.transcript.isEmpty ? "正在聆听…" : speech.transcript)
                        .font(.system(size: 13))
                        .foregroundStyle(speech.transcript.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("输入指令，或点麦克风说话", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .onSubmit(sendDraft)
                    .disabled(model.isSending)
            }

            Button {
                toggleVoice()
            } label: {
                Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 11))
                    .foregroundStyle(speech.isRecording ? Color.red : Theme.textSecondary.opacity(0.8))
            }
            .buttonStyle(.borderless)
            .help(speech.isRecording ? "停止并发送" : "语音输入")

            Button {
                voice.enabled.toggle()
                if !voice.enabled { voice.stop() }
            } label: {
                Image(systemName: voice.enabled ? (voice.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2") : "speaker.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(voice.enabled ? (voice.isSpeaking ? Theme.accent : Theme.textSecondary.opacity(0.8)) : Theme.textSecondary.opacity(0.4))
            }
            .buttonStyle(.borderless)
            .help(voice.enabled ? "关闭语音播报" : "开启语音播报")

            HStack(spacing: 5) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.accent)
                Text(model.settings.model.isEmpty ? "未配置" : model.settings.model)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.04), in: Capsule())

            if model.isSending {
                Button(action: model.stop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.borderless)
            } else {
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.black.opacity(draft.isEmpty ? 0.35 : 0.85))
                        .frame(width: 28, height: 28)
                        .background(
                            Theme.accent.opacity(draft.isEmpty ? 0.35 : 1),
                            in: Circle()
                        )
                }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.panelBorder, lineWidth: 0.8)
        )
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        model.send(text)
    }

    private func toggleVoice() {
        if speech.isRecording {
            speech.stop()
            let text = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            speech.transcript = ""
            if !text.isEmpty {
                model.send(text)
            }
        } else {
            speech.start(language: voice.languageCode, deviceUID: voice.inputDeviceUID)
        }
    }
}

struct TurnRow: View {
    let message: AppModel.Message
    @State private var hovering = false

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: .leading, spacing: 8) {
                if !message.text.isEmpty {
                    if isUser {
                        Text(message.text)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            .textSelection(.enabled)
                    } else {
                        MarkdownText(text: message.text)
                            .foregroundStyle(Theme.textPrimary)
                            .tint(Theme.accent)
                    }
                }

                if !isUser, !message.text.isEmpty, hovering {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.textSecondary)
                }

                if !message.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(message.steps) { step in
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(step.ok ? Theme.success : Color.red.opacity(0.8))
                                    .frame(width: 5, height: 5)
                                Text(step.name)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                if !step.detail.isEmpty {
                                    Text(step.detail)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }

            if !isUser { Spacer(minLength: 40) }
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - Orb

struct OrbView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let maxRadius = min(size.width, size.height) * 0.48
                let breath = 0.5 + 0.5 * sin(time * 0.9)
                let glowRadius = maxRadius * (1.30 + 0.06 * breath)

                context.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - glowRadius,
                        y: center.y - glowRadius,
                        width: glowRadius * 2,
                        height: glowRadius * 2
                    )),
                    with: .radialGradient(
                        Gradient(colors: [Theme.accent.opacity(0.07 + 0.05 * breath), .clear]),
                        center: center,
                        startRadius: maxRadius * 0.25,
                        endRadius: glowRadius
                    )
                )

                // Particle shell: Fibonacci sphere projected with a slow spin.
                let count = 1100
                let spin = time * 0.16
                let tilt = 0.42
                var particles: [(CGPoint, Double, Double)] = []
                particles.reserveCapacity(count)
                for index in 0..<count {
                    let y = 1 - 2 * (Double(index) + 0.5) / Double(count)
                    let ringRadius = (max(0, 1 - y * y)).squareRoot()
                    let theta = Double(index) * 2.399963229728653
                    let x0 = cos(theta) * ringRadius
                    let z0 = sin(theta) * ringRadius

                    let x1 = x0 * cos(spin) - z0 * sin(spin)
                    let z1 = x0 * sin(spin) + z0 * cos(spin)
                    let y1 = y * cos(tilt) - z1 * sin(tilt)
                    let z2 = y * sin(tilt) + z1 * cos(tilt)

                    let breathe = 1 + 0.018 * sin(time * 1.4 + Double(index) * 0.05)
                    let perspective = 1.0 / (1.0 + z2 * 0.22)
                    let radius = maxRadius * 0.92 * breathe * perspective
                    let point = CGPoint(x: center.x + x1 * radius, y: center.y + y1 * radius)
                    let depth = (z2 + 1) / 2
                    particles.append((point, depth, perspective))
                }
                particles.sort { $0.2 < $1.2 }

                for (point, depth, _) in particles {
                    let dotSize = 0.8 + 1.9 * depth
                    let alpha = 0.08 + 0.54 * depth
                    let dot = Path(ellipseIn: CGRect(
                        x: point.x - dotSize / 2,
                        y: point.y - dotSize / 2,
                        width: dotSize,
                        height: dotSize
                    ))
                    context.fill(dot, with: .color(Theme.accent.opacity(alpha)))
                }

                // A few orbit rings keep the structure readable.
                for ring in 0..<3 {
                    let radius = maxRadius * (0.74 + Double(ring) * 0.13)
                    context.stroke(
                        Path(ellipseIn: CGRect(
                            x: center.x - radius,
                            y: center.y - radius * 0.34,
                            width: radius * 2,
                            height: radius * 0.68
                        )),
                        with: .color(Theme.accent.opacity(0.10 - Double(ring) * 0.02)),
                        lineWidth: 0.7
                    )
                }

                let coreRadius = maxRadius * (0.30 + 0.012 * breath)
                let coreRect = CGRect(
                    x: center.x - coreRadius,
                    y: center.y - coreRadius,
                    width: coreRadius * 2,
                    height: coreRadius * 2
                )
                context.fill(
                    Path(ellipseIn: coreRect),
                    with: .radialGradient(
                        Gradient(colors: [
                            Theme.accent.opacity(0.12 + 0.05 * breath),
                            Color(red: 0.10, green: 0.09, blue: 0.08),
                            Color(red: 0.045, green: 0.042, blue: 0.04),
                        ]),
                        center: center,
                        startRadius: 0,
                        endRadius: coreRadius
                    )
                )
                context.stroke(
                    Path(ellipseIn: coreRect),
                    with: .color(Theme.accent.opacity(0.22)),
                    lineWidth: 0.8
                )
            }
        }
    }
}

// MARK: - Right column

struct RightColumn: View {
    @ObservedObject var model: AppModel
    @Binding var showTools: Bool

    private var latestSteps: [AppModel.ToolStep] {
        if let last = model.messages.last(where: { !$0.steps.isEmpty })?.steps, !last.isEmpty {
            return last
        }
        return []
    }

    private var projectionSteps: [AppModel.ToolStep] {
        Array(model.messages.suffix(12).flatMap(\.steps).reversed())
    }

    var body: some View {
        VStack(spacing: 14) {
            ProjectionStack(steps: projectionSteps)
            sourcesPanel
            Spacer(minLength: 0)
            taskPanel
        }
    }

    private var sourcesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                Text("资料")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("\(latestSteps.count) 条")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                Spacer()
            }

            if latestSteps.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.panelBorder, style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                    .frame(height: 120)
                    .overlay {
                        Text("本轮暂无工具回执")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary.opacity(0.65))
                    }
            } else {
                VStack(spacing: 8) {
                    ForEach(latestSteps.prefix(5)) { step in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(step.ok ? Theme.success : Color.red.opacity(0.8))
                                    .frame(width: 4, height: 4)
                                Text(step.name)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                            }
                            if !step.detail.isEmpty {
                                Text(step.detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(3)
                            }
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Theme.panelBorder, lineWidth: 0.6)
                        )
                    }
                }
            }
        }
        .panel()
    }

    private var finishedTaskCount: Int {
        model.messages.filter { !$0.steps.isEmpty }.count
    }

    private var sessionLabel: String {
        if let id = model.currentSessionID,
           let session = model.sessions.first(where: { $0.id == id }) {
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "主会话" : String(title.prefix(12))
        }
        return "主会话"
    }

    private var taskPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("任务")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)

                Text(sessionLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.07), in: Capsule())

                Text("已结束 \(max(finishedTaskCount, model.recentTasks.count))")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))

                Spacer()
            }

            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.panelBorder, style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                .frame(minHeight: 96)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.isSending {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("正在执行本轮对话")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                        }
                        if !latestSteps.isEmpty {
                            ForEach(latestSteps.prefix(3)) { step in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(step.ok ? Theme.success : Color.orange.opacity(0.85))
                                        .frame(width: 5, height: 5)
                                    Text(step.name)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                }
                            }
                        } else if !model.recentTasks.isEmpty {
                            ForEach(model.recentTasks.prefix(4)) { task in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(task.state == "completed" ? Theme.success : Color.orange.opacity(0.85))
                                        .frame(width: 5, height: 5)
                                    Text(task.title)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(task.state)
                                        .font(.system(size: 9))
                                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                                }
                            }
                        } else if !model.isSending {
                            Text("暂无当前任务")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                            Text("主会话 \(model.messages.count) 条消息")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.textSecondary.opacity(0.6))
                        }
                    }
                    .padding(12)
                }

            HStack(spacing: 14) {
                Button("工具列表") { showTools = true }
                Button("执行记录") { showTools = true }
                Button("连接") { model.settingsPresented = true }
                Spacer()
            }
            .font(.system(size: 10))
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.textSecondary)
        }
        .panel()
    }
}


// MARK: - Projections (tool-driven chrome)

struct ProjectionStack: View {
    let steps: [AppModel.ToolStep]

    private var music: AppModel.ToolStep? {
        steps.last(where: { $0.name == "system.music" || $0.name.hasSuffix(".music") })
    }
    private var application: AppModel.ToolStep? {
        steps.last(where: { $0.name == "system.application" || $0.name.contains(".application") })
    }
    private var screenshot: AppModel.ToolStep? {
        steps.last(where: { $0.name == "system.screen.capture" || $0.name.contains("screen.capture") })
    }

    private var hasAny: Bool { music != nil || application != nil || screenshot != nil }

    var body: some View {
        if hasAny {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                    Text("投影")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                if let music { MusicProjectionCard(step: music) }
                if let application { AppsProjectionCard(step: application) }
                if let screenshot { ScreenshotProjectionCard(step: screenshot) }
            }
            .panel()
        }
    }
}

struct MusicProjectionCard: View {
    let step: AppModel.ToolStep

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text("音乐")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text(step.detail.isEmpty ? (step.ok ? "已执行播放控制" : "控制失败") : step.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(step.ok ? Theme.success : Color.red.opacity(0.8))
                .frame(width: 6, height: 6)
        }
        .padding(10)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.panelBorder, lineWidth: 0.6))
    }
}

struct AppsProjectionCard: View {
    let step: AppModel.ToolStep

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "app.badge.checkmark")
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text("应用")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text(step.detail.isEmpty ? step.name : step.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(step.ok ? Theme.success : Color.red.opacity(0.8))
                .frame(width: 6, height: 6)
        }
        .padding(10)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.panelBorder, lineWidth: 0.6))
    }
}

struct ScreenshotProjectionCard: View {
    let step: AppModel.ToolStep

    private var imagePath: String? {
        let tokens = step.detail.split(whereSeparator: { $0.isWhitespace || ",{}".contains($0) }).map(String.init)
        if let hit = tokens.first(where: { $0.hasPrefix("/") && $0.contains(".png") }) {
            return hit.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        if let range = step.detail.range(of: #"/[^\\s\"']+\\.png"#, options: .regularExpression) {
            return String(step.detail[range])
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let path = imagePath, let ns = NSImage(contentsOfFile: path) {
                Image(nsImage: ns)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 40)
                    .clipped()
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.5))
            } else {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 56, height: 40)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("截图")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text(imagePath ?? (step.detail.isEmpty ? "已截屏" : step.detail))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.panelBorder, lineWidth: 0.6))
    }
}


// MARK: - Tool sheet

struct ToolCatalogSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("工具列表")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(model.tools.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("关闭") { dismiss() }
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.tools) { tool in
                        HStack(alignment: .top, spacing: 10) {
                            Text(tool.risk.uppercased())
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(tool.risk == "high" ? Color.red : Theme.textSecondary)
                                .frame(width: 38, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                Text(tool.title)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                        }
                        .padding(9)
                        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 480, height: 460)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}
