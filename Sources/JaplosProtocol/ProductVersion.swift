import Foundation

/// Single marketing version for the app, daemon, and MCP client info.
public enum ProductVersion {
    public static let marketing = "0.5.4"
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
