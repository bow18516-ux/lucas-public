import AppKit
import SwiftUI

/// First-run wizard: welcome → connect a model → ready.
/// Shown only when no connection is stored and the user has not finished setup.
struct OnboardingView: View {
    @ObservedObject var model: AppModel

    private enum Step: Int, CaseIterable {
        case welcome, connect, done
    }

    private enum Status {
        case testing
        case success(String)
        case failure(String)
    }

    @State private var step: Step
    @State private var status: Status?
    @State private var isSaving = false
    @State private var isRefreshingModels = false
    @State private var modelListHint: String?

    init(model: AppModel) {
        self.model = model
        switch ProcessInfo.processInfo.environment["LUCAS_ONBOARDING_STEP"] {
        case "connect": _step = State(initialValue: .connect)
        case "done": _step = State(initialValue: .done)
        default: _step = State(initialValue: .welcome)
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.58).ignoresSafeArea()
            card
                .frame(width: 560)
        }
        .onAppear(perform: autotestIfRequested)
    }

    private func applyPresetIfRequested() {
        guard
            step == .connect,
            let provider = ProcessInfo.processInfo.environment["LUCAS_ONBOARDING_PROVIDER"],
            !provider.isEmpty
        else { return }
        applyProvider(provider)
    }

    private func autotestIfRequested() {
        applyPresetIfRequested()
        guard
            ProcessInfo.processInfo.environment["LUCAS_ONBOARDING_AUTOTEST"] == "1",
            step == .connect
        else { return }
        applyProvider("Pollinations 测试")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            saveAndTest()
        }
    }

    // MARK: - Chrome

    private var card: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.panelBorder).frame(height: 0.8)
            Group {
                switch step {
                case .welcome: welcome
                case .connect: connect
                case .done: done
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.panelBorder, lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.5), radius: 44, y: 20)
    }

    private var header: some View {
        HStack(spacing: 12) {
            appIcon
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("Lucas Agent")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("第一次使用 · 三步完成设置")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Theme.accent : Color.white.opacity(0.12))
                        .frame(width: item == step ? 18 : 6, height: 6)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var appIcon: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
            .resizable()
            .interpolation(.high)
    }

    // MARK: - Step 1

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("欢迎使用 Lucas Agent")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("一个跑在你 Mac 上的桌面 Agent。先连接一个模型服务，就可以开始对话、执行命令、读写文件。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                feature("bubble.left.and.text.bubble.right", "对话", "流式回答")
                feature("wrench.and.screwdriver", "工具", "15 个系统能力")
                feature("waveform", "语音", "听写与播报")
                feature("arrow.triangle.2.circlepath", "更新", "自动升级")
            }

            VStack(alignment: .leading, spacing: 6) {
                bullet("API Key 只保存在这台 Mac 上，不会上传。")
                bullet("稍后也可以在设置里随时修改。")
            }
            .padding(.top, 2)

            HStack(spacing: 12) {
                Spacer()
                Button("稍后再说") { model.skipOnboarding() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                primaryButton("开始配置") { step = .connect }
            }
            .padding(.top, 4)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(Theme.textSecondary.opacity(0.6)).frame(width: 3, height: 3).padding(.top, 6)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Step 2

    private var connect: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("连接模型服务")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("支持任何 OpenAI 兼容接口。没有 Key 可以先选「Pollinations 测试」体验。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }

            field("服务商") {
                Menu {
                    ForEach(["DeepSeek", "MiMo", "Pollinations 测试", "自定义"], id: \.self) { item in
                        Button(item) { applyProvider(item) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(providerName)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }

            field("Base URL") {
                TextField("https://api.deepseek.com/v1", text: $model.settings.baseURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(9)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
            }

            field("API Key") {
                SecureField("sk-…", text: $model.settings.apiKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(9)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
            }

            field("模型") {
                HStack(spacing: 8) {
                    TextField("deepseek-chat", text: $model.settings.model)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(9)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))

                    Menu {
                        if model.availableModels.isEmpty {
                            Text(isRefreshingModels ? "正在加载模型…" : "暂无模型，先刷新")
                        } else {
                            ForEach(model.availableModels, id: \.self) { id in
                                Button {
                                    model.settings.model = id
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
                            Task { await refreshModelList() }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("选择模型")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8))
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Button {
                        Task { await refreshModelList() }
                    } label: {
                        if isRefreshingModels {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("刷新")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if let modelListHint {
                Text(modelListHint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
            } else if !model.availableModels.isEmpty {
                Text("已加载 \(model.availableModels.count) 个模型，可从「选择」里挑一个")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
            }

            statusLine

            HStack(spacing: 12) {
                Button("上一步") { step = .welcome }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)

                if case .failure = status {
                    Button("跳过测试，直接使用") {
                        if model.hasStoredConnection { step = .done }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent.opacity(0.9))
                }

                Spacer()

                if isSaving {
                    ProgressView().controlSize(.small)
                }

                primaryButton(model.hasStoredConnection ? "保存更改" : "保存并测试") {
                    saveAndTest()
                }
            }
        }
        .task { await refreshModelListIfNeeded() }
    }

    private func refreshModelListIfNeeded() async {
        guard model.availableModels.isEmpty, !isRefreshingModels else { return }
        await refreshModelList()
    }

    private func refreshModelList() async {
        guard !isRefreshingModels else { return }
        isRefreshingModels = true
        modelListHint = nil
        await model.refreshModels()
        if model.availableModels.isEmpty {
            modelListHint = "没有取到模型列表：检查 Base URL 和 Key，或直接手动填写模型 ID"
        } else {
            if model.settings.model.isEmpty, let first = model.availableModels.first {
                model.settings.model = first
            }
            modelListHint = nil
        }
        isRefreshingModels = false
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("正在测试连接…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.success)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.95, green: 0.55, blue: 0.45))
                .fixedSize(horizontal: false, vertical: true)
        case .none:
            EmptyView()
        }
    }

    // MARK: - Step 3

    private var done: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Theme.success.opacity(0.14)).frame(width: 64, height: 64)
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.success)
            }

            VStack(spacing: 6) {
                Text("配置完成")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("现在可以直接开始对话了。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(spacing: 8) {
                summaryRow("服务", providerName)
                summaryRow("模型", model.settings.model.isEmpty ? "—" : model.settings.model)
                summaryRow("地址", model.settings.baseURL)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.panelBorder, lineWidth: 0.7))

            primaryButton("开始使用") {
                UserDefaults.standard.set(true, forKey: AppModel.onboardingCompletedKey)
                model.onboardingPresented = false
                Task { await model.loadSettings() }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 36, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Actions

    private func saveAndTest() {
        guard !isSaving else { return }
        isSaving = true
        status = .testing
        Task {
            let saved = await model.saveSettings()
            guard saved else {
                status = .failure(model.errorText ?? "保存失败")
                isSaving = false
                return
            }
            await model.testModel()
            let result = model.testResult ?? "未知结果"
            if result.hasPrefix("连接成功") {
                status = .success(result)
                step = .done
            } else {
                status = .failure(result)
            }
            isSaving = false
        }
    }

    private var providerName: String {
        let url = model.settings.baseURL.lowercased()
        if url.contains("deepseek") { return "DeepSeek" }
        if url.contains("xiaomimimo") { return "MiMo" }
        if url.contains("pollinations") { return "Pollinations 测试" }
        return "自定义"
    }

    private func applyProvider(_ name: String) {
        switch name {
        case "DeepSeek":
            model.settings.baseURL = "https://api.deepseek.com/v1"
            if model.settings.model.isEmpty { model.settings.model = "deepseek-chat" }
        case "MiMo":
            model.settings.baseURL = "https://api.xiaomimimo.com/v1"
            if model.settings.model.isEmpty { model.settings.model = "mimo-v2.5" }
        case "Pollinations 测试":
            model.settings.baseURL = "https://text.pollinations.ai/openai"
            model.settings.model = "openai"
            if model.settings.apiKey.isEmpty && model.storedAPIKey.isEmpty {
                model.settings.apiKey = "anonymous"
            }
        default:
            break
        }
    }

    // MARK: - Controls

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.88))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}
