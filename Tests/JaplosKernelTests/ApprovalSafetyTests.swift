import XCTest
@testable import JaplosKernel
import JaplosProtocol

final class ApprovalSafetyTests: XCTestCase {
    func testRegisteredToolsDeclareApproval() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-approval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = try KernelCore(storePath: root.appendingPathComponent("kernel.sqlite3").path, workspace: root)
        let defs = core.tools.definitions()

        let never: Set<String> = [
            "system.time", "system.window.list", "system.process.list", "system.network.info",
            "system.hostname", "system.os.version", "system.app.support.paths", "system.uptime",
            "memory.search", "knowledge.search", "knowledge.read",
            "mail.status", "mail.list", "mail.read",
            "runtime.wechat.status", "runtime.feishu.status",
        ]
        let conditional: [String: ToolApproval] = [
            "system.filesystem": .whenArgument(key: "action", isOneOf: ["write"]),
            "system.application": .whenArgument(key: "action", isOneOf: ["open", "quit"]),
            "system.music": .whenArgument(key: "action", isOneOf: ["play", "pause", "toggle", "next", "previous"]),
            "system.audio": .whenArgument(key: "action", isOneOf: ["set"]),
            "system.user.defaults": .whenArgument(key: "action", isOneOf: ["set"]),
        ]
        let mustAlways: Set<String> = [
            "system.command.shell.execute",
            "system.document.pdf.create",
            "system.download.fetch",
            "system.screen.capture",
            "system.clipboard",
            "mail.send",
            "memory.save",
            "system.path.open",
            "system.url.open",
            "runtime.feishu.send_text",
        ]

        XCTAssertGreaterThan(defs.count, 30)
        XCTAssertFalse(defs.contains { $0.name == "runtime.wechat.send_text" })
        XCTAssertFalse(defs.contains { $0.name == "runtime.wechat.send_file" })
        for def in defs {
            if never.contains(def.name) {
                XCTAssertEqual(def.approval, .never, def.name)
                let call = ToolCall(name: def.name, arguments: .object([:]))
                XCTAssertFalse(ToolApprovalGate.requiresApproval(call: call, definition: def), def.name)
            } else if let expected = conditional[def.name] {
                XCTAssertEqual(def.approval, expected, def.name)
            } else {
                XCTAssertEqual(def.approval, .always, def.name)
            }
        }
        for name in mustAlways {
            let def = try XCTUnwrap(defs.first { $0.name == name })
            XCTAssertEqual(def.approval, .always, name)
            XCTAssertTrue(ToolApprovalGate.requiresApproval(
                call: ToolCall(name: name, arguments: .object(["text": .string("x"), "path": .string("/tmp/a.pdf")])),
                definition: def
            ), name)
        }

        let filesystem = try XCTUnwrap(defs.first { $0.name == "system.filesystem" })
        XCTAssertFalse(ToolApprovalGate.requiresApproval(
            call: ToolCall(name: filesystem.name, arguments: .object(["action": .string("read"), "path": .string("~/Desktop")])),
            definition: filesystem
        ))
        XCTAssertTrue(ToolApprovalGate.requiresApproval(
            call: ToolCall(name: filesystem.name, arguments: .object(["action": .string("write"), "path": .string("~/Desktop/a")])),
            definition: filesystem
        ))
    }

    func testMCPApprovalNeedsReadOnlyHintAndTrust() {
        XCTAssertEqual(MCPToolInfo.approval(readOnlyHint: true, trustReadOnly: true), .never)
        XCTAssertEqual(MCPToolInfo.approval(readOnlyHint: true, trustReadOnly: false), .always)
        XCTAssertEqual(MCPToolInfo.approval(readOnlyHint: false, trustReadOnly: true), .always)
        XCTAssertEqual(MCPToolInfo.approval(readOnlyHint: false, trustReadOnly: false), .always)
    }

    func testPDFRefusesToOverwriteExistingFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-pdf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let victim = dir.appendingPathComponent("victim.txt")
        try Data("keep-me".utf8).write(to: victim)
        let tool = PDFCreateTool()
        do {
            _ = try await tool.invoke(
                arguments: .object(["text": .string("pwned"), "path": .string(victim.path)]),
                context: ToolContext(workspace: dir)
            )
            XCTFail("overwrite should be refused")
        } catch {
            XCTAssertTrue(String(describing: error).contains("覆盖") || String(describing: error).contains("Denied"))
        }
        let data = try Data(contentsOf: victim)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "keep-me")
        XCTAssertFalse(data.starts(with: Data("%PDF".utf8)))
    }

    func testFilesystemReadDeniesSensitivePaths() async throws {
        let tool = FilesystemTool()
        let paths = [
            "~/.ssh/id_rsa",
            "~/.aws/credentials",
            "~/.gnupg/pubring.kbx",
            "~/Library/Keychains/login.keychain-db",
            "~/Library/Application Support/Lucas/secrets.json",
        ]
        for path in paths {
            do {
                _ = try await tool.invoke(
                    arguments: .object(["action": .string("read"), "path": .string(path)]),
                    context: ToolContext(workspace: URL(fileURLWithPath: NSHomeDirectory()))
                )
                XCTFail("expected deny for \(path)")
            } catch {
                XCTAssertTrue(String(describing: error).contains("敏感"), "\(path): \(error)")
            }
        }
    }

    func testKernelStatusExposesBuildAndExecutable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = try KernelCore(storePath: root.appendingPathComponent("kernel.sqlite3").path, workspace: root)
        let response = await core.handle(KernelRequest(operation: .kernelStatus))
        let result = try XCTUnwrap(response.result)
        XCTAssertFalse((result["build"]?.stringValue ?? "").isEmpty)
        let executable = try XCTUnwrap(result["executable"])
        let path = try XCTUnwrap(executable["path"]?.stringValue)
        XCTAssertTrue(path.hasPrefix("/"), path)
        XCTAssertNotNil(executable["modifiedAt"]?.doubleValue)
    }

    func testShellLargeOutputIsTruncatedInsteadOfTimingOut() async throws {
        let tool = ShellTool()
        let output = try await tool.invoke(
            arguments: .object([
                "command": .string(#"python3 -c 'print("x"*200000, end="")'"#),
                "timeoutSeconds": .number(20),
            ]),
            context: ToolContext(workspace: URL(fileURLWithPath: "/tmp"))
        )
        XCTAssertEqual(output["timedOut"]?.boolValue, false)
        XCTAssertEqual(output["exitCode"]?.intValue, 0)
        XCTAssertEqual(output["truncated"]?.boolValue, true)
        XCTAssertEqual(output["stdout"]?.stringValue?.count, 32 * 1024)
    }

    func testMailHeaderRejectsInjectedRecipients() {
        XCTAssertThrowsError(try MailHeader.requireAddress("a@b.com\r\nBcc: hidden@evil.test", field: "to"))
        XCTAssertThrowsError(try MailHeader.requireAddress("not-an-email", field: "to"))
        XCTAssertNoThrow(try MailHeader.requireAddress("Ada <ada@example.com>", field: "to"))
    }

    func testParseDecisionRejectsBareAffirmations() throws {
        for raw in ["ok", "y", "yes", "no", "n", "同意", "拒绝", "同意 AB12", "approve"] {
            XCTAssertNil(WeChatApprovalBridge.parseDecision(raw), raw)
        }
        XCTAssertEqual(WeChatApprovalBridge.parseDecision("同意 ABCDEF")?.approved, true)
        XCTAssertEqual(WeChatApprovalBridge.parseDecision("同意 ABCDEF")?.shortId, "ABCDEF")
        XCTAssertEqual(WeChatApprovalBridge.parseDecision("拒绝 FEDCBA")?.approved, false)
        XCTAssertEqual(WeChatApprovalBridge.parseDecision("不允许 ABCDEF")?.approved, false)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-wx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = try KernelCore(storePath: root.appendingPathComponent("kernel.sqlite3").path, workspace: root)
        let bridge = core.wechatApprovalBridge
        XCTAssertFalse(bridge.handleInboundText("同意 ABCDEF", sender: "wxid_bound"))
        try core.store.setConfiguration(
            path: WeChatApprovalBridge.senderPath,
            value: .string("wxid_bound"),
            updatedBy: "test"
        )
        XCTAssertFalse(bridge.handleInboundText("同意 ABCDEF", sender: "someone-else"))
        XCTAssertFalse(bridge.handleInboundText("ok", sender: "wxid_bound"))

        let done = expectation(description: "approved")
        bridge.register(
            callID: "call-1",
            shortId: "ABCDEF",
            title: "t",
            name: "system.command.shell.execute",
            onResolve: { approved in
                XCTAssertTrue(approved)
                _ = bridge.settle(callID: "call-1", approved: approved, source: "test", notifyWeChat: false)
                done.fulfill()
            }
        )
        XCTAssertFalse(bridge.handleInboundText("同意 ABCDEF", sender: "wxid_bound", sentAt: Date(timeIntervalSince1970: 0), cursor: "old"))
        XCTAssertTrue(bridge.handleInboundText(
            "同意 ABCDEF",
            sender: "wxid_bound",
            sentAt: Date().addingTimeInterval(1),
            cursor: "upd-1"
        ))
        XCTAssertFalse(bridge.handleInboundText(
            "同意 ABCDEF",
            sender: "wxid_bound",
            sentAt: Date().addingTimeInterval(2),
            cursor: "upd-1"
        ))
        wait(for: [done], timeout: 2)
    }

    func testSchemaMigrationKeepsRowsAndWritesBackup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-migrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("kernel.sqlite3").path
        let store = try KernelStore(path: path)
        _ = try store.createSession(title: "keep")
        XCTAssertEqual(try store.database.userVersion(), KernelStore.schemaVersion)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".pre-migrate.bak"))
        let check = try store.database.query("PRAGMA integrity_check;")
        XCTAssertEqual(check.first?["integrity_check"] as? String, "ok")
        let reopened = try KernelStore(path: path)
        XCTAssertEqual(try reopened.listSessions(limit: 5).count, 1)
        XCTAssertEqual(try reopened.database.userVersion(), KernelStore.schemaVersion)
    }

    func testKnowledgeSearchFindsDocumentOutsideRecentWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-fts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KernelStore(path: root.appendingPathComponent("kernel.sqlite3").path)
        for i in 0..<1000 {
            let id = String(format: "doc-%04d", i)
            let title = i == 0 ? "unique-needle-alpha" : "filler \(i)"
            let body = i == 0 ? "unique-needle-alpha lives here" : "padding \(i)"
            try store.upsertKnowledgeDocument(
                id: id,
                title: title,
                record: .object(["title": .string(title), "body": .string(body)])
            )
        }
        let hits = try store.searchKnowledgeDocuments(query: "unique-needle-alpha", limit: 5)
        XCTAssertTrue(hits.contains { $0["id"]?.stringValue == "doc-0000" })
        let vectors = try store.database.scalarInt("SELECT COUNT(*) FROM knowledge_vectors;")
        if LocalEmbedding.isAvailable {
            XCTAssertGreaterThan(vectors, 0)
        }
    }

    func testRetiredLedgerAndWeChatSendStayClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-retired-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = try KernelCore(storePath: root.appendingPathComponent("kernel.sqlite3").path, workspace: root)
        let ledger = await core.handle(KernelRequest(
            operation: .runtimeLedgerUpsert,
            arguments: .object(["table": .string("task_plans"), "record": .object([:])])
        ))
        XCTAssertEqual(ledger.failure?.code, "not_found")
        let alias = await core.handle(KernelRequest(operation: .wechatLoginStart))
        XCTAssertEqual(alias.failure?.code, "not_found")
        let configure = await core.handle(KernelRequest(
            operation: .feishuConnectionConfigure,
            arguments: .object([:])
        ))
        XCTAssertNotEqual(configure.failure?.code, "not_found")
        XCTAssertEqual(
            MCPManager.splitToolName("mcp.team.alpha.echo", serverIDs: ["team", "team.alpha"])?.serverID,
            "team.alpha"
        )
        XCTAssertEqual(
            MCPManager.splitToolName("mcp.team.alpha.echo", serverIDs: ["team", "team.alpha"])?.toolName,
            "echo"
        )
    }

    func testPlaintextKeyStaysWhenReadBackFails() {
        XCTAssertEqual(PlaintextKeyMigration.retainedPlaintext(original: "secret") { _ in throw SQLiteError(message: "disk full") }, "secret")
        XCTAssertEqual(PlaintextKeyMigration.retainedPlaintext(original: "secret") { _ in "other" }, "secret")
        XCTAssertEqual(PlaintextKeyMigration.retainedPlaintext(original: "secret") { key in key }, "")
    }
}
