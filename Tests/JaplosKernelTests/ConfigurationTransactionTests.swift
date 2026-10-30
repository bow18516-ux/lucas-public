import XCTest
@testable import JaplosKernel
import JaplosProtocol

/// C13: `setConfiguration` writes the row, reads the new revision, then appends
/// history. Without a transaction two writers can both read revision 2 and one
/// history row silently replaces the other.
final class ConfigurationTransactionTests: XCTestCase {
    func testConcurrentConfigurationWritesKeepEveryRevision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-config-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KernelStore(path: root.appendingPathComponent("kernel.sqlite3").path)
        let path = "agents.default.custom"

        let group = DispatchGroup()
        for index in 0..<50 {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                try? store.setConfiguration(
                    path: path,
                    value: .string("value-\(index)"),
                    updatedBy: "thread-\(index)"
                )
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)

        let rows = try store.database.query(
            "SELECT revision FROM configuration_history WHERE path = ? ORDER BY revision;",
            [path]
        )
        let revisions = rows.compactMap { ($0["revision"] as? Int64).map(Int.init) }
        XCTAssertEqual(revisions, Array(1...50), "every revision must be recorded exactly once")
    }
}
