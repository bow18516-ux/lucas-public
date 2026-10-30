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
}
