import XCTest
@testable import JaplosClient
import JaplosProtocol

/// A5: concurrent reconnects must produce exactly one daemon, a second daemon
/// must refuse a live socket, and shutdown -> restart must be reliable.
final class DaemonRestartTests: XCTestCase {
    private var root: URL!
    private var socketPath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Short path: sun_path is 104 bytes on macOS, and the default
        // temporary directory alone is most of that.
        root = URL(fileURLWithPath: "/tmp/lucas-race-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        socketPath = root.appendingPathComponent("kernel.sock").path
        setenv("LUCAS_CLONE_HOME", root.path, 1)
        setenv("LUCAS_SECRET_BACKEND", "file", 1)
        // Pin the freshly built daemon: `.build/release` may hold a stale build
        // that speaks an older protocol, which would make this test lie.
        let debugDaemon = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/lucasd")
        if FileManager.default.isExecutableFile(atPath: debugDaemon.path) {
            setenv("LUCASD_PATH", debugDaemon.path, 1)
        }
    }

    override func tearDownWithError() throws {
        unsetenv("LUCAS_CLONE_HOME")
        unsetenv("LUCAS_SECRET_BACKEND")
        unsetenv("LUCASD_PATH")
        for pid in Self.daemonPIDs(socket: socketPath) {
            kill(pid, SIGKILL)
        }
        if let log = try? String(contentsOf: daemonLog, encoding: .utf8) {
            try? log.write(toFile: "/tmp/lucas-daemon-test.log", atomically: true, encoding: .utf8)
        }
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeClient() -> KernelClient {
        KernelClient(socketPath: socketPath)
    }

    private var daemonLog: URL { root.appendingPathComponent("daemon.log") }

    private func ensureRunning(_ client: KernelClient) throws {
        try DaemonController.ensureRunning(client: client, logURL: daemonLog)
    }

    static func daemonPIDs(socket: String) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line -> pid_t? in
                let text = line.trimmingCharacters(in: .whitespaces)
                guard text.contains("lucasd"), text.contains("--socket \(socket)") else { return nil }
                return pid_t(text.split(separator: " ").first.map(String.init) ?? "")
            }
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(50_000)
        }
        return condition()
    }

    func testConcurrentReconnectStartsExactlyOneDaemon() async throws {
        let client = makeClient()
        try ensureRunning(client)
        XCTAssertTrue(client.ping())
        XCTAssertEqual(Self.daemonPIDs(socket: socketPath).count, 1)

        // Kill the daemon but leave its socket file behind: every one of the
        // next ten calls will hit "cannot connect" at the same time.
        for pid in Self.daemonPIDs(socket: socketPath) {
            kill(pid, SIGKILL)
        }
        XCTAssertTrue(waitUntil { !client.ping(timeout: 0.2) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "stale socket should still be there")

        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    (try? client.call(.kernelPing, arguments: .object([:]), timeout: 10)) != nil
                }
            }
            var count = 0
            for await ok in group where ok { count += 1 }
            return count
        }

        XCTAssertEqual(successes, 10, "every request must be served")
        XCTAssertTrue(client.ping())
        XCTAssertEqual(
            Self.daemonPIDs(socket: socketPath).count,
            1,
            "concurrent reconnects must not leave extra daemons: \(Self.daemonPIDs(socket: socketPath))"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    func testSecondDaemonRefusesLiveSocket() throws {
        let client = makeClient()
        try ensureRunning(client)
        XCTAssertTrue(client.ping())

        let binary = try XCTUnwrap(DaemonController.locateDaemon())
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--socket", socketPath,
            "--store", root.appendingPathComponent("kernel.sqlite3").path,
        ]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0, "a second daemon must refuse a live socket")
        XCTAssertTrue(client.ping(), "the first daemon must keep serving")
        XCTAssertEqual(Self.daemonPIDs(socket: socketPath).count, 1)
    }

    func testTwentyShutdownRestartCycles() throws {
        let client = makeClient()
        try ensureRunning(client)
        for iteration in 0..<20 {
            let before = Self.daemonPIDs(socket: socketPath)
            XCTAssertEqual(before.count, 1, "cycle \(iteration) start")

            client.shutdown()
            XCTAssertTrue(
                waitUntil({ !client.ping(timeout: 0.2) }, timeout: 5),
                "cycle \(iteration): old daemon kept answering"
            )
            try ensureRunning(client)
            XCTAssertTrue(client.ping(), "cycle \(iteration): new daemon not answering")

            let after = Self.daemonPIDs(socket: socketPath)
            XCTAssertEqual(after.count, 1, "cycle \(iteration): \(after)")
        }
    }
}
