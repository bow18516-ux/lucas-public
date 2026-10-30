import XCTest
@testable import JaplosKernel
import JaplosProtocol

/// C15: an approved `mail.send` sends once. There is no model-supplied
/// `confirm` flag left to bypass or duplicate the approval.
final class MailSendTests: XCTestCase {
    func testSendParametersHaveNoConfirmGate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-mail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KernelStore(path: root.appendingPathComponent("kernel.sqlite3").path)
        let channel = MailChannel(store: store, supportDirectory: root)
        let tools = MailTools.all(mail: channel)
        let send = try XCTUnwrap(tools.first { $0.definition.name == "mail.send" })
        let properties = send.definition.inputSchema["properties"]?.objectValue ?? [:]
        XCTAssertNil(properties["confirm"])
        XCTAssertNil(properties["draft_only"])
        XCTAssertNil(properties["draftOnly"])
        XCTAssertNotNil(properties["to"])
    }

    func testApprovedSendCallsSmtpOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-mail-send-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KernelStore(path: root.appendingPathComponent("kernel.sqlite3").path)
        let channel = MailChannel(store: store, supportDirectory: root)
        _ = try channel.configure(
            preset: "custom", email: "sender@example.com", displayName: "Sender",
            password: "app-password", imapHost: "imap.example.com", imapPort: 993,
            smtpHost: "smtp.example.com", smtpPort: 465
        )

        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        channel.outboundSender = { _, _, _, _, _, recipients, _, _ in
            counter.value += 1
            XCTAssertEqual(recipients, ["to@example.com"])
        }

        let result = try channel.send(
            to: "to@example.com",
            subject: "hello",
            body: "body",
            cc: nil
        )
        XCTAssertEqual(result["sent"]?.boolValue, true)
        XCTAssertEqual(counter.value, 1, "an approved send must hit SMTP exactly once")
        XCTAssertTrue(FileManager.default.fileExists(atPath: channel.draftsDir.path))
    }

    func testOldDraftsArePruned() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-mail-drafts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KernelStore(path: root.appendingPathComponent("kernel.sqlite3").path)
        let channel = MailChannel(store: store, supportDirectory: root)
        try FileManager.default.createDirectory(at: channel.draftsDir, withIntermediateDirectories: true)
        let old = channel.draftsDir.appendingPathComponent("old.json")
        let fresh = channel.draftsDir.appendingPathComponent("fresh.json")
        try Data("{}".utf8).write(to: old)
        try Data("{}".utf8).write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 86_400)],
            ofItemAtPath: old.path
        )
        let removed = channel.pruneDrafts()
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }
}
