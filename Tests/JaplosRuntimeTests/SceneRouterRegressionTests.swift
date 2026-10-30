import XCTest
@testable import JaplosRuntime

final class SceneRouterRegressionTests: XCTestCase {
    /// Desktop-file intents must NOT route to screenshot (bare 桌面/截/屏幕 removed).
    private let desktopFilePhrases = [
        "桌面有个文件去读",
        "帮我读一下桌面上的那个文件",
        "把文件存到桌面",
        "桌面文件夹里有什么",
        "读取桌面备注.txt",
        "我的地盘有一个文件你去读一下",
        "把结果保存到桌面",
        "桌面上的文件打开看看",
        "列一下桌面目录",
        "写一个文件到桌面",
    ]

    private let screenshotPhrases = [
        "帮我截屏",
        "截个图",
        "屏幕截图一下",
        "screenshot please",
    ]

    private let screenshotPattern = "截图|截屏|screenshot|screencapture|屏幕截图|截个图|截一下屏"
    private let filesystemPattern = "文件|目录|文件夹|读取|写入|保存到|桌面.{0,8}文件|文件.{0,8}桌面|读一下|存到"

    func testDesktopFilePhrasesDoNotMatchScreenshotPattern() throws {
        let shot = try NSRegularExpression(pattern: screenshotPattern, options: [.caseInsensitive])
        for phrase in desktopFilePhrases {
            let range = NSRange(phrase.startIndex..<phrase.endIndex, in: phrase)
            XCTAssertNil(shot.firstMatch(in: phrase, range: range), "screenshot should not match: \(phrase)")
        }
    }

    func testDesktopFilePhrasesMatchFilesystemPattern() throws {
        let fs = try NSRegularExpression(pattern: filesystemPattern, options: [.caseInsensitive])
        for phrase in desktopFilePhrases {
            let range = NSRange(phrase.startIndex..<phrase.endIndex, in: phrase)
            XCTAssertNotNil(fs.firstMatch(in: phrase, range: range), "filesystem should match: \(phrase)")
        }
    }

    func testScreenshotPhrasesStillMatch() throws {
        let shot = try NSRegularExpression(pattern: screenshotPattern, options: [.caseInsensitive])
        for phrase in screenshotPhrases {
            let range = NSRange(phrase.startIndex..<phrase.endIndex, in: phrase)
            XCTAssertNotNil(shot.firstMatch(in: phrase, range: range), phrase)
        }
    }

    func testSceneRouterMatchNotScreenshotForDesktopFiles() {
        for phrase in desktopFilePhrases {
            let scene = SceneRouter.match(phrase)
            XCTAssertNotEqual(scene?.id, "ED6B866C-8918-473A-83F7-853C548F087F", phrase)
            XCTAssertNotEqual(scene?.name, "截屏", phrase)
            // Prefer filesystem when matched
            if let scene {
                XCTAssertFalse(scene.tools.contains("system.screen.capture") && !scene.tools.contains("system.filesystem"),
                               "unexpected screenshot-only scene for \(phrase): \(scene.id)")
            }
        }
    }
}
