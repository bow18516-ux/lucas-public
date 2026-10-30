import AppKit
import Foundation
import JaplosProtocol

// MARK: - Time

public struct TimeTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.time",
            title: "当前时间",
            summary: "读取本机当前日期、时间与时区。回答与时间相关的问题前先调用。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "additionalProperties": false,
            ]),
            capability: Capability.root,
            risk: .low,
            approval: .never
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current
        return .object([
            "iso8601": .string(ISO8601.string(from: now)),
            "local": .string(formatter.string(from: now)),
            "timeZone": .string(TimeZone.current.identifier),
            "epochSeconds": .number(now.timeIntervalSince1970.rounded()),
        ])
    }
}

// MARK: - Shell

public struct ShellTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.command.shell.execute",
            title: "执行 Shell 命令",
            summary: "以当前用户身份用 /bin/zsh -lc 执行命令并返回 stdout/stderr/退出码。危险模式词表只是提示，不能代替审批；确认卡会显示完整命令和工作目录。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "command": .object(["type": "string", "description": "要执行的命令"]),
                    "timeoutSeconds": .object(["type": "number", "minimum": 1, "maximum": 120]),
                    "workingDirectory": .object(["type": "string"]),
                ]),
                "required": .array(["command"]),
                "additionalProperties": false,
            ]),
            capability: Capability.processExecute,
            risk: .high
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        guard let command = arguments["command"]?.stringValue, !command.isEmpty else {
            throw ToolError.invalidArguments("command is required")
        }
        if let reason = DangerousCommand.blockReason(for: command) {
            throw ToolError.denied("命令命中灾难性模式，已拒绝：\(reason)。审批不能放行这一小类命令。")
        }
        let timeout = min(max(arguments["timeoutSeconds"]?.doubleValue ?? 30, 1), 120)
        // Trust-root policy: cwd must be inside allowed roots (default = home).
        // Literal path tokens outside those roots are refused. This is not a sandbox.
        let workingDirectory = arguments["workingDirectory"]?.stringValue
        let cwdURL = try TrustRoots.allowedURL(path: workingDirectory ?? NSHomeDirectory())
        if let pathReason = TrustRoots.blockedAbsolutePaths(inShellCommand: command) {
            throw ToolError.denied(pathReason)
        }

        // Own process group: a timed-out command takes its background children
        // with it, and a child that holds the pipe after the shell exits can no
        // longer keep this call waiting for an EOF that never comes.
        let child = try ProcessGroup.spawn(
            executable: "/bin/zsh",
            arguments: ["-lc", command],
            workingDirectory: cwdURL
        )
        let watcher = ProcessGroup.ExitWatcher(pid: child.pid)
        let limit = 32 * 1024
        let bucket = ProcessPipes.Bucket(limit: limit)
        let readers = ProcessPipes.ReaderSet(
            stdout: child.stdout,
            stderr: child.stderr,
            bucket: bucket
        )
        readers.start()

        var timedOut = false
        var cancelled = false
        var status: Int32?
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let exit = watcher.poll() {
                status = exit
                break
            }
            if Task.isCancelled {
                cancelled = true
                break
            }
            if Date() >= deadline {
                timedOut = true
                break
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        if status == nil {
            status = await ProcessGroup.terminate(child.pid, watcher: watcher)
        }
        let captured = await ProcessPipes.finish(readers: readers, bucket: bucket)
        if cancelled {
            throw CancellationError()
        }

        let outText = String(decoding: captured.stdout, as: UTF8.self)
        let errText = String(decoding: captured.stderr, as: UTF8.self)

        return .object([
            "exitCode": .number(Double(status ?? -1)),
            "stdout": .string(outText),
            "stderr": .string(errText),
            "timedOut": .bool(timedOut),
            "truncated": .bool(captured.truncated),
            "detachedBackground": .bool(captured.detachedBackground),
        ])
    }
}

// MARK: - Applications

public struct ApplicationTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.application",
            title: "应用程序",
            summary: "列出、启动或退出本机应用。action=list 列出已安装应用；action=open 用 name 或 path 启动；action=quit 按名称退出。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "action": .object(["type": "string", "enum": .array(["list", "open", "quit"])]),
                    "name": .object(["type": "string", "description": "应用名、Bundle ID 或 .app 绝对路径"]),
                ]),
                "required": .array(["action"]),
                "additionalProperties": false,
            ]),
            capability: Capability.applicationsControl,
            risk: .medium,
            approval: .whenArgument(key: "action", isOneOf: ["open", "quit"])
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        guard let action = arguments["action"]?.stringValue else {
            throw ToolError.invalidArguments("action is required")
        }
        switch action {
        case "list":
            return .object(["applications": .array(Self.installedApplications().map { app in
                .object(["name": .string(app.name), "path": .string(app.path), "bundleID": .string(app.bundleID)])
            })])
        case "open":
            guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
                throw ToolError.invalidArguments("name is required for open")
            }
            let url = try resolveApplication(named: name)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let running = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSRunningApplication, Error>) in
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                    if let error {
                        continuation.resume(throwing: ToolError.failed("open failed: \(error.localizedDescription)"))
                    } else if let app {
                        continuation.resume(returning: app)
                    } else {
                        continuation.resume(throwing: ToolError.failed("open returned no application"))
                    }
                }
            }
            return .object([
                "opened": .string(running.localizedName ?? name),
                "path": .string(url.path),
                "pid": .number(Double(running.processIdentifier)),
            ])
        case "quit":
            guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
                throw ToolError.invalidArguments("name is required for quit")
            }
            let matches = NSWorkspace.shared.runningApplications.filter { app in
                app.localizedName == name || app.bundleIdentifier == name
            }
            guard !matches.isEmpty else {
                throw ToolError.failed("No running application named \(name)")
            }
            var terminated: [String] = []
            for app in matches where app.terminate() {
                terminated.append(app.localizedName ?? name)
            }
            return .object(["terminated": .array(terminated.map(JSONValue.string))])
        default:
            throw ToolError.invalidArguments("Unknown action \(action)")
        }
    }

    private func resolveApplication(named name: String) throws -> URL {
        let expanded = (name as NSString).expandingTildeInPath
        if expanded.hasSuffix(".app"), FileManager.default.fileExists(atPath: expanded) {
            return URL(fileURLWithPath: expanded)
        }
        if name.contains("."), !name.contains(" ") {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
                return url
            }
        }
        if let url = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/Applications")) {
            _ = url
        }
        let target = name.lowercased()
        if let match = Self.installedApplications().first(where: {
            $0.name.lowercased() == target || $0.name.lowercased().contains(target)
        }) {
            return URL(fileURLWithPath: match.path)
        }
        throw ToolError.failed("Application not found: \(name)")
    }

    struct InstalledApp {
        var name: String
        var path: String
        var bundleID: String
    }

    static func installedApplications() -> [InstalledApp] {
        let roots = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
        ]
        var seen = Set<String>()
        var result: [InstalledApp] = []
        let fileManager = FileManager.default
        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries.sorted() where entry.hasSuffix(".app") {
                let path = (root as NSString).appendingPathComponent(entry)
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                let bundle = Bundle(path: path)
                let bundleID = bundle?.bundleIdentifier ?? ""
                let name = (entry as NSString).deletingPathExtension
                result.append(InstalledApp(name: name, path: path, bundleID: bundleID))
            }
        }
        return result
    }
}

/// Hard deny for credential and browser-profile paths. Approval cannot widen this.
public enum SensitivePaths {
    public static func reject(_ path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        let candidates = [
            URL(fileURLWithPath: expanded).standardizedFileURL.path,
            (expanded as NSString).resolvingSymlinksInPath,
        ]
        for candidate in candidates {
            if let reason = reason(for: candidate) {
                throw ToolError.denied(reason)
            }
        }
    }

    private static func reason(for path: String) -> String? {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let roots = [
            ".ssh",
            ".aws",
            ".gnupg",
            "Library/Keychains",
            "Library/Application Support/Lucas",
            "Library/Application Support/Google/Chrome",
            "Library/Application Support/Chromium",
            "Library/Application Support/Microsoft Edge",
            "Library/Application Support/BraveSoftware",
            "Library/Application Support/Arc",
            "Library/Application Support/Firefox",
            "Library/Safari",
            "Library/Cookies",
        ].map { (home as NSString).appendingPathComponent($0) }
        for root in roots {
            if path == root || path.hasPrefix(root + "/") {
                return "拒绝读取或写入敏感路径：\(root)"
            }
        }
        return nil
    }
}

// MARK: - Filesystem

public struct FilesystemTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.filesystem",
            title: "文件读写",
            summary: "读取/写入/列目录。只允许访问用户主目录、/tmp 与 /Users/Shared。action=read|write|list。~/.ssh、钥匙串、浏览器配置和 Lucas 数据目录会被拒绝。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "action": .object(["type": "string", "enum": .array(["read", "write", "list"])]),
                    "path": .object(["type": "string"]),
                    "content": .object(["type": "string"]),
                ]),
                "required": .array(["action", "path"]),
                "additionalProperties": false,
            ]),
            capability: Capability.filesystemWrite,
            risk: .medium,
            approval: .whenArgument(key: "action", isOneOf: ["write"])
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        guard
            let action = arguments["action"]?.stringValue,
            let rawPath = arguments["path"]?.stringValue
        else {
            throw ToolError.invalidArguments("action and path are required")
        }
        let url = try Self.allowedURL(path: rawPath)
        try SensitivePaths.reject(url.path)
        let fileManager = FileManager.default

        switch action {
        case "read":
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size <= 2 * 1024 * 1024 else {
                throw ToolError.failed("File is too large to read (\(size) bytes, limit 2 MB)")
            }
            let data = try Data(contentsOf: url)
            let text = String(decoding: data.prefix(256 * 1024), as: UTF8.self)
            return .object([
                "path": .string(url.path),
                "bytes": .number(Double(size)),
                "content": .string(text),
                "truncated": .bool(data.count > 256 * 1024),
            ])
        case "write":
            guard let content = arguments["content"]?.stringValue else {
                throw ToolError.invalidArguments("content is required for write")
            }
            let data = Data(content.utf8)
            guard data.count <= 2 * 1024 * 1024 else {
                throw ToolError.failed("Content exceeds 2 MB write limit")
            }
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return .object(["path": .string(url.path), "bytes": .number(Double(data.count))])
        case "list":
            let entries = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let items = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(300).map { entry -> JSONValue in
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                return .object([
                    "name": .string(entry.lastPathComponent),
                    "path": .string(entry.path),
                    "isDirectory": .bool(values?.isDirectory ?? false),
                    "bytes": .number(Double(values?.fileSize ?? 0)),
                    "modifiedAt": .string(values?.contentModificationDate.map(ISO8601.string(from:)) ?? ""),
                ])
            }
            return .object(["path": .string(url.path), "entries": .array(Array(items))])
        default:
            throw ToolError.invalidArguments("Unknown action \(action)")
        }
    }

    static func allowedRoots() -> [String] {
        TrustRoots.allowedRoots()
    }

    static func allowedURL(path: String) throws -> URL {
        try TrustRoots.allowedURL(path: path)
    }
}

// MARK: - Screenshot

public struct ScreenshotTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.screen.capture",
            title: "截屏",
            summary: "截取当前屏幕并保存为 PNG，返回文件路径。需要系统「屏幕录制」权限。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "path": .object(["type": "string", "description": "可选保存路径，默认保存在应用支持目录"]),
                ]),
                "additionalProperties": false,
            ]),
            capability: Capability.screenCapture,
            risk: .high
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        let capturesDirectory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lucas/Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)

        let path: String
        if let explicit = arguments["path"]?.stringValue, !explicit.isEmpty {
            path = try FilesystemTool.allowedURL(path: explicit).path
        } else {
            let stamp = ISO8601.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            path = capturesDirectory.appendingPathComponent("capture-\(stamp).png").path
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        let captured = await ProcessPipes.drain(
            process: process,
            stdout: nil,
            stderr: stderr.fileHandleForReading,
            limit: 64 * 1024
        )

        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: path) else {
            let message = String(decoding: captured.stderr, as: UTF8.self)
            throw ToolError.failed("screencapture failed (\(process.terminationStatus)): \(message)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        return .object(["path": .string(path), "bytes": .number(Double(size))])
    }
}

// MARK: - Clipboard

public struct ClipboardTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.clipboard",
            title: "剪贴板",
            summary: "读取或写入系统剪贴板。action=get|set|types。types 返回可用类型并检测是否含图片。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "action": .object(["type": "string", "enum": .array(["get", "set", "types"])]),
                    "text": .object(["type": "string"]),
                ]),
                "required": .array(["action"]),
                "additionalProperties": false,
            ]),
            capability: Capability.clipboardWrite,
            risk: .medium
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        guard let action = arguments["action"]?.stringValue else {
            throw ToolError.invalidArguments("action is required")
        }
        let pasteboard = NSPasteboard.general
        switch action {
        case "get":
            return .object([
                "text": .string(pasteboard.string(forType: .string) ?? ""),
                "hasImage": .bool(Self.pasteboardHasImage(pasteboard)),
            ])
        case "set":
            guard let text = arguments["text"]?.stringValue else {
                throw ToolError.invalidArguments("text is required for set")
            }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .object(["written": .number(Double(text.count))])
        case "types":
            let types = (pasteboard.types ?? []).map { JSONValue.string($0.rawValue) }
            return .object([
                "types": .array(types),
                "hasString": .bool(pasteboard.string(forType: .string) != nil),
                "hasImage": .bool(Self.pasteboardHasImage(pasteboard)),
            ])
        default:
            throw ToolError.invalidArguments("Unknown action \(action)")
        }
    }

    private static func pasteboardHasImage(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) { return true }
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .pdf]
        return imageTypes.contains { pasteboard.data(forType: $0) != nil }
    }
}

/// Shared filesystem / shell trust roots. Approval never widens these roots.
public enum TrustRoots {
    public static func allowedRoots() -> [String] {
        [
            NSHomeDirectory(),
            "/tmp",
            "/private/tmp",
            "/Users/Shared",
        ].map { (($0 as NSString).resolvingSymlinksInPath) }
    }

    public static func contains(path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = ((URL(fileURLWithPath: expanded).standardizedFileURL.path) as NSString)
            .resolvingSymlinksInPath
        return allowedRoots().contains { root in
            resolved == root || resolved.hasPrefix(root + "/")
        }
    }

    public static func allowedURL(path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let resolved = URL(fileURLWithPath: (url.path as NSString).resolvingSymlinksInPath)
        guard contains(path: resolved.path) else {
            throw ToolError.denied("Path is outside the allowed roots: \(resolved.path)")
        }
        return resolved
    }

    /// System executable prefixes that shell may reference without being trust-root paths.
    private static let systemExecutablePrefixes = [
        "/bin/", "/usr/bin/", "/usr/sbin/", "/sbin/", "/usr/libexec/",
    ]

    /// Absolute / home-relative path tokens outside trust roots (approval cannot widen).
    /// Policy: cwd + path args must stay in ~/ /tmp /Users/Shared; `/bin`/`/usr/bin` etc. allowed as executables only.
    public static func blockedAbsolutePaths(inShellCommand command: String) -> String? {
        let pattern = #"(\~/[^\s;|&<>]+|~(?=[\s;|&<>]|$)|/(?:Users|private|tmp|etc|var|opt|System|Volumes|Applications|Library|usr|bin|sbin)[^\s;|&<>]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        for match in regex.matches(in: command, range: range) {
            guard let swiftRange = Range(match.range, in: command) else { continue }
            let token = String(command[swiftRange])
            if token == "~" || token == "~/" { continue }
            if contains(path: token) { continue }
            let resolved = ((token as NSString).expandingTildeInPath as NSString).resolvingSymlinksInPath
            if systemExecutablePrefixes.contains(where: { resolved == String($0.dropLast()) || resolved.hasPrefix($0) }) {
                continue
            }
            return "命令引用了信任根之外的路径：\(token)。Shell 与 filesystem 共用 ~/、/tmp、/Users/Shared；系统可执行前缀（/bin、/usr/bin…）除外。这只检查字面路径，不能代替审批。"
        }
        return nil
    }
}

/// Advisory deny-list for a few catastrophic shell patterns (`rm -rf /`,
/// `curl | bash`). It is not a sandbox: split flags, `find -delete`, and
/// encoded commands pass through and must be judged on the approval card.
public enum DangerousCommand {
    private static let rules: [(pattern: String, reason: String)] = [
        (#"(?i)\brm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)\s+(/|~|\$HOME)(\s|$|/)"#, "递归删除根目录或主目录"),
        (#"(?i)\brm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)\s+(~/Desktop|~/Documents|~/Downloads|\$HOME/Desktop|\$HOME/Documents|\$HOME/Downloads)(/|\s|$)"#, "递归删除桌面/文稿/下载目录"),
        (#"(?i)\brm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)\s+[^\n;|&]*\b(Desktop|Documents|Downloads)(/|\s|$)"#, "递归删除桌面/文稿/下载子树"),
        (#"(?i)\b(curl|wget|fetch)\b[^\n|;]*\|\s*(ba)?sh\b"#, "管道下载并执行 shell"),
        (#"(?i)\b(curl|wget|fetch)\b[^\n|;]*\|\s*(ba)?sh\s+-s\b"#, "管道下载并执行 shell -s"),
        (#"(?i)>\s*~/?\.ssh/authorized_keys\b"#, "写入 ~/.ssh/authorized_keys"),
        (#"(?i)>\s*\$HOME/?\.ssh/authorized_keys\b"#, "写入 $HOME/.ssh/authorized_keys"),
        (#"(?i)\btee\b[^\n;|&]*\.ssh/authorized_keys\b"#, "tee 写入 authorized_keys"),
        (#"(?i)\brm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)\s+[^\n;|&]*~/"#, "递归删除主目录下大片内容"),
        (#"(?i)\bsudo\b"#, "sudo 需要交互式密码"),
        (#"(?i)\bmkfs(\.|\s)"#, "格式化磁盘"),
        (#"(?i)\bdiskutil\s+(erase|reformat)"#, "擦除磁盘"),
        (#"(?i)\bdd\b.*\bof=/dev/(disk|rdisk)"#, "直接写磁盘设备"),
        (#"(?i)\b(shutdown|reboot|halt)\b"#, "关机或重启"),
        (#"(?i):\(\)\s*\{\s*:\|:&\s*\}\s*;:"#, "fork bomb"),
        (#"(?i)\bchmod\s+-R\s+777\s+/"#, "递归放开根目录权限"),
    ]

    public static func blockReason(for command: String) -> String? {
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(command.startIndex..<command.endIndex, in: command)
            if regex.firstMatch(in: command, range: range) != nil {
                return rule.reason
            }
        }
        return nil
    }
}

public enum BuiltinTools {
    public static func all() -> [any KernelTool] {
        [
            TimeTool(),
            ShellTool(),
            ApplicationTool(),
            FilesystemTool(),
            ScreenshotTool(),
            ClipboardTool(),
        ]
    }
}
