import XCTest
@testable import JaplosKernel
import JaplosProtocol

/// C6: `status()`/`verify()` read login state that `connect`/`disconnect`
/// mutate. Run under `swift test --sanitize=thread --filter WeChat`.
final class WeChatChannelRaceTests: XCTestCase {
    func testStatusAndVerifyAreRaceFreeWhileStateChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-wechat-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KernelStore(path: root.appendingPathComponent("kernel.sqlite3").path)
        let channel = WeChatChannel(store: store, supportDirectory: root)
        // Put the channel into a state where `verify` actually takes the
        // verification branch instead of returning early.
        try store.upsertWeChatConnection(
            id: "login-race",
            state: WeChatChannel.State.awaitingScan.rawValue,
            record: .object(["event": .string("test")])
        )

        let group = DispatchGroup()
        for _ in 0..<4 {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                for _ in 0..<300 {
                    _ = try? channel.status()
                }
            }
        }
        for _ in 0..<300 {
            _ = try? channel.verify(code: "123456")
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
    }
}
