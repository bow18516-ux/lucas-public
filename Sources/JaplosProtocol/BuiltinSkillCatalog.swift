import Foundation

public struct BuiltinSkill: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var body: String
    public var directory: URL
    public var source: String

    public init(name: String, description: String, body: String, directory: URL, source: String) {
        self.name = name
        self.description = description
        self.body = body
        self.directory = directory
        self.source = source
    }

    public var summaryLine: String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 120 { return trimmed }
        let index = trimmed.index(trimmed.startIndex, offsetBy: 120)
        return String(trimmed[..<index]) + "…"
    }
}

/// Loads Cursor/Japlos-style `SKILL.md` packs (YAML frontmatter + markdown body).
public enum BuiltinSkillCatalog {
    public static func supportSkillsRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["LUCAS_CLONE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("BuiltinSkills", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lucas/BuiltinSkills", isDirectory: true)
    }

    public static func load(additionalRoots: [URL] = []) -> [BuiltinSkill] {
        var roots: [URL] = [supportSkillsRoot()]
        roots.append(contentsOf: additionalRoots)
        var seen = Set<String>()
        var skills: [BuiltinSkill] = []
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let sourceLabel: String
            if root.path == supportSkillsRoot().path {
                sourceLabel = "Application Support"
            } else {
                sourceLabel = "Bundle"
            }
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for dir in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                let skillURL = dir.appendingPathComponent("SKILL.md")
                guard let raw = try? String(contentsOf: skillURL, encoding: .utf8) else { continue }
                guard let parsed = parse(raw) else { continue }
                let name = parsed.name.isEmpty ? dir.lastPathComponent : parsed.name
                if seen.contains(name) { continue }
                seen.insert(name)
                skills.append(
                    BuiltinSkill(
                        name: name,
                        description: localize(parsed.description),
                        body: localize(parsed.body),
                        directory: dir,
                        source: sourceLabel
                    )
                )
            }
        }
        return skills
    }

    /// Copy a bundled BuiltinSkills tree into Application Support without overwriting.
    @discardableResult
    public static func seed(from bundledRoot: URL) -> Int {
        let destRoot = supportSkillsRoot()
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: bundledRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var created = 0
        for dir in children {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = dir.lastPathComponent
            if name.hasPrefix("._") { continue }
            let target = destRoot.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: target.path) { continue }
            do {
                try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)
                try fm.copyItem(at: dir, to: target)
                created += 1
            } catch {
                continue
            }
        }
        return created
    }

    // MARK: - Parse

    private struct Parsed {
        var name: String
        var description: String
        var body: String
    }

    private static func parse(_ raw: String) -> Parsed? {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else {
            return Parsed(name: "", description: "", body: normalized.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let after = normalized.dropFirst(4)
        guard let endRange = after.range(of: "\n---\n") else {
            return Parsed(name: "", description: "", body: normalized.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let front = String(after[..<endRange.lowerBound])
        let body = String(after[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        var name = ""
        var description = ""
        for line in front.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.hasPrefix("name:") {
                name = text.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            } else if text.hasPrefix("description:") {
                description = text.dropFirst(12).trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return Parsed(name: name, description: description, body: body)
    }

    private static func localize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "Bailongma2.0", with: "Lucas")
            .replacingOccurrences(of: "Bailongma", with: "Lucas")
            .replacingOccurrences(of: "Japlos-v2", with: "Lucas")
            .replacingOccurrences(of: "Japlos", with: "Lucas")
    }
}
