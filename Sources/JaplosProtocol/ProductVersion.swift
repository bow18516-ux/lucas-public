import Foundation

/// Single marketing version for the app, daemon, and MCP client info.
public enum ProductVersion {
    public static let marketing = "0.5.8"
}

/// Build identity of the process: the packaged `CFBundleVersion` (not the
/// marketing version, which two different builds can share) plus the exact
/// executable that is running.
public enum ProductBuild {
    /// `CFBundleVersion` of the enclosing bundle, or `"dev"` when the process
    /// runs straight out of `.build` with no Info.plist.
    public static var current: String {
        guard let value = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
              !value.isEmpty
        else { return "dev" }
        return value
    }

    public static var executablePath: String {
        let url = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return url.resolvingSymlinksInPath().path
    }

    /// Modification time of the executable, so replacing `lucasd` in place
    /// (same path, same marketing version) still forces a restart.
    public static var executableModifiedAt: Double? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: executablePath),
              let date = attributes[.modificationDate] as? Date
        else { return nil }
        return date.timeIntervalSince1970
    }
}

/// Decides whether the daemon that answered `kernel.ping` is the same build
/// the app just launched from. Any mismatch means "restart it".
public enum DaemonHandshake {
    public static func matches(
        appBuild: String?,
        daemonBuild: String?,
        expectedPath: String?,
        daemonPath: String?,
        expectedModifiedAt: Double?,
        daemonModifiedAt: Double?,
        tolerance: Double = 1.0
    ) -> Bool {
        guard let appBuild, let daemonBuild, appBuild == daemonBuild else { return false }
        if let expectedPath, let daemonPath {
            let expected = URL(fileURLWithPath: expectedPath).resolvingSymlinksInPath().path
            let actual = URL(fileURLWithPath: daemonPath).resolvingSymlinksInPath().path
            if expected != actual { return false }
        }
        if let expectedModifiedAt, let daemonModifiedAt,
           abs(expectedModifiedAt - daemonModifiedAt) > tolerance {
            return false
        }
        return true
    }
}

/// Keeps a plaintext secret until the secret store confirms it read back.
public enum PlaintextKeyMigration {
    public static func retainedPlaintext(
        original: String,
        persist: (String) throws -> String?
    ) -> String {
        do {
            let readBack = try persist(original)
            return readBack == original ? "" : original
        } catch {
            return original
        }
    }
}
