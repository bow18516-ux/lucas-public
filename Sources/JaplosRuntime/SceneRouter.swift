import Foundation

public struct Scene: Sendable {
    public var id: String
    public var name: String
    public var pattern: String
    public var extraPrompt: String
    public var tools: [String]
    public var promptFiles: [String]
    public var enabled: Bool

    public init(
        id: String,
        name: String,
        pattern: String,
        extraPrompt: String,
        tools: [String],
        promptFiles: [String] = [],
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.extraPrompt = extraPrompt
        self.tools = tools
        self.promptFiles = promptFiles
        self.enabled = enabled
    }
}

/// File-driven scene injection. Loads `Injection/scenes.json` (Japlos schemaVersion 1)
/// from the bundle, with Application Support override, then falls back to a small built-in list.
public enum SceneRouter {
    private struct FileRoot: Decodable {
        var schemaVersion: Int?
        var scenes: [FileScene]
    }

    private struct FileScene: Decodable {
        var id: String
        var name: String
        var pattern: String
        var enabled: Bool?
        var responsePrompt: String?
        var tools: [String]?
        var promptFiles: [String]?
    }

    private static let cacheLock = NSLock()
    private static var cachedScenes: [Scene]?
    private static var cachedToken: String?

    public static var scenes: [Scene] {
        let token = scenesCacheToken()
        cacheLock.lock()
        if cachedToken == token, let cachedScenes {
            cacheLock.unlock()
            return cachedScenes
        }
        cacheLock.unlock()
        let loaded = loadFromDisk()
        let value = (loaded?.isEmpty == false) ? loaded! : builtInScenes
        cacheLock.lock()
        cachedScenes = value
        cachedToken = token
        cacheLock.unlock()
        return value
    }

    private static func scenesCacheToken() -> String {
        let url = scenesFileOverrideURL()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        return "\(modified)|\(size)"
    }

    public static func match(_ text: String) -> Scene? {
        for scene in scenes where scene.enabled {
            guard let regex = try? NSRegularExpression(pattern: scene.pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if regex.firstMatch(in: text, range: range) != nil {
                return scene
            }
        }
        return nil
    }

    public static func scenesFileOverrideURL() -> URL {
        PromptLibrary.supportRoot()
            .appendingPathComponent("Injection/scenes.json", isDirectory: false)
    }

    @discardableResult
    public static func seedScenesIfNeeded() -> Bool {
        let dest = scenesFileOverrideURL()
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { return false }
        guard let source = bundledScenesURL() else { return false }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: dest)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Loading

    private static func decodeScenes(_ data: Data) -> [Scene]? {
        guard let root = try? JSONDecoder().decode(FileRoot.self, from: data) else { return nil }
        let mapped = root.scenes.map { item in
            Scene(
                id: item.id,
                name: item.name,
                pattern: item.pattern,
                extraPrompt: item.responsePrompt ?? "",
                tools: item.tools ?? [],
                promptFiles: item.promptFiles ?? [],
                enabled: item.enabled ?? true
            )
        }
        return mapped.isEmpty ? nil : mapped
    }

    private static func loadFromDisk() -> [Scene]? {
        if let text = SeededOverride.text(
            override: scenesFileOverrideURL(),
            bundled: bundledScenesURL(),
            relativePath: "Injection/scenes.json"
        ),
           let data = text.data(using: .utf8),
           let mapped = decodeScenes(data) {
            return mapped
        }
        let candidates = [bundledScenesURL()].compactMap { $0 }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let mapped = decodeScenes(data) else {
                continue
            }
            return mapped
        }
        return nil
    }

    private static func bundledScenesURL() -> URL? {
        if let url = Bundle.module.url(forResource: "scenes", withExtension: "json", subdirectory: "Injection") {
            return url
        }
        if let url = Bundle.module.resourceURL?
            .appendingPathComponent("Injection/scenes.json", isDirectory: false),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let url = Bundle.main.resourceURL?
            .appendingPathComponent("Injection/scenes.json", isDirectory: false),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    /// Last-resort scenes if JSON is missing (keep product usable).
    private static let builtInScenes: [Scene] = [
        Scene(
            id: "music",
            name: "播放音乐",
            pattern: "播放|音乐|歌曲|来一首|下一首|上一首|暂停|music|song",
            extraPrompt: "音乐操作优先使用 system.music。",
            tools: ["system.music"],
            promptFiles: ["tools/music.md"]
        ),
        Scene(
            id: "screenshot",
            name: "截屏",
            pattern: "截图|截屏|screenshot|screencapture|屏幕截图|截个图|截一下屏",
            extraPrompt: "截屏使用 system.screen.capture；成功后把保存路径告诉用户。不要把桌面文件操作当成截屏。",
            tools: ["system.screen.capture"]
        ),
        Scene(
            id: "filesystem",
            name: "文件操作",
            pattern: "文件|目录|文件夹|读取|写入|保存到|桌面.{0,8}文件|文件.{0,8}桌面|读一下|存到|file|folder|directory",
            extraPrompt: "文件操作使用 system.filesystem；写入前确认路径。",
            tools: ["system.filesystem", "system.command.shell.execute"]
        ),
        Scene(
            id: "application",
            name: "打开应用",
            pattern: "打开|启动|关闭|退出",
            extraPrompt: "打开或退出应用时使用 system.application。",
            tools: ["system.application"],
            promptFiles: ["tools/software.md"]
        ),
    ]
}
