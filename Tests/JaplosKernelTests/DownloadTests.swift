import XCTest
@testable import JaplosKernel
import JaplosProtocol

/// C10: an existing file must survive a download; the new bytes go to "name (1).ext".
final class DownloadTests: XCTestCase {
    private func freePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw XCTSkip("socket() failed") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw XCTSkip("bind() failed") }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw XCTSkip("getsockname() failed") }
        return Int(UInt16(bigEndian: actual.sin_port))
    }

    func testDownloadKeepsExistingFileAndRenames() async throws {
        let served = URL(fileURLWithPath: "/tmp/lucas-dl-src-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let target = URL(fileURLWithPath: "/tmp/lucas-dl-dst-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: served)
            try? FileManager.default.removeItem(at: target)
        }
        try Data("new-content".utf8).write(to: served.appendingPathComponent("report.txt"))
        let existing = target.appendingPathComponent("report.txt")
        try Data("keep-me".utf8).write(to: existing)

        let port = try freePort()
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", served.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        // Wait for the server to accept connections.
        try await Task.sleep(nanoseconds: 800_000_000)

        let result = try await DownloadFetchTool().invoke(
            arguments: .object([
                "url": .string("http://127.0.0.1:\(port)/report.txt"),
                "path": .string(existing.path),
            ]),
            context: ToolContext(workspace: target)
        )

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep-me")
        let renamed = target.appendingPathComponent("report (1).txt")
        XCTAssertEqual(result["path"]?.stringValue, renamed.path)
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "new-content")
    }
}
