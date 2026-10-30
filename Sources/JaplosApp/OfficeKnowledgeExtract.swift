import Foundation

/// Best-effort text extract for Office Open XML (.xlsx / .pptx) via `/usr/bin/unzip`.
/// Honest v1: sheet/shared-string dumps and slide `<a:t>` runs — not a full spreadsheet engine.
enum OfficeKnowledgeExtract {
    static func extractXLSX(url: URL) -> (body: String, status: String, note: String) {
        guard let root = unzipToTemp(url) else {
            return ("", "empty", "无法解压 xlsx（不是有效的 OOXML 压缩包？）")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        var parts: [String] = []

        let shared = root.appendingPathComponent("xl/sharedStrings.xml")
        if let xml = try? String(contentsOf: shared, encoding: .utf8) {
            let strings = extractTaggedText(xml, tagLocalNames: ["t"])
            if !strings.isEmpty {
                parts.append("【共享字符串】\n" + strings.joined(separator: " | "))
            }
        }

        let sheetsDir = root.appendingPathComponent("xl/worksheets")
        if let sheets = try? FileManager.default.contentsOfDirectory(at: sheetsDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension.lowercased() == "xml" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            for (idx, sheet) in sheets.enumerated() {
                guard let xml = try? String(contentsOf: sheet, encoding: .utf8) else { continue }
                // Cell values (inlineStr / cached numbers) — strip tags into CSV-ish lines.
                let cells = extractTaggedText(xml, tagLocalNames: ["v", "t"])
                if cells.isEmpty { continue }
                let chunk = cells.joined(separator: ",")
                parts.append("【工作表 \(idx + 1): \(sheet.deletingPathExtension().lastPathComponent)】\n" + String(chunk.prefix(40_000)))
                if parts.joined().count > 200_000 { break }
            }
        }

        let body = String(parts.joined(separator: "\n\n").prefix(200_000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return ("", "empty", "xlsx 解压成功但未读到单元格/共享字符串文本")
        }
        return (body, "ok", "OOXML 文本抽取（共享字符串 + 工作表值，非公式重算）")
    }

    static func extractPPTX(url: URL) -> (body: String, status: String, note: String) {
        guard let root = unzipToTemp(url) else {
            return ("", "empty", "无法解压 pptx（不是有效的 OOXML 压缩包？）")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let slidesDir = root.appendingPathComponent("ppt/slides")
        guard let slides = try? FileManager.default.contentsOfDirectory(at: slidesDir, includingPropertiesForKeys: nil)
            .filter({ $0.lastPathComponent.lowercased().hasPrefix("slide") && $0.pathExtension.lowercased() == "xml" })
            .sorted(by: { slideIndex($0) < slideIndex($1) }) else {
            return ("", "empty", "pptx 无 slides 目录")
        }

        var parts: [String] = []
        for (idx, slide) in slides.enumerated() {
            guard let xml = try? String(contentsOf: slide, encoding: .utf8) else { continue }
            let runs = extractTaggedText(xml, tagLocalNames: ["t"])
            let text = runs.joined(separator: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            parts.append("【幻灯片 \(idx + 1)】\n" + text)
            if parts.joined().count > 200_000 { break }
        }

        // Notes slides (optional)
        let notesDir = root.appendingPathComponent("ppt/notesSlides")
        if let notes = try? FileManager.default.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension.lowercased() == "xml" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            for note in notes.prefix(30) {
                guard let xml = try? String(contentsOf: note, encoding: .utf8) else { continue }
                let runs = extractTaggedText(xml, tagLocalNames: ["t"])
                let text = runs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                parts.append("【备注 \(note.deletingPathExtension().lastPathComponent)】\n" + text)
            }
        }

        let body = String(parts.joined(separator: "\n\n").prefix(200_000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return ("", "empty", "pptx 解压成功但幻灯片无文本框（可能是纯图片页）")
        }
        return (body, "ok", "OOXML 幻灯片文本抽取（a:t 文本框）")
    }

    // MARK: - Internals

    private static func unzipToTemp(_ url: URL) -> URL? {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lucas-ooxml-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-qq", "-o", url.path, "-d", root.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            try? fm.removeItem(at: root)
            return nil
        }
        guard proc.terminationStatus == 0 else {
            try? fm.removeItem(at: root)
            return nil
        }
        return root
    }

    /// Pulls character data of elements whose local name is in `tagLocalNames` (ignores XML namespaces).
    private static func extractTaggedText(_ xml: String, tagLocalNames: [String]) -> [String] {
        var results: [String] = []
        let ns = xml as NSString
        let full = NSRange(location: 0, length: ns.length)
        for name in tagLocalNames {
            let pattern = "<([A-Za-z0-9._-]+:)?" + name + "(\\s[^>]*)?>([\\s\\S]*?)</([A-Za-z0-9._-]+:)?" + name + ">"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            regex.enumerateMatches(in: xml, options: [], range: full) { match, _, _ in
                guard let match, match.numberOfRanges >= 4 else { return }
                let bodyRange = match.range(at: 3)
                guard bodyRange.location != NSNotFound else { return }
                let piece = ns.substring(with: bodyRange)
                let decoded = decodeXMLEntities(stripTags(piece))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !decoded.isEmpty {
                    results.append(decoded)
                }
            }
        }
        return results
    }

    private static func stripTags(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
    }

    private static func decodeXMLEntities(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&#13;", with: "\r")
    }

    private static func slideIndex(_ url: URL) -> Int {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let digits = name.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
        return Int(digits) ?? 0
    }
}
