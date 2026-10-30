import XCTest
@testable import JaplosKernel
import JaplosProtocol

/// D2: record tables go through one CRUD implementation; the public API keeps
/// its shape and upserts keep updating a single row.
final class LedgerRepositoryTests: XCTestCase {
    private func makeStore() throws -> (KernelStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try KernelStore(path: root.appendingPathComponent("kernel.sqlite3").path), root)
    }

    func testUpsertsUpdateInPlaceAcrossTables() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try store.upsertModule(id: "m1", version: "1", enabled: false, record: .object([:]))
        try store.upsertModule(id: "m1", version: "2", enabled: true, record: .object([:]))
        let modules = try store.listModules()
        XCTAssertEqual(modules.count, 1)
        XCTAssertEqual(modules.first?["version"]?.stringValue, "2")
        XCTAssertEqual(modules.first?["enabled"]?.boolValue, true)

        try store.upsertSubscription(id: "s1", informationType: "news", active: true, record: .object([:]))
        try store.upsertSubscription(id: "s1", informationType: "alerts", active: false, record: .object([:]))
        let subscriptions = try store.listSubscriptions()
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?["informationType"]?.stringValue, "alerts")
        XCTAssertEqual(subscriptions.first?["active"]?.boolValue, false)

        try store.upsertDelivery(id: "d1", subscriptionID: "s1", revisionID: "r1", state: "queued", record: .object([:]))
        XCTAssertEqual(try store.listDeliveries().first?["state"]?.stringValue, "queued")

        try store.upsertSituation(id: "sit1", record: .object([:]))
        XCTAssertEqual(try store.listSituations().count, 1)

        let ledgerID = try store.upsertRuntimeLedger(table: "task_plans", id: nil, record: .object(["a": .number(1)]))
        XCTAssertEqual(try store.listRuntimeLedger(table: "task_plans").count, 1)
        try store.upsertRuntimeLedger(table: "task_plans", id: ledgerID, record: .object(["a": .number(2)]))
        let rows = try store.listRuntimeLedger(table: "task_plans")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["id"]?.stringValue, ledgerID)
        try store.deleteRuntimeLedger(table: "task_plans", id: ledgerID)
        XCTAssertEqual(try store.listRuntimeLedger(table: "task_plans").count, 0)
    }

    func testUnknownLedgerTableIsRejected() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try store.upsertRuntimeLedger(table: "not_a_table", id: nil, record: .object([:])))
    }
}
