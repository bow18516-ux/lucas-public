import AppKit
import JaplosProtocol
import SwiftUI

@main
struct LucasMain {
    static func main() {
        AppLog.write("main() entered pid=\(ProcessInfo.processInfo.processIdentifier)")
        atexit {
            AppLog.write("atexit")
        }
        AppDelegate.installCrashHandlers()
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: AppModel?
    private var updates: UpdateService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.write("applicationDidFinishLaunching pid=\(ProcessInfo.processInfo.processIdentifier)")

        if let snapshotPath = ProcessInfo.processInfo.environment["LUCAS_SNAPSHOT"] {
            Task { @MainActor in
                renderSnapshot(to: snapshotPath)
                NSApp.terminate(nil)
            }
            return
        }

        let model = AppModel()
        self.model = model

        let root = CoreSurfaceView(model: model)
            .preferredColorScheme(.dark)
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = "Lucas Agent"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = Theme.backgroundNSColor
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 1120, height: 700)
        var initialSize = NSSize(width: 1400, height: 875)
        if let raw = ProcessInfo.processInfo.environment["LUCAS_WINDOW_SIZE"] {
            let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2, parts[0] >= 800, parts[1] >= 600 {
                initialSize = NSSize(width: parts[0], height: parts[1])
            }
        }
        window.setContentSize(initialSize)
        window.center()
        window.setFrameAutosaveName("")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        NSWindow.allowsAutomaticWindowTabbing = false
        window.makeKeyAndOrderFront(nil)
        self.window = window

        buildMainMenu()
        // Keep the app alive even when the window is closed or the app is idle.
        ProcessInfo.processInfo.disableAutomaticTermination("Lucas Agent keeps a local kernel session")
        ProcessInfo.processInfo.disableSuddenTermination()

        // Sparkle needs a real bundle with SUFeedURL; running the raw debug
        // binary would otherwise show a modal error before the UI appears.
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            updates = UpdateService.shared
            Task { await UpdateService.shared.refreshFeed() }
        }
        if ProcessInfo.processInfo.environment["LUCAS_CHECK_UPDATES_ON_LAUNCH"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.updates?.checkForUpdates()
            }
        }
        // Enforce the initial size once, even if macOS restored an old frame.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            if abs(window.frame.width - initialSize.width) > 1 || abs(window.frame.height - initialSize.height) > 1 {
                window.setContentSize(initialSize)
                window.center()
            }
        }

        NSApp.activate(ignoringOtherApps: true)

        if ProcessInfo.processInfo.environment["LUCAS_OPEN_SETTINGS"] == "1" {
            model.settingsPresented = true
        }

        AppLog.write("didFinishLaunching visible=\(window.isVisible) frame=\(NSStringFromRect(window.frame))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak window] in
            AppLog.write("heartbeat visible=\(window?.isVisible ?? false) occluded=\(window?.occlusionState.contains(.visible) ?? false)")
        }

        if ProcessInfo.processInfo.environment["LUCAS_AUTOCLOSE_TEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak window] in
                window?.close()
            }
        }

        Task { await model.bootstrap() }

        // If anything closed the window during restoration, bring it back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak window] in
            if window?.isVisible != true {
                window?.makeKeyAndOrderFront(nil)
            }
        }

        if let capturePath = ProcessInfo.processInfo.environment["LUCAS_WINDOW_CAPTURE"] {
            let delay = Double(ProcessInfo.processInfo.environment["LUCAS_CAPTURE_DELAY"] ?? "") ?? 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                guard let view = window?.contentView else { return }
                let bounds = view.bounds
                guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
                view.cacheDisplay(in: bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: capturePath))
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// Renders the main surface offscreen so UI changes can be reviewed without
    /// a screen-recording permission.
    @MainActor
    private func renderSnapshot(to path: String) {
        let model = AppModel()
        model.connected = true
        model.settings = ModelConnection(
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-flash",
            apiKey: "sk-preview",
            temperature: 0.3
        )
        model.tools = [
            .init(name: "system.application", title: "应用程序", risk: "medium"),
            .init(name: "system.command.shell.execute", title: "执行 Shell 命令", risk: "high"),
            .init(name: "system.filesystem", title: "文件读写", risk: "medium"),
            .init(name: "system.screen.capture", title: "截屏", risk: "medium"),
            .init(name: "system.music", title: "音乐播放", risk: "low"),
            .init(name: "system.time", title: "当前时间", risk: "low"),
        ]
        model.messages = [
            AppModel.Message(role: "user", text: "雪人股份 002639 今日股价 实时行情"),
            AppModel.Message(
                role: "assistant",
                text: """
                这是 **雪人股份（002639）** 的实时行情入口：

                - 东方财富行情页：https://quote.eastmoney.com/sz002639.html
                - 第一财经快讯：https://www.yicai.com/brief/103414546.html

                注：今天是收盘前最后几分钟，具体收盘价以交易软件为准；基本面上前三季度归母净利润仍为亏损。
                """,
                steps: [
                    AppModel.ToolStep(name: "system.command.shell.execute", ok: true, detail: "curl quote.eastmoney.com"),
                    AppModel.ToolStep(name: "system.filesystem", ok: true, detail: "sz002639.html"),
                ]
            ),
        ]
        let view = CoreSurfaceView(model: model)
            .frame(width: 1440, height: 900)
            .preferredColorScheme(.dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard
            let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            AppLog.write("snapshot failed to render")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        AppLog.write("snapshot written to \(path)")
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Lucas Agent", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Lucas Agent", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "u")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Lucas Agent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let conversationMenuItem = NSMenuItem()
        mainMenu.addItem(conversationMenuItem)
        let conversationMenu = NSMenu(title: "对话")
        conversationMenu.addItem(withTitle: "新建对话", action: #selector(newConversation), keyEquivalent: "n")
        conversationMenuItem.submenu = conversationMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "帮助")
        helpMenu.addItem(withTitle: "重新显示新手引导", action: #selector(showOnboarding), keyEquivalent: "")
        helpMenuItem.submenu = helpMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "0")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let snapshotItem = windowMenu.addItem(withTitle: "保存界面快照", action: #selector(saveWindowSnapshot), keyEquivalent: "s")
        snapshotItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showMainWindow() {
        window?.makeKeyAndOrderFront(nil)
    }

    @MainActor @objc private func showOnboarding() {
        model?.resetOnboarding()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor @objc private func saveWindowSnapshot() {
        guard let view = window?.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/Lucas-window.png")
        do {
            try png.write(to: url)
            AppLog.write("window snapshot saved to \(url.path)")
        } catch {
            AppLog.write("snapshot failed: \(error)")
        }
    }

    @MainActor @objc private func checkForUpdates() {
        UpdateService.shared.checkForUpdates()
    }

    @objc private func newConversation() {
        Task { @MainActor in
            await model?.createSession()
        }
    }

    /// Records abnormal exits to /tmp so a launch failure leaves evidence even
    /// when the system does not write a crash report.
    fileprivate static func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            AppLog.write("UNCAUGHT \(exception.name.rawValue): \(exception.reason ?? "")")
        }
        let handler: @convention(c) (Int32) -> Void = { signalNumber in
            let path = "/tmp/lucas-crash.log"
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            if fd >= 0 {
                let line = "signal \(signalNumber) pid \(getpid())\n"
                _ = line.withCString { write(fd, $0, strlen($0)) }
                close(fd)
            }
            signal(signalNumber, SIG_DFL)
            raise(signalNumber)
        }
        signal(SIGABRT, handler)
        signal(SIGSEGV, handler)
        signal(SIGBUS, handler)
        signal(SIGILL, handler)
        signal(SIGFPE, handler)
        signal(SIGTRAP, handler)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if window?.isVisible != true {
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLog.write("applicationShouldTerminate")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.write("applicationWillTerminate")
    }
}
