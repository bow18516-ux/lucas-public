import XCTest
@testable import JaplosKernel
import JaplosProtocol

/// A2: a child the shell leaves in the background must not defeat the timeout,
/// and a timeout must take the whole process group with it.
final class ShellProcessGroupTests: XCTestCase {
    private let marker = "31.7"

    private func invoke(_ command: String, timeout: Double) async throws -> JSONValue {
        try await ShellTool().invoke(
            arguments: .object([
                "command": .string(command),
                "timeoutSeconds": .number(timeout),
            ]),
            context: ToolContext(workspace: URL(fileURLWithPath: "/tmp"))
        )
    }

    /// Exact command match through `ps`: a `pgrep -f` substring would also hit
    /// the shell running this test, whose command line contains the pattern.
    private func matchingProcesses(_ command: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        // Drain before waiting: `ps -axo` on a busy Mac can exceed the 64 KiB
        // pipe buffer, and a child blocked on write never exits.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard let space = line.firstIndex(of: " ") else { return false }
                return String(line[line.index(after: space)...])
                    .trimmingCharacters(in: .whitespaces) == command
            }
    }

    private func killLeftovers() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "sleep \(marker)"]
        try? process.run()
        process.waitUntilExit()
    }

    func testShellBackgroundChildDoesNotBlock() async throws {
        defer { killLeftovers() }
        let started = Date()
        let output = try await invoke("sleep 30 & echo started", timeout: 2)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(
            output["stdout"]?.stringValue?.contains("started") ?? false,
            "stdout should still be captured: \(output)"
        )
        XCTAssertLessThan(
            elapsed,
            3,
            "a background child holding the pipe must not extend a 2s timeout to 30s"
        )
        XCTAssertEqual(output["detachedBackground"]?.boolValue, true)
    }

    func testShellTimeoutKillsProcessGroup() async throws {
        defer { killLeftovers() }
        let started = Date()
        let output = try await invoke("sleep \(marker) & sleep \(marker)", timeout: 2)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(output["timedOut"]?.boolValue, true, "\(output)")
        XCTAssertLessThan(elapsed, 4, "timeout must fire and kill the group promptly")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(
            matchingProcesses("sleep \(marker)").isEmpty,
            "background children survived the timeout: \(matchingProcesses("sleep \(marker)"))"
        )
    }

    func testShellReportsDetachedBackground() async throws {
        // A distinct duration keeps this test's intentionally-detached child out
        // of the timeout test's leftover check.
        let output = try await invoke("sleep 4 & echo done", timeout: 5)
        XCTAssertEqual(output["exitCode"]?.intValue, 0)
        XCTAssertTrue(output["stdout"]?.stringValue?.contains("done") ?? false)
        XCTAssertEqual(output["detachedBackground"]?.boolValue, true)
    }
}
