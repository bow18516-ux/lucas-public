import AppKit
import Foundation
import JaplosProtocol

// MARK: - Apple Music

public struct MusicTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.music",
            title: "音乐播放",
            summary: "控制 Apple Music：播放、暂停、切换、上一首、下一首、查看状态。action=play|pause|toggle|next|previous|status。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "action": .object([
                        "type": "string",
                        "enum": .array(["play", "pause", "toggle", "next", "previous", "status"]),
                    ]),
                ]),
                "required": .array(["action"]),
                "additionalProperties": false,
            ]),
            capability: Capability.musicControl,
            risk: .low
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        guard let action = arguments["action"]?.stringValue else {
            throw ToolError.invalidArguments("action is required")
        }
        let script: String
        switch action {
        case "play": script = "tell application \"Music\" to play"
        case "pause": script = "tell application \"Music\" to pause"
        case "toggle": script = "tell application \"Music\" to playpause"
        case "next": script = "tell application \"Music\" to next track"
        case "previous": script = "tell application \"Music\" to previous track"
        case "status":
            script = """
            tell application "Music"
                if it is running then
                    set stateText to (player state as text)
                    try
                        set trackName to name of current track
                        set artistName to artist of current track
                        return stateText & "|" & trackName & "|" & artistName
                    on error
                        return stateText & "||"
                    end try
                else
                    return "stopped||"
                end if
            end tell
            """
        default:
            throw ToolError.invalidArguments("Unknown action \(action)")
        }

        let result = try runAppleScript(script)
        if action == "status" {
            let parts = result.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            return .object([
                "state": .string(parts.first ?? "unknown"),
                "track": .string(parts.count > 1 ? parts[1] : ""),
                "artist": .string(parts.count > 2 ? parts[2] : ""),
            ])
        }
        return .object(["action": .string(action), "ok": .bool(true)])
    }

    private func runAppleScript(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw ToolError.failed("osascript failed to launch: \(error)")
        }
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorOutput, as: UTF8.self)
            throw ToolError.failed("Apple Music 控制失败（可能未授予自动化权限）：\(message.prefix(200))")
        }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - System audio

public struct AudioTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.audio",
            title: "系统音量",
            summary: "读取或设置系统输出音量（0–100）。action=get|set。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "action": .object(["type": "string", "enum": .array(["get", "set"])]),
                    "volume": .object(["type": "number", "minimum": 0, "maximum": 100]),
                ]),
                "required": .array(["action"]),
                "additionalProperties": false,
            ]),
            capability: Capability.audioControl,
            risk: .low
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        guard let action = arguments["action"]?.stringValue else {
            throw ToolError.invalidArguments("action is required")
        }
        switch action {
        case "get":
            let value = try run("output volume of (get volume settings)")
            return .object(["volume": .number(Double(Int(value) ?? 0))])
        case "set":
            guard let volume = arguments["volume"]?.intValue else {
                throw ToolError.invalidArguments("volume is required")
            }
            let clamped = min(max(volume, 0), 100)
            _ = try run("set volume output volume \(clamped)")
            return .object(["volume": .number(Double(clamped))])
        default:
            throw ToolError.invalidArguments("Unknown action \(action)")
        }
    }

    private func run(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ToolError.failed("音量控制失败：\(message)")
        }
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - URLs

public struct OpenURLTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.url.open",
            title: "打开链接",
            summary: "用默认浏览器打开一个 http(s) 链接。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "url": .object(["type": "string", "description": "http 或 https 地址"]),
                ]),
                "required": .array(["url"]),
                "additionalProperties": false,
            ]),
            capability: Capability.applicationsControl,
            risk: .high
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        guard
            let raw = arguments["url"]?.stringValue,
            let url = URL(string: raw),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            throw ToolError.invalidArguments("a valid http(s) url is required")
        }
        let opened = NSWorkspace.shared.open(url)
        guard opened else { throw ToolError.failed("系统拒绝打开 \(raw)") }
        return .object(["url": .string(raw), "opened": .bool(true)])
    }
}


// MARK: - Paths

public struct OpenPathTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.path.open",
            title: "打开路径",
            summary: "用 Finder 显示或用默认应用打开本机路径。action=reveal|open。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "action": .object(["type": "string", "enum": .array(["reveal", "open"])]),
                    "path": .object(["type": "string", "description": "绝对路径或 ~/ 路径"]),
                ]),
                "required": .array(["action", "path"]),
                "additionalProperties": false,
            ]),
            capability: Capability.applicationsControl,
            risk: .high
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        guard let action = arguments["action"]?.stringValue else {
            throw ToolError.invalidArguments("action is required")
        }
        guard let raw = arguments["path"]?.stringValue, !raw.isEmpty else {
            throw ToolError.invalidArguments("path is required")
        }
        let url = try TrustRoots.allowedURL(path: raw)
        let expanded = url.path
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ToolError.failed("路径不存在：\(expanded)")
        }
        switch action {
        case "reveal":
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return .object(["path": .string(expanded), "revealed": .bool(true)])
        case "open":
            let opened = NSWorkspace.shared.open(url)
            guard opened else { throw ToolError.failed("系统拒绝打开 \(expanded)") }
            return .object(["path": .string(expanded), "opened": .bool(true)])
        default:
            throw ToolError.invalidArguments("Unknown action \(action)")
        }
    }
}

public enum ExtendedTools {
    public static func all() -> [any KernelTool] {
        [MusicTool(), AudioTool(), OpenURLTool(), OpenPathTool()]
    }
}
