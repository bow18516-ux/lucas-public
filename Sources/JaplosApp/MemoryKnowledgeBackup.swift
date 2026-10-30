import AppKit
import Foundation
import JaplosProtocol

/// On-disk bundle for memories + knowledge_documents + KnowledgeFiles copies.
/// Format: `lucas.memory-knowledge.v1` — round-trip via id-preserving upserts.
enum MemoryKnowledgeBackup {
    static let formatID = "lucas.memory-knowledge.v1"
    static let manifestName = "manifest.json"
    static let memoriesName = "memories.json"
    static let knowledgeName = "knowledge_documents.json"
    static let filesDirName = "KnowledgeFiles"

    static var localKnowledgeFilesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lucas/KnowledgeFiles", isDirectory: true)
    }

    // MARK: - Panels

    @MainActor
    static func pickExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择导出位置"
        panel.message = "将在此文件夹内创建 Lucas 记忆/知识库备份目录"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    @MainActor
    static func pickImportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择备份文件夹"
        panel.message = "选择含 manifest.json 的 Lucas 备份目录（或其上一级）"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Resolve a user-picked URL to the actual backup root (folder that has manifest.json).
    static func resolveBackupRoot(_ url: URL) -> URL? {
        let fm = FileManager.default
        let direct = url.appendingPathComponent(manifestName)
        if fm.fileExists(atPath: direct.path) { return url }
        // Allow picking the parent that contains a single Lucas-backup-* child.
        if let kids = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            let matches = kids.filter { fm.fileExists(atPath: $0.appendingPathComponent(manifestName).path) }
            if matches.count == 1 { return matches[0] }
            if let named = matches.first(where: { $0.lastPathComponent.hasPrefix("Lucas-backup") }) {
                return named
            }
        }
        return nil
    }

    static func makeExportDirectoryName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "Lucas-backup-\(f.string(from: date))"
    }

    // MARK: - JSON helpers

    static func writeJSON(_ value: JSONValue, to url: URL) throws {
        let compact = try ProtocolCoding.encode(value)
        let obj = try JSONSerialization.jsonObject(with: compact)
        let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try pretty.write(to: url, options: .atomic)
    }

    static func readJSON(from url: URL) throws -> JSONValue {
        let data = try Data(contentsOf: url)
        return try ProtocolCoding.decode(JSONValue.self, from: data)
    }
}

