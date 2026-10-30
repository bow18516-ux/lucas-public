import XCTest
@testable import JaplosClient
import Foundation

/// C12: the crash writer must work with only `write(2)` on a descriptor that
/// was opened before the crash, and it must not use the old /tmp path.
final class CrashLogTests: XCTestCase {
    func testRecordAppendsSignalLine() throws {
        let directory = URL(fileURLWithPath: "/tmp/lucas-crash-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("crash.log")

        CrashLog.install(url: url)
        XCTAssertGreaterThanOrEqual(CrashLog.descriptor, 0)
        CrashLog.record(SIGSEGV)
        CrashLog.record(SIGABRT)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, "signal 11\nsignal 6\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testDefaultPathIsUnderLibraryLogs() {
        let path = CrashLog.defaultURL().path
        XCTAssertTrue(path.hasSuffix("/Library/Logs/Lucas/crash.log"), path)
        XCTAssertFalse(path.hasPrefix("/tmp/"), path)
    }
}
