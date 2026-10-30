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
            risk: .low
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
            risk: .low
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
            risk: .low
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

public enum SystemInfoTools {
    public static func all() -> [any KernelTool] {
        [WindowListTool(), ProcessListTool(), NetworkInfoTool()]
    }
}
