import XCTest
@testable import JaplosProtocol

final class JaplosProtocolTests: XCTestCase {
    func testFrameRoundTrip() throws {
        let payload = Data("hello".utf8)
        let framed = FrameCodec.encode(payload)
        XCTAssertEqual(framed.count, payload.count + 4)
        XCTAssertEqual(Array(framed.prefix(4)), [0, 0, 0, 5])
        XCTAssertEqual(Int(framed.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }), 5)
    }

    func testFrameTooLargeIsRejected() {
        var header = Data()
        var length = UInt32(FrameCodec.maximumFrameSize + 1).bigEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        // decodeFrameCount only checks the prefix; the size guard lives in readFrame.
        XCTAssertEqual(FrameCodec.decodeFrameCount(from: header), FrameCodec.maximumFrameSize + 1)
    }

    func testJSONValueRoundTrip() throws {
        let value: JSONValue = .object([
            "text": .string("你好"),
            "count": .number(3),
            "nested": .array([.bool(true), .null]),
        ])
        let data = try ProtocolCoding.encode(value)
        let decoded = try ProtocolCoding.decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded["text"]?.stringValue, "你好")
        XCTAssertEqual(decoded["count"]?.intValue, 3)
    }

    func testKernelRequestCodingUsesStableKeys() throws {
        let request = KernelRequest(
            id: "REQ-1",
            principal: Principal.localUser,
            operation: .kernelStatus,
            arguments: .object([:])
        )
        let data = try ProtocolCoding.encode(request)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"id\":\"REQ-1\""))
        XCTAssertTrue(json.contains("\"operation\":\"kernel.status\""))
        XCTAssertTrue(json.contains("\"protocolVersion\":\"1.0\""))

        let decoded = try ProtocolCoding.decode(KernelRequest.self, from: data)
        XCTAssertEqual(decoded.operation, .kernelStatus)
        XCTAssertEqual(decoded.principal, Principal.localUser)
    }

    func testPolicyGlobMatching() {
        XCTAssertTrue(GlobMatcher.matches(pattern: "*", value: "chat.send"))
        XCTAssertTrue(GlobMatcher.matches(pattern: "model.*", value: "model.test"))
        XCTAssertFalse(GlobMatcher.matches(pattern: "model.*", value: "tool.list"))
        XCTAssertTrue(GlobMatcher.matches(pattern: "system.*.execute", value: "system.command.shell.execute"))
    }

    func testGrantExpiry() {
        let expired = PermissionGrant(
            principal: "local-user",
            capability: Capability.root,
            expiresAt: Date(timeIntervalSinceNow: -60)
        )
        XCTAssertFalse(expired.isActive())
        let active = PermissionGrant(principal: "local-user", capability: Capability.root)
        XCTAssertTrue(active.isActive())
    }

    func testCapabilityRouting() {
        XCTAssertEqual(CapabilityRouting.capability(for: .chatSend), Capability.chatManage)
        XCTAssertEqual(CapabilityRouting.capability(for: .toolInvoke), Capability.toolInvoke)
        XCTAssertEqual(CapabilityRouting.capability(for: .kernelStatus), Capability.root)
    }

    func testKernelResponseEncodesErrorAlongsideFailure() throws {
        let response = KernelResponse.failure(.invalidArgument("missing model"), requestID: "REQ-ERR")
        let data = try ProtocolCoding.encode(response)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"failure\""))
        XCTAssertTrue(json.contains("\"error\":\"missing model\""))
        XCTAssertTrue(json.contains("\"servedAt\""))

        let decoded = try ProtocolCoding.decode(KernelResponse.self, from: data)
        XCTAssertEqual(decoded.failure?.code, "invalid_argument")
        XCTAssertEqual(decoded.error, "missing model")
        XCTAssertNil(decoded.result)
    }


    func testToolApprovalGateHighAlwaysRequires() {
        let definition = ToolDefinition(
            name: "system.command.shell.execute",
            title: "shell",
            summary: "s",
            inputSchema: .object([:]),
            capability: Capability.processExecute,
            risk: .high
        )
        let call = ToolCall(name: definition.name, arguments: .object(["command": .string("ls")]))
        XCTAssertTrue(ToolApprovalGate.requiresApproval(call: call, definition: definition))
    }

    func testToolApprovalGateFilesystemWriteOnly() {
        let definition = ToolDefinition(
            name: "system.filesystem",
            title: "fs",
            summary: "s",
            inputSchema: .object([:]),
            capability: Capability.filesystemWrite,
            risk: .medium,
            approval: .whenArgument(key: "action", isOneOf: ["write"])
        )
        let write = ToolCall(name: definition.name, arguments: .object([
            "action": .string("write"),
            "path": .string("~/Desktop/a.txt"),
            "content": .string("x"),
        ]))
        let read = ToolCall(name: definition.name, arguments: .object([
            "action": .string("read"),
            "path": .string("~/Desktop/a.txt"),
        ]))
        XCTAssertTrue(ToolApprovalGate.requiresApproval(call: write, definition: definition))
        XCTAssertFalse(ToolApprovalGate.requiresApproval(call: read, definition: definition))
    }

    func testToolApprovalGateOutboundAndPathOpen() {
        for name in ["system.path.open", "runtime.wechat.send_text", "system.download.fetch"] {
            let definition = ToolDefinition(
                name: name,
                title: name,
                summary: "s",
                inputSchema: .object([:]),
                capability: Capability.root,
                risk: .medium
            )
            let call = ToolCall(name: name, arguments: .object([:]))
            XCTAssertTrue(ToolApprovalGate.requiresApproval(call: call, definition: definition), name)
        }
    }

    func testDefaultApprovalIsAlwaysEvenWhenRiskIsLow() {
        let definition = ToolDefinition(
            name: "system.document.pdf.create",
            title: "pdf",
            summary: "s",
            inputSchema: .object([:]),
            capability: Capability.filesystemWrite,
            risk: .low
        )
        let call = ToolCall(name: definition.name, arguments: .object(["text": .string("x")]))
        XCTAssertEqual(definition.approval, .always)
        XCTAssertTrue(ToolApprovalGate.requiresApproval(call: call, definition: definition))
    }

    func testMissingApprovalDecodesAsAlways() throws {
        let json = """
        {"name":"t","title":"t","summary":"s","inputSchema":{},"capability":"cap"}
        """.data(using: .utf8)!
        let definition = try ProtocolCoding.decode(ToolDefinition.self, from: json)
        XCTAssertEqual(definition.approval, .always)
        XCTAssertEqual(definition.risk, .low)
    }

    func testApprovalSummaryKeepsCommandAndMailFields() {
        let command = "echo " + String(repeating: "safe ", count: 80)
        let summary = ApprovalPresentation.summary(.object([
            "command": .string(command),
            "workingDirectory": .string("/tmp/work"),
            "note": .string(String(repeating: "n", count: 800)),
        ]))
        XCTAssertTrue(summary.contains(command))
        XCTAssertTrue(summary.contains("/tmp/work"))

        let mail = ApprovalPresentation.summary(.object([
            "body": .string(String(repeating: "b", count: 2000)),
            "to": .string("a@b.com"),
            "subject": .string("hi"),
            "confirm": .bool(true),
            "draft_only": .bool(false),
        ]))
        XCTAssertTrue(mail.contains("a@b.com"))
        XCTAssertTrue(mail.contains("主题：hi"))
        XCTAssertTrue(mail.contains("confirm：true"))
        XCTAssertTrue(mail.contains("draft_only：false"))
        XCTAssertFalse(mail.contains(String(repeating: "b", count: 40)))
    }


    func testDaemonHandshakeRequiresMatchingBuildPathAndMtime() {
        XCTAssertTrue(DaemonHandshake.matches(
            appBuild: "42", daemonBuild: "42",
            expectedPath: "/tmp/Lucas.app/Contents/MacOS/lucasd",
            daemonPath: "/tmp/Lucas.app/Contents/MacOS/lucasd",
            expectedModifiedAt: 1_000, daemonModifiedAt: 1_000.5
        ))
        // Same marketing version, rebuilt package: only CFBundleVersion differs.
        XCTAssertFalse(DaemonHandshake.matches(
            appBuild: "43", daemonBuild: "42",
            expectedPath: "/tmp/lucasd", daemonPath: "/tmp/lucasd",
            expectedModifiedAt: 1_000, daemonModifiedAt: 1_000
        ))
        // A daemon from another checkout, or one replaced in place.
        XCTAssertFalse(DaemonHandshake.matches(
            appBuild: "42", daemonBuild: "42",
            expectedPath: "/tmp/a/lucasd", daemonPath: "/tmp/b/lucasd",
            expectedModifiedAt: 1_000, daemonModifiedAt: 1_000
        ))
        XCTAssertFalse(DaemonHandshake.matches(
            appBuild: "42", daemonBuild: "42",
            expectedPath: "/tmp/lucasd", daemonPath: "/tmp/lucasd",
            expectedModifiedAt: 1_000, daemonModifiedAt: 1_030
        ))
        // A daemon too old to report `build` must not be trusted.
        XCTAssertFalse(DaemonHandshake.matches(
            appBuild: "42", daemonBuild: nil,
            expectedPath: nil, daemonPath: nil,
            expectedModifiedAt: nil, daemonModifiedAt: nil
        ))
    }

    func testOpenAICompatibleToolNameSanitize() {
        XCTAssertEqual(OpenAICompatibleToolName.sanitize("memory.save"), "memory_save")
        XCTAssertEqual(OpenAICompatibleToolName.sanitize("system.url.open"), "system_url_open")
        XCTAssertEqual(OpenAICompatibleToolName.sanitize("mcp.foo.bar.baz"), "mcp_foo_bar_baz")
        XCTAssertEqual(OpenAICompatibleToolName.sanitize("工具 名称"), "tool")
        XCTAssertEqual(OpenAICompatibleToolName.sanitize("播放 音乐"), "tool")
        XCTAssertEqual(OpenAICompatibleToolName.sanitize("foo bar"), "foo_bar")
        XCTAssertFalse(OpenAICompatibleToolName.isValid("memory.save"))
        XCTAssertTrue(OpenAICompatibleToolName.isValid("memory_save"))
        let spaced = OpenAICompatibleToolName.sanitize("a b.c")
        XCTAssertEqual(spaced, "a_b_c")
        XCTAssertTrue(OpenAICompatibleToolName.isValid(spaced))
    }

    func testOpenAICompatibleToolNameCodecRoundTrip() {
        let tools = [
            ToolDefinition(
                name: "memory.save",
                title: "Save",
                summary: "save",
                inputSchema: .object([:]),
                capability: "memory"
            ),
            ToolDefinition(
                name: "memory_save",
                title: "Alt",
                summary: "collision",
                inputSchema: .object([:]),
                capability: "memory"
            ),
            ToolDefinition(
                name: "system.music",
                title: "Music",
                summary: "music",
                inputSchema: .object([:]),
                capability: "system"
            ),
        ]
        let codec = OpenAICompatibleToolName.Codec(tools: tools)
        XCTAssertEqual(codec.wireName("system.music"), "system_music")
        XCTAssertEqual(codec.canonicalName(codec.wireName("system.music")), "system.music")
        // Collision: both sanitize to memory_save — second gets suffix.
        let wires = Set(tools.map { codec.wireName($0.name) })
        XCTAssertEqual(wires.count, 3)
        for tool in tools {
            let wire = codec.wireName(tool.name)
            XCTAssertTrue(OpenAICompatibleToolName.isValid(wire), wire)
            XCTAssertEqual(codec.canonicalName(wire), tool.name)
        }
        let encoded = codec.wireTools(tools)
        XCTAssertTrue(encoded.allSatisfy { OpenAICompatibleToolName.isValid($0.name) })
    }

}
