import Foundation
import JaplosProtocol

/// Locates and seeds the Japlos BuiltinSkills pack shipped inside JaplosRuntime.
public enum SkillPack {
    public static func bundledRoot() -> URL? {
        if let url = Bundle.module.resourceURL?.appendingPathComponent("BuiltinSkills", isDirectory: true),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let url = Bundle.main.resourceURL?.appendingPathComponent("BuiltinSkills", isDirectory: true),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    @discardableResult
    public static func seedIfNeeded() -> Int {
        guard let root = bundledRoot() else { return 0 }
        return BuiltinSkillCatalog.seed(from: root)
    }

    public static func load() -> [BuiltinSkill] {
        var extras: [URL] = []
        if let root = bundledRoot() { extras.append(root) }
        return BuiltinSkillCatalog.load(additionalRoots: extras)
    }
}
