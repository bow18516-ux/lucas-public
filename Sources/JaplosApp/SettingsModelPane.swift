import AppKit
import SwiftUI
import UniformTypeIdentifiers
import JaplosProtocol
import JaplosClient

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
