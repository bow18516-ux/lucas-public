import CryptoKit
import Foundation

/// Tracks the hash of a file copied out of the bundle. An unchanged copy is
/// refreshed when the bundle changes. A file whose bytes differ from that hash
/// is treated as a user edit and left alone.
public enum SeededOverride {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sidecar(for file: URL) -> URL {
        URL(fileURLWithPath: file.path + ".seed-sha256")
    }

    public static func text(override: URL, bundled: URL?, createIfMissing: Bool = false) -> String? {
        let fm = FileManager.default
        let bundledData = bundled.flatMap { try? Data(contentsOf: $0) }
        if !fm.fileExists(atPath: override.path) {
            guard let bundledData else { return nil }
            guard createIfMissing else { return String(data: bundledData, encoding: .utf8) }
            try? fm.createDirectory(at: override.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? bundledData.write(to: override, options: .atomic)
            writeHash(sha256Hex(bundledData), for: override)
            return String(data: bundledData, encoding: .utf8)
        }
        guard let overrideData = try? Data(contentsOf: override) else { return nil }
        let overrideHash = sha256Hex(overrideData)
        let recorded = (try? String(contentsOf: sidecar(for: override), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let bundledData, let recorded, !recorded.isEmpty, overrideHash == recorded, sha256Hex(bundledData) != recorded {
            try? bundledData.write(to: override, options: .atomic)
            writeHash(sha256Hex(bundledData), for: override)
            return String(data: bundledData, encoding: .utf8)
        }
        if (recorded == nil || recorded?.isEmpty == true), let bundledData, overrideHash == sha256Hex(bundledData) {
            writeHash(overrideHash, for: override)
        }
        return String(data: overrideData, encoding: .utf8)
    }

    private static func writeHash(_ hash: String, for file: URL) {
        try? Data(hash.utf8).write(to: sidecar(for: file), options: .atomic)
    }
}
