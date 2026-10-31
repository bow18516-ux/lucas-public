import AppKit
import Sparkle

/// Shared Sparkle updater. Only starts inside a real app bundle that has a
/// usable feed URL, so running the raw debug binary / placeholder builds
/// never shows Sparkle's English "Update Error!" modal.
@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    @Published private(set) var automaticallyChecks = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var latestVersion: String?
    /// Numeric `sparkle:version` of the newest feed item (nil until a successful parse).
    @Published private(set) var latestBuild: Int?
    @Published private(set) var updateAvailable = false
    @Published private(set) var releaseNotes: String?
    @Published private(set) var isCheckingFeed = false
    /// Set when the last feed fetch/parse failed; cleared on success.
    @Published private(set) var feedCheckError: String?
    /// True after at least one successful appcast parse this session.
    @Published private(set) var feedDidLoad = false

    let version: String
    let build: String
    let feedURL: String

    /// True when Info.plist still has the build-app.sh placeholder host.
    let isPlaceholderFeed: Bool

    private var controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    /// Short status for the Updates settings row when Sparkle is off.
    var unavailableReason: String {
        if ProcessInfo.processInfo.environment["LUCAS_DISABLE_UPDATER"] == "1" {
            return "已禁用自动更新"
        }
        if feedURL.isEmpty {
            return "当前包未写入更新地址"
        }
        if isPlaceholderFeed {
            return "开发构建未配置更新服务器"
        }
        return "开发模式下不会检查更新"
    }

    private init() {
        let info = Bundle.main.infoDictionary
        version = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        build = info?["CFBundleVersion"] as? String ?? "0"
        feedURL = info?["SUFeedURL"] as? String ?? ""
        isPlaceholderFeed = Self.isPlaceholder(feedURL)

        guard
            Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
            !feedURL.isEmpty,
            !isPlaceholderFeed,
            ProcessInfo.processInfo.environment["LUCAS_DISABLE_UPDATER"] != "1"
        else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        lastCheck = controller.updater.lastUpdateCheckDate
    }

    func checkForUpdates() {
        guard let controller else {
            presentUnavailableAlert()
            return
        }
        controller.checkForUpdates(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refresh()
        }
    }

    func setAutomaticallyChecks(_ value: Bool) {
        controller?.updater.automaticallyChecksForUpdates = value
        automaticallyChecks = value
    }

    func refresh() {
        guard let controller else { return }
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        lastCheck = controller.updater.lastUpdateCheckDate
    }

    /// Prefer Sparkle's runtime override (UserDefaults `SUFeedURL`) when it looks
    /// like a real feed. Drill leftovers on 127.0.0.1 / localhost / example.com
    /// must not silently replace Info.plist and fake an empty "no updates" state.
    private var resolvedFeedURL: String {
        if let override = UserDefaults.standard.string(forKey: "SUFeedURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           !Self.isUnusableFeedURL(override) {
            return override
        }
        return feedURL
    }

    /// Reads the appcast directly so the settings page can show the latest
    /// version and a badge without opening Sparkle's update dialog.
    func refreshFeed() async {
        let urlString = resolvedFeedURL
        guard !isPlaceholderFeed, !urlString.isEmpty, let url = URL(string: urlString) else {
            if isPlaceholderFeed || feedURL.isEmpty {
                feedCheckError = unavailableReason
            }
            return
        }
        // Allow the settings page to read the feed even if Sparkle controller
        // failed to start; still surface unavailable separately via isAvailable.
        isCheckingFeed = true
        feedCheckError = nil
        defer { isCheckingFeed = false }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                feedCheckError = "更新源返回 HTTP \(http.statusCode)"
                updateAvailable = false
                return
            }
            let xml = String(decoding: data, as: UTF8.self)

            guard let newest = Self.newestFeedItem(in: xml) else {
                feedCheckError = "更新源无法解析（未找到版本条目）"
                updateAvailable = false
                return
            }

            let short = newest.shortVersion ?? String(newest.build)
            latestVersion = short
            latestBuild = newest.build
            let localBuild = Int(build) ?? 0
            updateAvailable = newest.build > localBuild
            releaseNotes = newest.notes
            feedDidLoad = true
            feedCheckError = nil
            lastCheck = Date()
        } catch {
            feedCheckError = "检查更新失败：\(error.localizedDescription)"
            // Do not pretend we are up to date when the feed never loaded.
            if !feedDidLoad {
                updateAvailable = false
            }
        }
    }

    /// Display label for the newest feed item, e.g. `0.5.6 (202610311011)`.
    var latestVersionLabel: String? {
        guard let short = latestVersion else { return nil }
        if let build = latestBuild {
            return "\(short) (\(build))"
        }
        return short
    }

    private func presentUnavailableAlert() {
        let alert = NSAlert()
        alert.messageText = "暂时无法检查更新"
        if isPlaceholderFeed {
            alert.informativeText = "当前是开发构建，更新地址仍是占位域名，不会去连线上更新服务器。正式安装包检查更新即可。"
        } else if feedURL.isEmpty {
            alert.informativeText = "当前包没有写入更新地址（SUFeedURL）。"
        } else {
            alert.informativeText = unavailableReason
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private static func isPlaceholder(_ url: String) -> Bool {
        isUnusableFeedURL(url)
    }

    private static func isUnusableFeedURL(_ url: String) -> Bool {
        let lowered = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.isEmpty { return true }
        if lowered.contains("example.com") { return true }
        if lowered.contains("127.0.0.1") { return true }
        if lowered.contains("localhost") { return true }
        return false
    }

    private struct FeedItem {
        let build: Int
        let shortVersion: String?
        let notes: String?
    }

    /// Pick the `<item>` with the highest `sparkle:version` (build). Appcasts
    /// usually list newest first, so taking `shorts.last` wrongly yields the
    /// oldest marketing version (e.g. 0.5.3 while newest build is 0.5.5).
    private static func newestFeedItem(in xml: String) -> FeedItem? {
        let bodies = matches(#"<item>(.*?)</item>"#, in: xml)
        var best: FeedItem?
        for body in bodies {
            guard let build = matches(#"<sparkle:version>(\d+)</sparkle:version>"#, in: body)
                .compactMap(Int.init)
                .first else { continue }
            let short = matches(
                #"<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>"#,
                in: body
            ).first
            var notes: String?
            if let notesRange = body.range(
                of: #"<description>[^<]*<!\[CDATA\[(.*?)\]\]>[^<]*</description>"#,
                options: .regularExpression
            ) {
                let raw = String(body[notesRange])
                if let start = raw.range(of: "<![CDATA[")?.upperBound,
                   let end = raw.range(of: "]]>", range: start..<raw.endIndex)?.lowerBound {
                    let plain = plainText(from: String(raw[start..<end]))
                    notes = plain.isEmpty ? nil : plain
                }
            }
            if best == nil || build > best!.build {
                best = FeedItem(build: build, shortVersion: short, notes: notes)
            }
        }
        return best
    }

    private static func plainText(from html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</(p|li|div|h[1-6])>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }
}
