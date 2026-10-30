import XCTest
@testable import JaplosKernel
import JaplosProtocol

/// D1: `KernelCore` only gates policy and routes. Every declared operation must
/// resolve to exactly one domain handler, or be explicitly retired.
final class OperationDispatchTests: XCTestCase {
    private func declaredOperations() throws -> [String] {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // JaplosKernelTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/JaplosProtocol/KernelProtocol.swift"),
            encoding: .utf8
        )
        let regex = try NSRegularExpression(pattern: #"static let \w+ = KernelOperation\("([^"]+)"\)"#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }

    func testEveryDeclaredOperationIsHandledOrRetired() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-dispatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = try KernelCore(storePath: root.appendingPathComponent("kernel.sqlite3").path, workspace: root)

        let operations = try declaredOperations()
        XCTAssertGreaterThan(operations.count, 100, "operation list should cover the whole protocol")

        // `tool.approval` is answered inside the streaming connection loop, never
        // through `handle`, so it is neither dispatched nor retired.
        let streamOnly: Set<String> = ["tool.approval"]
        for raw in operations {
            let operation = KernelOperation(raw)
            if streamOnly.contains(raw) {
                XCTAssertFalse(core.handles(operation), "\(raw) must not be dispatched")
                continue
            }
            let handled = core.handles(operation)
            let retired = KernelRetiredOperations.all.contains(operation)
            XCTAssertTrue(
                handled || retired,
                "\(raw) has no handler and is not retired"
            )
        }
    }

    func testNoOperationIsRegisteredTwice() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-dispatch-dup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = try KernelCore(storePath: root.appendingPathComponent("kernel.sqlite3").path, workspace: root)

        let handlers = KernelCore.makeHandlers(core: core)
        let registered = handlers.reduce(0) { $0 + $1.operations.count }
        XCTAssertEqual(registered, core.operationHandlers.count, "an operation is claimed by two handlers")
        XCTAssertEqual(handlers.count, 7)
    }

    func testUnknownOperationFailsCleanly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-dispatch-unknown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = try KernelCore(storePath: root.appendingPathComponent("kernel.sqlite3").path, workspace: root)
        let response = await core.handle(KernelRequest(operation: KernelOperation("nope.not.real")))
        XCTAssertEqual(response.failure?.code, "not_found")
    }
}
