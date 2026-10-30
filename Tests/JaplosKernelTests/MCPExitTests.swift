import XCTest
@testable import JaplosKernel
import JaplosProtocol

/// C19: when an MCP child dies, `mcp.status` must say `exited` and tool calls
/// must fail immediately instead of waiting out the 120s request timeout.
final class MCPExitTests: XCTestCase {
    func testChildExitMarksExitedAndFailsFast() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let script = root.appendingPathComponent("scripts/mcp_echo_server.py")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script.path), "echo server missing")
        let client = MCPStdioClient(config: MCPServerConfig(
            id: "echo",
            name: "Echo",
            command: "/usr/bin/python3",
            args: [script.path]
        ))
        try await client.start()
        defer { client.stop() }
        XCTAssertEqual(client.state, "ready")
        let pid = try XCTUnwrap(client.pid)

        kill(pid, SIGKILL)
        let deadline = Date().addingTimeInterval(5)
        while client.state != "exited" && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(client.state, "exited", "a dead child must not report ready")

        let started = Date()
        do {
            _ = try await client.callTool("echo", arguments: .object(["text": .string("after death")]))
            XCTFail("a dead MCP server must not answer")
        } catch {
            // expected
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 2, "the call waited \(elapsed)s instead of failing fast")
    }
}
