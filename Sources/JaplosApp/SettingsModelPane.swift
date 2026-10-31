import AppKit
import SwiftUI
import UniformTypeIdentifiers
import JaplosProtocol
import JaplosClient

// MARK: - Provider catalog (DeepSeek shipping; others placeholder)

private enum ModelProviderID: String, CaseIterable, Identifiable {
    case deepseek
    case glm
    case qwen
    case doubao

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .glm: return "智谱 GLM"
        case .qwen: return "通义千问"
        case .doubao: return "豆包"
        }
    }

    var subtitle: String {
        switch self {
        case .deepseek: return "已接入"
        case .glm, .qwen, .doubao: return "即将支持"
        }
    }

    var isAvailable: Bool {
        self == .deepseek
    }

    var systemImage: String {
        switch self {
        case .deepseek: return "brain.head.profile"
        case .glm: return "sparkles"
        case .qwen: return "cloud"
        case .doubao: return "leaf"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/v1"
        case .glm: return "https://open.bigmodel.cn/api/paas/v4"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .doubao: return "https://ark.cn-beijing.volces.com/api/v3"
        }
    }

    static func infer(from baseURL: String) -> ModelProviderID {
        let url = baseURL.lowercased()
        if url.contains("deepseek") { return .deepseek }
        if url.contains("bigmodel") || url.contains("zhipu") { return .glm }
        if url.contains("dashscope") || url.contains("aliyun") { return .qwen }
        if url.contains("volces") || url.contains("doubao") || url.contains("ark.cn") { return .doubao }
        return .deepseek
    }
}

private struct DeepSeekModelOption: Identifiable, Hashable {
    let id: String
    let title: String
    let blurb: String

    /// Official API ids (2026-10-31): deepseek-flash / deepseek-v4-pro.
    /// Legacy deepseek-chat / deepseek-reasoner retired 2026-07-24 — do not list.
    static let catalog: [DeepSeekModelOption] = [
        .init(id: "deepseek-flash", title: "DeepSeek V4.1 Flash", blurb: "V4.1 Flash-1017 · 快"),
        .init(id: "deepseek-v4-pro", title: "DeepSeek V4 Pro", blurb: "V4-Pro-0813 · 强"),
    ]
}

/// UI 低/中/高 → DeepSeek `thinking` + `reasoning_effort`（不是温度）。
/// 映射：低=low，中=high，高=max；默认思考开启。
private enum ThinkingIntensity: String, CaseIterable, Identifiable {
    case low, medium, high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    var thinkingEnabled: Bool { true }

    /// OpenAI ChatCompletions `reasoning_effort` after DeepSeek mapping table.
    var reasoningEffort: String {
        switch self {
        case .low: return "low"
        case .medium: return "high"
        case .high: return "max"
        }
    }

    static func from(connection: ModelConnection) -> ThinkingIntensity {
        if !connection.thinkingEnabled { return .low }
        switch ModelConnection.normalizedEffort(connection.reasoningEffort) {
        case "low": return .low
        case "max": return .high
        default: return .medium
        }
    }

    func apply(to settings: inout ModelConnection) {
        settings.thinkingEnabled = thinkingEnabled
        settings.reasoningEffort = reasoningEffort
        // Temperature is ignored in DeepSeek thinking mode; keep a mild default for non-thinking probes.
        settings.temperature = 0.3
    }
}

struct ModelSettingsPane: View {
    @ObservedObject var model: AppModel
    @State private var selectedProvider: ModelProviderID = .deepseek
    @State private var savedNote = "选择厂商后填写 Key 并保存"
    @State private var savedRoutes: [JSONValue] = []

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: "大模型设置", subtitle: "先选厂商，再填该厂商需要的字段", model: model)

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    currentCard
                    providerGalleryCard
                    if selectedProvider.isAvailable {
                        deepseekFormCard
                    } else {
                        comingSoonCard
                    }
                    routesCard
                }
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.bottom, 20)
            }

            bottomBar
        }
        .task {
            selectedProvider = ModelProviderID.infer(from: model.settings.baseURL)
            if selectedProvider == .deepseek {
                applyDeepSeekDefaults(preserveModel: true)
            }
            await reloadRoutes()
        }
        .onChange(of: model.settings.baseURL) { newValue in
            let inferred = ModelProviderID.infer(from: newValue)
            if inferred != selectedProvider, inferred.isAvailable {
                selectedProvider = inferred
            }
        }
    }

    private func reloadRoutes() async {
        savedRoutes = await model.listModelRoutes()
    }

    // MARK: - Current

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
                Text("保存后用于后续对话；也可在下方 API Key 旁点「测试连接」验证。")
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
            .disabled(model.isTestingModel || !canTestConnection)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

    // MARK: - Provider gallery

    private var providerGalleryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择厂商")
                .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("点选下方按钮；本版 DeepSeek 可完整配置，其它厂商先占位。")
                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                .foregroundStyle(Theme.textSecondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140), spacing: 10)],
                spacing: 10
            ) {
                ForEach(ModelProviderID.allCases) { provider in
                    ProviderChip(
                        provider: provider,
                        selected: selectedProvider == provider
                    ) {
                        selectProvider(provider)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

    private func selectProvider(_ provider: ModelProviderID) {
        selectedProvider = provider
        if provider == .deepseek {
            applyDeepSeekDefaults(preserveModel: false)
            savedNote = "已选 DeepSeek，填写 API Key 后保存"
        } else {
            savedNote = "\(provider.title) 即将支持，本版请先用 DeepSeek"
        }
    }

    private func applyDeepSeekDefaults(preserveModel: Bool) {
        model.settings.baseURL = ModelProviderID.deepseek.defaultBaseURL
        if model.settings.displayName.trimmingCharacters(in: .whitespaces).isEmpty
            || model.settings.displayName == "自定义"
            || !model.settings.displayName.lowercased().contains("deepseek") {
            model.settings.displayName = "DeepSeek"
        }
        let known = Set(DeepSeekModelOption.catalog.map(\.id))
        if !preserveModel || model.settings.model.isEmpty || !known.contains(model.settings.model) {
            model.settings.model = DeepSeekModelOption.catalog[0].id
        }
        // Migrate retired ids and ensure thinking defaults for DeepSeek requests.
        if model.settings.reasoningEffort.trimmingCharacters(in: .whitespaces).isEmpty {
            model.settings.reasoningEffort = "high"
        }
        model.settings.reasoningEffort = ModelConnection.normalizedEffort(model.settings.reasoningEffort)
        if !preserveModel {
            model.settings.thinkingEnabled = true
        }
    }

    // MARK: - DeepSeek form

    private var deepseekFormCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("DeepSeek 连接")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                Text("Chat Completions")
                    .font(.system(size: SettingsMetrics.microSize))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06), in: Capsule())
                Spacer()
            }

            // Base URL: fixed, not user-facing required field.
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
                Text(ModelProviderID.deepseek.defaultBaseURL)
                    .font(.system(size: SettingsMetrics.cardSubtitleSize, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                Text("已预填")
                    .font(.system(size: SettingsMetrics.microSize))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.panelBorder, lineWidth: 0.7))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("API Key")
                        .font(.system(size: SettingsMetrics.labelSize))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: model.storedAPIKey.isEmpty ? "circle" : "checkmark.circle.fill")
                            .font(.system(size: SettingsMetrics.captionSize))
                        Text(model.storedAPIKey.isEmpty ? "未保存" : "已保存")
                    }
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(model.storedAPIKey.isEmpty ? Theme.textSecondary : Theme.success)
                }
                HStack(alignment: .center, spacing: 8) {
                    SecureField("输入新 Key 可替换，留空保持不变", text: $model.settings.apiKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: SettingsMetrics.labelSize))
                        .padding(9)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
                    Button {
                        Task { await model.testModel() }
                    } label: {
                        HStack(spacing: 5) {
                            if model.isTestingModel {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "bolt.horizontal.circle")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            Text(model.isTestingModel ? "测试中…" : "测试连接")
                                .font(.system(size: SettingsMetrics.cardSubtitleSize, weight: .medium))
                        }
                        .foregroundStyle(canTestConnection ? Theme.accent : Theme.textSecondary.opacity(0.55))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            canTestConnection ? Theme.accent.opacity(0.12) : Color.white.opacity(0.03),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    canTestConnection ? Theme.accent.opacity(0.45) : Theme.panelBorder,
                                    lineWidth: 0.8
                                )
                        )
                    }
                    .buttonStyle(.pressable)
                    .disabled(model.isTestingModel || !canTestConnection)
                    .help("用当前 Key（新填或已保存）对预填 Base URL 与所选模型发一次最小请求")
                }
                if let result = model.testResult {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: result.hasPrefix("连接成功") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: SettingsMetrics.captionSize))
                            .foregroundStyle(result.hasPrefix("连接成功") ? Theme.success : Color.red.opacity(0.85))
                        Text(result)
                            .font(.system(size: SettingsMetrics.captionSize))
                            .foregroundStyle(result.hasPrefix("连接成功") ? Theme.success : Color.red.opacity(0.85))
                            .textSelection(.enabled)
                    }
                } else {
                    Text("已保存的密钥不会回填。填 Key 后可点「测试连接」验证，无需先保存。")
                        .font(.system(size: SettingsMetrics.captionSize))
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("对话模型")
                    .font(.system(size: SettingsMetrics.labelSize))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    ForEach(DeepSeekModelOption.catalog) { option in
                        ModelPickChip(
                            title: option.title,
                            blurb: option.blurb,
                            selected: model.settings.model == option.id
                        ) {
                            model.settings.model = option.id
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("思考强度")
                    .font(.system(size: SettingsMetrics.labelSize))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    ForEach(ThinkingIntensity.allCases) { level in
                        IntensityChip(
                            label: level.label,
                            selected: ThinkingIntensity.from(connection: model.settings) == level
                        ) {
                            level.apply(to: &model.settings)
                        }
                    }
                }
                Text("写入 DeepSeek thinking + reasoning_effort（低=low / 中=high / 高=max）；思考模式下温度无效。")
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

    private var comingSoonCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(selectedProvider.title) 即将支持")
                .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
            Text("本版先把 DeepSeek 接完整。点上方 DeepSeek 即可配置 API Key 与模型。")
                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                .foregroundStyle(Theme.textSecondary)
            Button("改用 DeepSeek") {
                selectProvider(.deepseek)
            }
            .buttonStyle(.pressable)
            .font(.system(size: SettingsMetrics.cardSubtitleSize))
            .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

    // MARK: - Routes

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
                Text("保存连接后会出现在这里。")
                    .font(.system(size: SettingsMetrics.cardSubtitleSize))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(Array(savedRoutes.enumerated()), id: \.offset) { _, route in
                    ModelRouteRow(route: route) { title in
                        let record = route["record"]
                        if let base = record?["baseURL"]?.stringValue {
                            model.settings.baseURL = base
                            selectedProvider = ModelProviderID.infer(from: base)
                        }
                        if let m = record?["model"]?.stringValue { model.settings.model = m }
                        if let temp = record?["temperature"]?.doubleValue { model.settings.temperature = temp }
                        if let name = record?["displayName"]?.stringValue { model.settings.displayName = name }
                        if let thinking = record?["thinkingEnabled"]?.boolValue {
                            model.settings.thinkingEnabled = thinking
                        }
                        if let effort = record?["reasoningEffort"]?.stringValue {
                            model.settings.reasoningEffort = ModelConnection.normalizedEffort(effort)
                        }
                        if selectedProvider == .deepseek {
                            applyDeepSeekDefaults(preserveModel: true)
                        }
                        savedNote = "已填入 \(title)，确认 Key 后点保存"
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        HStack {
            Text(savedNote)
                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button {
                guard selectedProvider.isAvailable else {
                    savedNote = "请先选择已接入的厂商（DeepSeek）"
                    return
                }
                applyDeepSeekDefaults(preserveModel: true)
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
                    .background(
                        selectedProvider.isAvailable ? Theme.accent : Theme.accent.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
            }
            .buttonStyle(.pressable)
            .disabled(!selectedProvider.isAvailable)
        }
        .padding(.horizontal, SettingsMetrics.pagePadding)
        .padding(.vertical, 12)
        .background(Theme.panel.opacity(0.5))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.panelBorder).frame(height: 0.8)
        }
    }

    private var providerLabel: String {
        if !model.settings.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            return model.settings.displayName
        }
        return ModelProviderID.infer(from: model.settings.baseURL).title
    }

    /// New draft key or already-saved key + model + base URL.
    private var canTestConnection: Bool {
        let key = model.settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasKey = !key.isEmpty || !model.storedAPIKey.isEmpty
        let hasModel = !model.settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasURL = !model.settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasKey && hasModel && hasURL
    }
}

// MARK: - Chips

private struct ProviderChip: View {
    let provider: ModelProviderID
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: provider.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                    }
                }
                Text(provider.title)
                    .font(.system(size: SettingsMetrics.bodySize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(provider.subtitle)
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(provider.isAvailable ? Theme.accent.opacity(0.9) : Theme.textSecondary.opacity(0.75))
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .background(
                selected ? Theme.accent.opacity(0.10) : Color.white.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Theme.accent.opacity(0.55) : Theme.panelBorder, lineWidth: selected ? 1.2 : 0.7)
            )
            .opacity(provider.isAvailable || selected ? 1 : 0.72)
        }
        .buttonStyle(.pressable)
    }
}

private struct ModelPickChip: View {
    let title: String
    let blurb: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: SettingsMetrics.bodySize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(blurb)
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Theme.accent.opacity(0.12) : Color.white.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Theme.accent.opacity(0.5) : Theme.panelBorder, lineWidth: 0.8)
            )
        }
        .buttonStyle(.pressable)
    }
}

private struct IntensityChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: SettingsMetrics.bodySize, weight: .medium))
                .foregroundStyle(selected ? Color.black.opacity(0.85) : Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    selected ? Theme.accent : Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? Color.clear : Theme.panelBorder, lineWidth: 0.7)
                )
        }
        .buttonStyle(.pressable)
    }
}

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
