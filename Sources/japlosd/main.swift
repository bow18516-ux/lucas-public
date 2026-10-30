import Foundation
import JaplosKernel
import JaplosProtocol
import JaplosRuntime

struct DaemonOptions {
    var socketPath: String
    var storePath: String
    var workspace: URL
}

func defaultSupportDirectory() -> URL {
    if let override = ProcessInfo.processInfo.environment["LUCAS_CLONE_HOME"], !override.isEmpty {
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Lucas", isDirectory: true)
}

func parseOptions() throws -> DaemonOptions {
    var options = DaemonOptions(
        socketPath: defaultSupportDirectory().appendingPathComponent("kernel.sock").path,
        storePath: defaultSupportDirectory().appendingPathComponent("kernel.sqlite3").path,
        workspace: FileManager.default.homeDirectoryForCurrentUser
    )
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--socket":
            guard !arguments.isEmpty else { throw DaemonError.missingValue("--socket") }
            options.socketPath = (arguments.removeFirst() as NSString).expandingTildeInPath
        case "--store":
            guard !arguments.isEmpty else { throw DaemonError.missingValue("--store") }
            options.storePath = (arguments.removeFirst() as NSString).expandingTildeInPath
        case "--workspace":
            guard !arguments.isEmpty else { throw DaemonError.missingValue("--workspace") }
            options.workspace = URL(fileURLWithPath: (arguments.removeFirst() as NSString).expandingTildeInPath)
        case "--help", "-h":
            print("""
            lucasd — Lucas kernel daemon

            用法:
              lucasd [--socket <path>] [--store <path>] [--workspace <path>]

            默认:
              socket: ~/Library/Application Support/Lucas/kernel.sock
              store:  ~/Library/Application Support/Lucas/kernel.sqlite3
            """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("Unknown argument: \(argument)\n".utf8))
        }
    }
    return options
}

enum DaemonError: Error, CustomStringConvertible {
    case missingValue(String)

    var description: String {
        switch self {
        case .missingValue(let flag): return "Missing value for \(flag)"
        }
    }
}


/// Create Japlos-shaped Application Support subdirs (empty scaffolds; safe/idempotent).
func ensureSupportTree(_ support: URL) {
    let fm = FileManager.default
    let names = [
        "self-healing",
        "credentials",
        "Caches",
        "Caches/wechat",
        "DownloadStaging",
        "feishu",
        "feishu/credentials",
        "wechat",
        "wechat/credentials",
        "Prompts",
        "Injection",
        "BuiltinSkills",
        "bin",
    ]
    for name in names {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    }
    // Japlos-shaped empty Feishu auth sqlite (0 rows until boss pastes credentials).
    let auth = support.appendingPathComponent("feishu/credentials/auth.sqlite")
    if !fm.fileExists(atPath: auth.path) {
        try? FeishuAuthStore.ensureSchema(at: auth)
    }
    let logs = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Lucas", isDirectory: true)
    try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
}

func log(_ message: String) {
    let stamp = ISO8601.string(from: Date())
    FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
}

do {
    let options = try parseOptions()
    let support = defaultSupportDirectory()
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    ensureSupportTree(support)

    let seededPrompts = PromptLibrary.seedOverridesIfNeeded()
    let seededScenes = SceneRouter.seedScenesIfNeeded()
    let seededSkills = SkillPack.seedIfNeeded()
    if seededPrompts > 0 || seededScenes || seededSkills > 0 {
        log("seeded prompts=\(seededPrompts) scenes=\(seededScenes) skills=\(seededSkills)")
    }

    let core = try KernelCore(storePath: options.storePath, workspace: options.workspace)
    let chat = ChatService(core: core)
    core.setChatHandler { request in await chat.handle(request) }
    core.setModelHandler { request in await chat.handle(request) }
    core.setStreamingChatHandler { request, emit, approval in
        await chat.handleStreaming(request, emit: emit, approval: approval)
    }

    let server = UnixSocketServer(
        path: options.socketPath,
        keepAlive: { !core.shutdownRequested },
        streamHandler: { request, emit, approval in
            await core.handleStreaming(request, emit: emit, approval: approval)
        },
        handler: { request in await core.handle(request) }
    )
    core.recordBootSelfHealing(supportDirectory: support)

    try server.start()
    if server.recoveredFromBindFailure {
        log("self-healing: recovered from socket bind failure at \(options.socketPath)")
        core.recordSelfHealing(
            kind: "socket.bind.recover",
            detail: ["socketPath": .string(options.socketPath)],
            supportDirectory: support
        )
    }

    Task {
        await core.reloadMCP()
        log("MCP tools: \(core.mcpDefinitions.count)")
    }

    log("lucasd \(core.version) listening on \(options.socketPath)")
    log("store: \(options.storePath)")
    log("tools: \(core.tools.definitions().map(\.name).joined(separator: ", "))")

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let queue = DispatchQueue(label: "lucasd.signals")
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
    let shutdown: () -> Void = {
        log("shutting down")
        server.stop()
        exit(0)
    }
    interrupt.setEventHandler(handler: shutdown)
    terminate.setEventHandler(handler: shutdown)
    interrupt.resume()
    terminate.resume()

    // Watch for `kernel.shutdown`.
    let monitor = DispatchSource.makeTimerSource(queue: queue)
    monitor.schedule(deadline: .now() + 0.5, repeating: 0.5)
    monitor.setEventHandler {
        if core.shutdownRequested {
            log("shutdown requested by client")
            server.stop()
            exit(0)
        }
    }
    monitor.resume()

    dispatchMain()
} catch {
    FileHandle.standardError.write(Data("lucasd failed: \(error)\n".utf8))
    exit(1)
}
