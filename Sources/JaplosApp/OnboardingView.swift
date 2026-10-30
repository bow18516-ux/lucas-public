import AppKit
import ApplicationServices
import AVFoundation
import Speech
import SwiftUI

/// First-run wizard: welcome → risk → permissions → connect → done.
/// Prefs mirror Japlos awakening/onboarding keys under `lucas.*`.
struct OnboardingView: View {
    @ObservedObject var model: AppModel

    private enum Step: Int, CaseIterable {
        case welcome, risk, permissions, connect, done
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
    @State private var riskChecked = OnboardingPrefs.riskAccepted
    @State private var selectedTone = OnboardingPrefs.tone
    @State private var micAuthorized = false
    @State private var speechAuthorized = false
    @State private var accessibilityTrusted = false
    @State private var tonePlayer: AVAudioPlayer?

    init(model: AppModel) {
        self.model = model
        switch ProcessInfo.processInfo.environment["LUCAS_ONBOARDING_STEP"] {
        case "risk": _step = State(initialValue: .risk)
        case "permissions": _step = State(initialValue: .permissions)
        case "connect": _step = State(initialValue: .connect)
        case "done": _step = State(initialValue: .done)
        default: _step = State(initialValue: .welcome)
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.58).ignoresSafeArea()
            card
                .frame(width: 580)
        }
        .onAppear {
            UserDefaults.standard.set(true, forKey: OnboardingPrefs.awakeningInFlightKey)
            refreshPermissionFlags()
            autotestIfRequested()
        }
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
                case .risk: risk
                case .permissions: permissions
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
                Text("第一次使用 · \(stepCaption)")
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

    private var stepCaption: String {
        switch step {
        case .welcome: return "欢迎"
        case .risk: return "风险说明"
        case .permissions: return "系统权限"
        case .connect: return "连接模型"
        case .done: return "完成"
        }
    }

    private var appIcon: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
            .resizable()
            .interpolation(.high)
    }

    // MARK: - Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("欢迎使用 Lucas Agent")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("跑在你 Mac 上的桌面 Agent。接下来会过一遍风险说明、系统权限，再连接模型服务。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                feature("bubble.left.and.text.bubble.right", "对话", "流式回答")
                feature("wrench.and.screwdriver", "工具", "系统能力")
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
                Button("稍后再说") {
                    OnboardingPrefs.markSkipped()
                    model.skipOnboarding()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                primaryButton("开始配置") {
                    OnboardingPrefs.activationDone = true
                    OnboardingPrefs.nextStage = max(OnboardingPrefs.nextStage, 1)
                    step = .risk
                }
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

    // MARK: - Risk

    private var risk: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("使用前请了解")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Lucas 可以在你授权后读写文件、执行命令、访问网络。请确认你理解这些能力。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                riskRow("工具默认需你确认高风险操作（删文件、改系统等）。")
                riskRow("模型回答可能出错；重要操作请先核对。")
                riskRow("密钥与对话存在本机；卸载前请自行备份需要保留的内容。")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.panelBorder, lineWidth: 0.7))

            Toggle(isOn: $riskChecked) {
                Text("我已阅读并接受上述风险说明")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
            }
            .toggleStyle(.checkbox)

            HStack(spacing: 12) {
                Button("上一步") { step = .welcome }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                primaryButton("继续") {
                    guard riskChecked else { return }
                    OnboardingPrefs.riskAccepted = true
                    OnboardingPrefs.nextStage = max(OnboardingPrefs.nextStage, 2)
                    step = .permissions
                }
                .opacity(riskChecked ? 1 : 0.45)
                .disabled(!riskChecked)
            }
        }
    }

    private func riskRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Permissions

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("系统权限")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("语音听写需要麦克风与语音识别；完整桌面操控可能需要辅助功能。均可稍后在系统设置里改。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                permissionRow(
                    title: "麦克风",
                    detail: micAuthorized ? "已授权" : "未授权 · 语音输入需要",
                    ok: micAuthorized
                ) {
                    Task { await requestMic() }
                }
                permissionRow(
                    title: "语音识别",
                    detail: speechAuthorized ? "已授权" : "未授权 · 听写需要",
                    ok: speechAuthorized
                ) {
                    Task { await requestSpeech() }
                }
                permissionRow(
                    title: "辅助功能",
                    detail: accessibilityTrusted ? "已信任" : "未信任 · 可选，用于更深系统操作",
                    ok: accessibilityTrusted
                ) {
                    openAccessibilityPane()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("引导音效")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    ForEach(OnboardingPrefs.tones, id: \.self) { name in
                        Button {
                            selectedTone = name
                            OnboardingPrefs.tone = name
                            playTone(name)
                        } label: {
                            Text(name)
                                .font(.system(size: 11, weight: selectedTone == name ? .semibold : .regular))
                                .foregroundStyle(selectedTone == name ? Color.black.opacity(0.88) : Theme.textPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    selectedTone == name ? Theme.accent : Color.white.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 4)

            HStack(spacing: 12) {
                Button("上一步") { step = .risk }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("跳过权限") {
                    finishPermissions(skipped: true)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent.opacity(0.9))
                primaryButton("继续") {
                    finishPermissions(skipped: false)
                }
            }
        }
        .onAppear(perform: refreshPermissionFlags)
    }

    private func permissionRow(
        title: String,
        detail: String,
        ok: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Theme.success : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button(ok ? "已就绪" : "授权") { action() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(ok ? Theme.textSecondary : Theme.accent)
                .disabled(ok)
        }
        .padding(10)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
    }

    private func finishPermissions(skipped: Bool) {
        OnboardingPrefs.tone = selectedTone
        OnboardingPrefs.macOSBranchDone = true
        OnboardingPrefs.explorationDone = true
        OnboardingPrefs.nextStage = max(OnboardingPrefs.nextStage, skipped ? 3 : 4)
        step = .connect
    }

    private func refreshPermissionFlags() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micAuthorized = true
        default: micAuthorized = false
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speechAuthorized = true
        default: speechAuthorized = false
        }
        accessibilityTrusted = AXIsProcessTrusted()
    }

    private func requestMic() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        await MainActor.run {
            micAuthorized = granted
            refreshPermissionFlags()
        }
    }

    private func requestSpeech() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in
                cont.resume()
            }
        }
        await MainActor.run { refreshPermissionFlags() }
    }

    private func openAccessibilityPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            refreshPermissionFlags()
        }
    }

    private func playTone(_ name: String) {
        let url =
            Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Awakening")
            ?? Bundle.main.url(forResource: name, withExtension: "wav")
        guard let url else { return }
        do {
            tonePlayer = try AVAudioPlayer(contentsOf: url)
            tonePlayer?.prepareToPlay()
            tonePlayer?.play()
        } catch {
            // Preview is optional; ignore missing assets in debug.
        }
    }

    // MARK: - Connect

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
                Button("上一步") { step = .permissions }
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

    // MARK: - Done

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
                summaryRow("音效", OnboardingPrefs.tone)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.panelBorder, lineWidth: 0.7))

            primaryButton("开始使用") {
                OnboardingPrefs.markCompleted(sequence: 1)
                OnboardingPrefs.encounterDone = true
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
                OnboardingPrefs.encounterDone = true
                OnboardingPrefs.nextStage = max(OnboardingPrefs.nextStage, 5)
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
