import XCTest
@testable import JaplosRuntime

final class SeedAndProbeTests: XCTestCase {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucas-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    func testUneditedSeedRefreshesWhenBundleChanges() throws {
        let root = try temporaryRoot("seed")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundled.md")
        let override = root.appendingPathComponent("override.md")
        try Data("old".utf8).write(to: bundled)
        try Data("old".utf8).write(to: override)
        try Data(SeededOverride.sha256Hex(Data("old".utf8)).utf8).write(to: SeededOverride.sidecar(for: override))
        try Data("new from bundle".utf8).write(to: bundled)
        let text = SeededOverride.text(override: override, bundled: bundled)
        XCTAssertEqual(text, "new from bundle")
        XCTAssertEqual(try String(contentsOf: override, encoding: .utf8), "new from bundle")
    }

    func testEditedSeedIsKept() throws {
        let root = try temporaryRoot("seed-edit")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundled.md")
        let override = root.appendingPathComponent("override.md")
        try Data("bundled".utf8).write(to: bundled)
        try Data("user edit".utf8).write(to: override)
        try Data(SeededOverride.sha256Hex(Data("bundled".utf8)).utf8).write(to: SeededOverride.sidecar(for: override))
        let text = SeededOverride.text(override: override, bundled: bundled)
        XCTAssertEqual(text, "user edit")
    }

    // MARK: - A1: legacy copies without a sidecar

    /// A prompt copied out by an older release has no `.seed-sha256` file. If
    /// its bytes match a version recorded in the seed manifest, it was never
    /// edited and must be replaced by the bundled version.
    func testLegacyCopyWithoutSidecarIsRefreshed() throws {
        let root = try temporaryRoot("seed-legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        let relative = "Prompts/communication/wechat.md"
        let bundled = root.appendingPathComponent("bundle").appendingPathComponent(relative)
        let override = root.appendingPathComponent("home").appendingPathComponent(relative)
        try write("legacy release copy", to: override)
        try write("new from bundle", to: bundled)
        let legacyHash = SeededOverride.sha256Hex(Data("legacy release copy".utf8))
        let manifest = SeedManifest(entries: [relative: [legacyHash]])

        let text = SeededOverride.text(
            override: override,
            bundled: bundled,
            relativePath: relative,
            manifest: manifest
        )

        XCTAssertEqual(text, "new from bundle")
        XCTAssertEqual(try String(contentsOf: override, encoding: .utf8), "new from bundle")
        XCTAssertEqual(
            try String(contentsOf: SeededOverride.sidecar(for: override), encoding: .utf8),
            SeededOverride.sha256Hex(Data("new from bundle".utf8))
        )
    }

    /// Content no release ever shipped is a user edit and must survive.
    func testUserEditedFileWithoutSidecarIsKept() throws {
        let root = try temporaryRoot("seed-user-edit")
        defer { try? FileManager.default.removeItem(at: root) }
        let relative = "Prompts/communication/wechat.md"
        let bundled = root.appendingPathComponent("bundle").appendingPathComponent(relative)
        let override = root.appendingPathComponent("home").appendingPathComponent(relative)
        try write("my own wording", to: override)
        try write("new from bundle", to: bundled)
        let manifest = SeedManifest(entries: [
            relative: [SeededOverride.sha256Hex(Data("some old release".utf8))],
        ])

        let text = SeededOverride.text(
            override: override,
            bundled: bundled,
            relativePath: relative,
            manifest: manifest
        )

        XCTAssertEqual(text, "my own wording")
        XCTAssertEqual(try String(contentsOf: override, encoding: .utf8), "my own wording")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: SeededOverride.sidecar(for: override).path),
            "a user-edited file must not get a sidecar, or a later bundle change would overwrite it"
        )
    }

    /// Anchors the generated manifest to the copy that 0.5.4 actually left on
    /// disk: `communication/wechat.md` at commit 1777439.
    func testBundledSeedManifestCoversTheShippedLegacyPrompt() {
        XCTAssertGreaterThan(SeedManifest.shared.entries.count, 50)
        XCTAssertTrue(
            SeedManifest.shared.contains(
                relativePath: "Prompts/communication/wechat.md",
                hash: "9eff42cabe69090be3338392aa8d8b3ca3103755088a899d96fc08a8a80953bb"
            )
        )
        XCTAssertTrue(
            SeedManifest.shared.contains(
                relativePath: "Sources/JaplosRuntime/Resources/Injection/scenes.json",
                hash: "3a7d9b007aa5f1db46eb8dbbe8872bc968ad87c283908dad8daf16b912d017d5"
            ),
            "repository-style paths must normalize to the same key"
        )
    }

    /// Rehearsal against a real release tree:
    ///   cp -R "$HOME/Library/Application Support/Lucas" /tmp/lucas-home-copy
    ///   LUCAS_PROBE_HOME=/tmp/lucas-home-copy swift test --filter testInstalledLegacyCopyRefreshes
    /// Skipped in normal runs.
    func testInstalledLegacyCopyRefreshesFromBundledPrompts() throws {
        guard let probe = ProcessInfo.processInfo.environment["LUCAS_PROBE_HOME"], !probe.isEmpty else {
            throw XCTSkip("set LUCAS_PROBE_HOME to a copy of ~/Library/Application Support/Lucas")
        }
        setenv("LUCAS_CLONE_HOME", probe, 1)
        defer { unsetenv("LUCAS_CLONE_HOME") }

        let relative = "Prompts/communication/wechat.md"
        let override = URL(fileURLWithPath: probe).appendingPathComponent(relative)
        let before = try String(contentsOf: override, encoding: .utf8)
        guard let bundledRoot = PromptLibrary.bundledPromptsRoot() else {
            return XCTFail("bundled prompts missing")
        }
        let bundled = try String(contentsOf: bundledRoot.appendingPathComponent("communication/wechat.md"), encoding: .utf8)
        XCTAssertNotEqual(before, bundled, "the probe copy must actually be the stale release version")

        guard let loaded = PromptLibrary.load("communication/wechat.md") else {
            return XCTFail("PromptLibrary.load returned nil")
        }
        XCTAssertTrue(loaded.contains("iLink can actually deliver"))
        XCTAssertEqual(try String(contentsOf: override, encoding: .utf8), bundled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: SeededOverride.sidecar(for: override).path))
    }

    func testProbeDropsStoredKeyWhenBaseURLChanges() {
        XCTAssertEqual(
            ModelProbeKey.apiKey(
                storedBaseURL: "http://127.0.0.1:9/v1",
                storedKey: "stored-secret",
                requestedBaseURL: "http://127.0.0.1:10/v1",
                requestedKey: ""
            ),
            ""
        )
        XCTAssertEqual(
            ModelProbeKey.apiKey(
                storedBaseURL: "http://127.0.0.1:9/v1/",
                storedKey: "stored-secret",
                requestedBaseURL: "http://127.0.0.1:9/v1",
                requestedKey: ""
            ),
            "stored-secret"
        )
    }
}
