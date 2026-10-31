import XCTest
@testable import JaplosProtocol

final class SpeechSegmenterTests: XCTestCase {
    func testEmitsFirstSentenceBeforeReplyEnds() {
        var s = SpeechSegmenter()
        XCTAssertEqual(s.append("好的，我"), [])
        XCTAssertEqual(s.append("查过了。明天"), ["好的，我查过了。"])
        XCTAssertEqual(s.append("多云"), [])
        XCTAssertEqual(s.finish(), ["明天多云。"])
    }

    func testSkipsCodeFenceAndMarkdown() {
        var s = SpeechSegmenter()
        var out = s.append("## 结果\n```swift\nlet a = 1。\n```\n- **完成**了")
        out += s.finish()
        XCTAssertEqual(out, ["结果。", "完成了。"])
    }

    func testCapsTotal() {
        var s = SpeechSegmenter(maxTotal: 5)
        XCTAssertEqual(s.append("一二三。四五六。"), ["一二三。", "四"])
        XCTAssertEqual(s.finish(), [])
    }

    func testPushToTalkGate() {
        func gate(_ text: String, ime: Bool = false, mods: Bool = false) -> Bool {
            PushToTalkGate.shouldHandle(isSpace: true, hasModifiers: mods, appActive: true, overlayPresented: false,
                                        composerText: text, imeComposing: ime, focusInOtherTextField: false)
        }
        XCTAssertTrue(gate(""))
        XCTAssertFalse(gate("hello"))
        XCTAssertFalse(gate("", ime: true))
        XCTAssertFalse(gate("", mods: true))
    }
}
