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

                Spacer(minLength: 8)

                Button {
                    model.settingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.pressable)
                .overlay(alignment: .topTrailing) {
                    if updateService.updateAvailable {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -2)
                    }
                }
                .help("设置")
            }
            .frame(width: DashboardLayout.columnWidth, alignment: .leading)

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
            .buttonStyle(.pressable)
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
                .font(.system(size: 11))
                .buttonStyle(.pressable)
                .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 0) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { day in
                    Text(day)
                        .font(.system(size: 11))
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
            .font(.system(size: 10))
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
            if let nudge = model.unfinishedNudge {
                unfinishedNudgeBanner(nudge)
            }
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

    private func unfinishedNudgeBanner(_ nudge: AppModel.UnfinishedNudge) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("还有未完成的事项")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(nudge.titles.prefix(3).joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button {
                    let prompt = model.continueUnfinishedNudgePrompt()
                    draft = prompt
                    model.send(prompt)
                    draft = ""
                } label: {
                    Text("继续")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.pressable)

                Button {
                    model.dismissUnfinishedNudge()
                } label: {
                    Text("稍后")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.25), lineWidth: 0.8)
        )
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
            .buttonStyle(.pressable)

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
            .buttonStyle(.pressable)
            .help(speech.isRecording ? "停止并发送" : "语音输入")

            Button {
                voice.enabled.toggle()
                if !voice.enabled { voice.stop() }
            } label: {
                Image(systemName: voice.enabled ? (voice.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2") : "speaker.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(voice.enabled ? (voice.isSpeaking ? Theme.accent : Theme.textSecondary.opacity(0.8)) : Theme.textSecondary.opacity(0.4))
            }
            .buttonStyle(.pressable)
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
                .buttonStyle(.pressable)
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
                .buttonStyle(.pressable)
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
