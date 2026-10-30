import AppKit
import Sparkle

/// Shared Sparkle updater. Only starts inside a real app bundle that has a
/// feed URL, so running the raw debug binary never shows modal errors.
@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    @Published private(set) var automaticallyChecks = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var latestVersion: String?
    @Published private(set) var updateAvailable = false
    @Published private(set) var releaseNotes: String?
    @Published private(set) var isCheckingFeed = false

    let version: String
    let build: String
    let feedURL: String

    private var controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    private init() {
        let info = Bundle.main.infoDictionary
        version = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        build = info?["CFBundleVersion"] as? String ?? "0"
        feedURL = info?["SUFeedURL"] as? String ?? ""

        guard
            Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
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
        controller?.checkForUpdates(nil)
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

    /// Reads the appcast directly so the settings page can show the latest
    /// version and a badge without opening Sparkle's update dialog.
    func refreshFeed() async {
        guard isAvailable, let url = URL(string: feedURL) else { return }
        isCheckingFeed = true
        defer { isCheckingFeed = false }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, _) = try await URLSession.shared.data(for: request)
            let xml = String(decoding: data, as: UTF8.self)

            let builds = Self.matches(#"<sparkle:version>(\d+)</sparkle:version>"#, in: xml).compactMap(Int.init)
            let shorts = Self.matches(#"<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>"#, in: xml)
            guard let newest = builds.max() else { return }

            latestVersion = shorts.last ?? String(newest)
            updateAvailable = newest > (Int(build) ?? 0)

            if let notesRange = xml.range(of: #"<description>[^<]*<!\[CDATA\[(.*?)\]\]>[^<]*</description>"#, options: .regularExpression) {
                let raw = String(xml[notesRange])
                if let start = raw.range(of: "<![CDATA[")?.upperBound,
                   let end = raw.range(of: "]]>", range: start..<raw.endIndex)?.lowerBound {
                    releaseNotes = Self.plainText(from: String(raw[start..<end]))
                }
            }
        } catch {
            // Feed may not exist yet; keep the last known values.
        }
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
