import XCTest
@testable import JaplosKernel
import JaplosProtocol

/// C9: documents that predate the vector table must get embeddings on the next
/// launch (v9 -> v10), in batches, without touching documents that already have one.
final class KnowledgeBackfillTests: XCTestCase {
    func testV9LibraryBackfillsMissingVectors() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("kernel.sqlite3").path

        let store = try KernelStore(path: path)
        for index in 0..<20 {
            try store.upsertKnowledgeDocument(
                id: String(format: "doc-%02d", index),
                title: "笔记 \(index)",
                record: .object([
                    "title": .string("笔记 \(index)"),
                    "body": .string("这是第 \(index) 篇关于向量回填的测试文档。"),
                ])
            )
        }
        // Rewind to the v9 shape: rows exist, vectors do not.
        try store.database.execute("DELETE FROM knowledge_vectors;")
        try store.database.setUserVersion(9)

        let reopened = try KernelStore(path: path)
        XCTAssertEqual(try reopened.database.userVersion(), 10)
        let vectors = try reopened.database.scalarInt("SELECT COUNT(*) FROM knowledge_vectors;")
        if LocalEmbedding.isAvailable {
            XCTAssertEqual(vectors, 20, "every pre-v9 document needs a vector")
        } else {
            XCTAssertEqual(vectors, 0, "without an on-device model nothing can be computed")
        }
        let documents = try reopened.database.scalarInt("SELECT COUNT(*) FROM knowledge_documents;")
        XCTAssertEqual(documents, 20)
    }
}
