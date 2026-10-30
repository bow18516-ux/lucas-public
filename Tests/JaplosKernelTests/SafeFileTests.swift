import XCTest
@testable import JaplosKernel
import JaplosProtocol

/// C20: a write must not follow a symlink planted after the trust-root check.
final class SafeFileTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/lucas-safe-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testWriteRefusesSymlinkTarget() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        try Data("keep-me".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try SafeFile.write(Data("pwned".utf8), to: link)) { error in
            XCTAssertTrue(String(describing: error).contains("符号链接"), "\(error)")
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep-me")
    }

    func testWriteCreatesAndOverwritesRegularFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try SafeFile.write(Data("one".utf8), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "one")
        try SafeFile.write(Data("two".utf8), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "two")
        XCTAssertThrowsError(try SafeFile.write(Data("three".utf8), to: file, exclusive: true)) { error in
            XCTAssertTrue(String(describing: error).contains("覆盖"), "\(error)")
        }
    }

    func testPDFCreateRefusesSymlinkDestination() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("victim.txt")
        try Data("keep-me".utf8).write(to: target)
        let link = directory.appendingPathComponent("report.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        do {
            _ = try await PDFCreateTool().invoke(
                arguments: .object(["text": .string("hello"), "path": .string(link.path)]),
                context: ToolContext(workspace: directory)
            )
            XCTFail("symlinked PDF destination must be refused")
        } catch {
            XCTAssertTrue(String(describing: error).contains("符号链接") || String(describing: error).contains("覆盖"), "\(error)")
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep-me")
    }
}
