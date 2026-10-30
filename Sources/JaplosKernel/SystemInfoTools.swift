import AppKit
import CoreGraphics
import Foundation
import JaplosProtocol

// MARK: - Windows

public struct WindowListTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.window.list",
            title: "窗口列表",
            summary: "列出当前屏幕上可见的窗口：所属应用、标题、位置尺寸、层级。用于了解用户正在看什么。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "additionalProperties": false,
            ]),
            capability: Capability.systemRead,
            risk: .low,
            approval: .never
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = raw.prefix(80).compactMap { item -> JSONValue? in
            guard let owner = item[kCGWindowOwnerName as String] as? String else { return nil }
            let title = item[kCGWindowName as String] as? String ?? ""
            let layer = item[kCGWindowLayer as String] as? Int ?? 0
            let bounds = item[kCGWindowBounds as String] as? [String: Any] ?? [:]
            return .object([
                "owner": .string(owner),
                "title": .string(title),
                "layer": .number(Double(layer)),
                "bounds": .object([
                    "x": .number((bounds["X"] as? Double) ?? 0),
                    "y": .number((bounds["Y"] as? Double) ?? 0),
                    "width": .number((bounds["Width"] as? Double) ?? 0),
                    "height": .number((bounds["Height"] as? Double) ?? 0),
                ]),
            ])
        }
        return .object(["windows": .array(Array(windows))])
    }
}

// MARK: - Processes

public struct ProcessListTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.process.list",
            title: "进程列表",
            summary: "列出占用 CPU 累计时间最高的进程（pid、路径、累计 CPU 秒、驻留内存、线程数）。只读，不启动外部命令。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "limit": .object(["type": "number", "minimum": 1, "maximum": 50]),
                ]),
                "additionalProperties": false,
            ]),
            capability: Capability.systemRead,
            risk: .low,
            approval: .never
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        let limit = min(max(arguments["limit"]?.intValue ?? 15, 1), 50)

        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * 4))
        let count = max(0, Int(bytes) / MemoryLayout<pid_t>.size)

        struct Entry {
            let pid: Int32
            let command: String
            let cpuSeconds: Double
            let memoryBytes: UInt64
            let threads: Int
        }

        var entries: [Entry] = []
        let infoSize = Int32(MemoryLayout<proc_taskinfo>.size)
        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0 else { continue }
            var info = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, infoSize) == infoSize else { continue }
            guard info.pti_resident_size > 0 else { continue }

            var pathBuffer = [CChar](repeating: 0, count: 4096)
            let pathLength = proc_pidpath(pid, &pathBuffer, 4096)
            let command = pathLength > 0
                ? String(cString: pathBuffer)
                : "pid \(pid)"

            let cpuSeconds = Double(info.pti_total_user &+ info.pti_total_system) / 1_000_000_000
            entries.append(Entry(
                pid: pid,
                command: command,
                cpuSeconds: cpuSeconds,
                memoryBytes: info.pti_resident_size,
                threads: Int(info.pti_threadnum)
            ))
        }
        entries.sort { $0.cpuSeconds > $1.cpuSeconds }

        return .object([
            "processes": .array(entries.prefix(limit).map { entry in
                .object([
                    "pid": .number(Double(entry.pid)),
                    "command": .string(entry.command),
                    "cpuSeconds": .number(entry.cpuSeconds),
                    "memoryBytes": .number(Double(entry.memoryBytes)),
                    "threads": .number(Double(entry.threads)),
                ])
            }),
        ])
    }
}

// MARK: - Network

public struct NetworkInfoTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.network.info",
            title: "网络信息",
            summary: "列出本机网络接口、IPv4/IPv6 地址与启用状态。用于判断当前网络环境。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "additionalProperties": false,
            ]),
            capability: Capability.systemRead,
            risk: .low,
            approval: .never
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        var interfaces: [JSONValue] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            throw ToolError.failed("getifaddrs failed")
        }
        defer { freeifaddrs(pointer) }

        var seen = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, let address = current.pointee.ifa_addr else { continue }
            let family = address.pointee.sa_family
            guard family == AF_INET || family == AF_INET6 else { continue }
            let name = String(cString: current.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = family == AF_INET
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let value = String(cString: host)
            let key = "\(name)-\(value)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            interfaces.append(.object([
                "name": .string(name),
                "address": .string(value),
                "family": .string(family == AF_INET ? "ipv4" : "ipv6"),
            ]))
        }
        return .object(["interfaces": .array(interfaces)])
    }
}

// MARK: - Hostname

public struct HostnameTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.hostname",
            title: "主机名",
            summary: "返回本机 hostname（Host.current().localizedName / ProcessInfo）。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "additionalProperties": false,
            ]),
            capability: Capability.systemRead,
            risk: .low,
            approval: .never
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        let localized = Host.current().localizedName ?? ""
        let name = ProcessInfo.processInfo.hostName
        return .object([
            "hostname": .string(name),
            "localizedName": .string(localized),
        ])
    }
}

// MARK: - OS version

public struct OSVersionTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.os.version",
            title: "系统版本",
            summary: "返回 macOS 版本号与操作系统名称。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "additionalProperties": false,
            ]),
            capability: Capability.systemRead,
            risk: .low,
            approval: .never
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        let info = ProcessInfo.processInfo
        let v = info.operatingSystemVersion
        return .object([
            "name": .string(info.operatingSystemVersionString),
            "major": .number(Double(v.majorVersion)),
            "minor": .number(Double(v.minorVersion)),
            "patch": .number(Double(v.patchVersion)),
        ])
    }
}

// MARK: - App support paths

public struct AppSupportPathsTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.app.support.paths",
            title: "Lucas 数据路径",
            summary: "返回 Lucas Application Support / Logs / self-healing 等本机目录。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "additionalProperties": false,
            ]),
            capability: Capability.systemRead,
            risk: .low,
            approval: .never
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        let home: URL
        if let override = ProcessInfo.processInfo.environment["LUCAS_CLONE_HOME"], !override.isEmpty {
            home = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Lucas", isDirectory: true)
        }
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Lucas", isDirectory: true)
        func dir(_ name: String) -> JSONValue {
            .string(home.appendingPathComponent(name, isDirectory: true).path)
        }
        return .object([
            "applicationSupport": .string(home.path),
            "store": .string(home.appendingPathComponent("kernel.sqlite3").path),
            "socket": .string(home.appendingPathComponent("kernel.sock").path),
            "selfHealing": dir("self-healing"),
            "credentials": dir("credentials"),
            "caches": dir("Caches"),
            "downloadStaging": dir("DownloadStaging"),
            "feishu": dir("feishu"),
            "prompts": dir("Prompts"),
            "injection": dir("Injection"),
            "builtinSkills": dir("BuiltinSkills"),
            "bin": dir("bin"),
            "logs": .string(logs.path),
        ])
    }
}

// MARK: - Lucas UserDefaults (scoped)

public struct UserDefaultsTool: KernelTool {
    public init() {}

    private static let allowedPrefixes = ["lucas.", "LUCAS_", "onboarding", "speech", "update", "voice"]

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.user.defaults",
            title: "Lucas 偏好",
            summary: "读取或写入仅限 Lucas 相关键的 UserDefaults（suite=com.lucas.app）。action=get|set。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "action": .object(["type": "string", "enum": .array(["get", "set"])]),
                    "key": .object(["type": "string"]),
                    "value": .object([:]),
                ]),
                "required": .array(["action", "key"]),
                "additionalProperties": false,
            ]),
            capability: Capability.systemRead,
            risk: .low,
            approval: .whenArgument(key: "action", isOneOf: ["set"])
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        guard let action = arguments["action"]?.stringValue else {
            throw ToolError.invalidArguments("action is required")
        }
        guard let key = arguments["key"]?.stringValue, !key.isEmpty else {
            throw ToolError.invalidArguments("key is required")
        }
        guard Self.isAllowed(key) else {
            throw ToolError.invalidArguments("key must be Lucas-scoped (lucas.* / onboarding / speech / voice / update)")
        }
        let defaults = UserDefaults(suiteName: "com.lucas.app") ?? .standard
        switch action {
        case "get":
            if let value = defaults.object(forKey: key) {
                return .object(["key": .string(key), "value": Self.json(from: value)])
            }
            return .object(["key": .string(key), "value": .null])
        case "set":
            guard let json = arguments["value"] else {
                throw ToolError.invalidArguments("value is required for set")
            }
            defaults.set(Self.plist(from: json), forKey: key)
            return .object(["key": .string(key), "saved": .bool(true)])
        default:
            throw ToolError.invalidArguments("Unknown action \(action)")
        }
    }

    private static func isAllowed(_ key: String) -> Bool {
        let lower = key.lowercased()
        if lower.hasPrefix("lucas.") || lower.hasPrefix("com.lucas.") { return true }
        return allowedPrefixes.contains { lower.hasPrefix($0.lowercased()) }
    }

    private static func json(from value: Any) -> JSONValue {
        switch value {
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let arr as [Any]: return .array(arr.map(json(from:)))
        case let dict as [String: Any]:
            return .object(dict.mapValues { json(from: $0) })
        default: return .string(String(describing: value))
        }
    }

    private static func plist(from value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let items): return items.map(plist(from:))
        case .object(let obj): return obj.mapValues { plist(from: $0) }
        }
    }
}


// MARK: - Uptime

public struct SystemUptimeTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.uptime",
            title: "系统运行时间",
            summary: "返回本机自启动以来的秒数（ProcessInfo.systemUptime）。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "additionalProperties": false,
            ]),
            capability: Capability.systemRead,
            risk: .low,
            approval: .never
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        let seconds = ProcessInfo.processInfo.systemUptime
        return .object([
            "seconds": .number(seconds),
            "hours": .number(seconds / 3600.0),
        ])
    }
}

public enum SystemInfoTools {
    public static func all() -> [any KernelTool] {
        [
            WindowListTool(),
            ProcessListTool(),
            NetworkInfoTool(),
            HostnameTool(),
            OSVersionTool(),
            AppSupportPathsTool(),
            SystemUptimeTool(),
            UserDefaultsTool(),
        ]
    }
}
