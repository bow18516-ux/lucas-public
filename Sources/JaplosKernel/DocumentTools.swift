import AppKit
import CoreGraphics
import CoreText
import Foundation
import JaplosProtocol

// MARK: - PDF

public struct PDFCreateTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.document.pdf.create",
            title: "生成 PDF",
            summary: "把纯文本渲染成多页 PDF。默认写到 ~/Downloads，已存在的文件不会被覆盖。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "text": .object(["type": "string", "description": "正文内容"]),
                    "path": .object(["type": "string", "description": "保存路径，默认 ~/Downloads/japlos-时间戳.pdf"]),
                ]),
                "required": .array(["text"]),
                "additionalProperties": false,
            ]),
            capability: Capability.filesystemWrite,
            risk: .high
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
            throw ToolError.invalidArguments("text is required")
        }
        guard text.utf8.count <= 512 * 1024 else {
            throw ToolError.failed("Text exceeds the 512 KB PDF limit")
        }

        let path: String
        if let explicit = arguments["path"]?.stringValue, !explicit.isEmpty {
            path = try TrustRoots.allowedURL(path: explicit).path
        } else {
            let stamp = ISO8601.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/japlos-\(stamp).pdf").path
        }
        try SensitivePaths.reject(path)
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw ToolError.denied("拒绝通过符号链接写入 PDF：\(path)")
        }
        if FileManager.default.fileExists(atPath: path) {
            throw ToolError.denied("拒绝覆盖已有文件：\(path)")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Render beside the destination, then publish through the same
        // O_NOFOLLOW writer the filesystem tool uses.
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".lucas-pdf-\(UUID().uuidString).tmp")
        let pages = try render(text: text, to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        try SafeFile.write(Data(contentsOf: staging), to: url, exclusive: true)
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        return .object([
            "path": .string(path),
            "pages": .number(Double(pages)),
            "bytes": .number(Double(size)),
        ])
    }

    private func render(text: String, to url: URL) throws -> Int {
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842) // A4
        guard
            let consumer = CGDataConsumer(url: url as CFURL),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw ToolError.failed("Cannot create PDF context at \(url.path)")
        }

        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.black,
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textRect = mediaBox.insetBy(dx: 48, dy: 48)
        var current = 0
        var pages = 0
        let total = attributed.length

        while current < total && pages < 200 {
            context.beginPDFPage(nil)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRangeMake(current, 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            context.endPDFPage()

            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            current += visible.length
            pages += 1
        }
        context.closePDF()
        return pages
    }
}

// MARK: - Download

public struct DownloadFetchTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.download.fetch",
            title: "下载文件",
            summary: "下载一个 http(s) 链接到本地（默认 ~/Downloads），上限 200 MB。返回保存路径与大小。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "url": .object(["type": "string"]),
                    "path": .object(["type": "string", "description": "可选保存路径"]),
                ]),
                "required": .array(["url"]),
                "additionalProperties": false,
            ]),
            capability: Capability.filesystemWrite,
            risk: .high
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        guard
            let raw = arguments["url"]?.stringValue,
            let remote = URL(string: raw),
            let scheme = remote.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            throw ToolError.invalidArguments("a valid http(s) url is required")
        }

        let limit = 200 * 1024 * 1024
        if let advertised = try? await Self.advertisedByteCount(remote), advertised > limit {
            throw ToolError.failed("文件超过 200 MB 上限")
        }
        let (temporary, response) = try await URLSession.shared.download(from: remote)
        defer { try? FileManager.default.removeItem(at: temporary) }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ToolError.failed("下载失败：HTTP \(http.statusCode)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= limit else {
            throw ToolError.failed("文件超过 200 MB 上限")
        }

        let destination: URL
        if let explicit = arguments["path"]?.stringValue, !explicit.isEmpty {
            destination = try TrustRoots.allowedURL(path: explicit)
        } else {
            let suggested = response.suggestedFilename ?? remote.lastPathComponent
            let name = suggested.isEmpty ? "download-\(Int(Date().timeIntervalSince1970))" : suggested
            destination = try TrustRoots.allowedURL(
                path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/\(name)").path
            )
        }
        try SensitivePaths.reject(destination.path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Never destroy a file the user already has: pick "name (1).ext" instead.
        let finalDestination = Self.uniqueDestination(destination)
        try FileManager.default.moveItem(at: temporary, to: finalDestination)
        var result: [String: JSONValue] = [
            "path": .string(finalDestination.path),
            "bytes": .number(Double(size)),
        ]
        if finalDestination.path != destination.path {
            result["renamedFrom"] = .string(destination.path)
        }
        return .object(result)
    }

    /// `report.txt` occupied -> `report (1).txt`, then `report (2).txt`, ...
    static func uniqueDestination(_ url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        for index in 1...999 {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(base)-\(UUID().uuidString)\(ext.isEmpty ? "" : ".\(ext)")")
    }

    private static func advertisedByteCount(_ url: URL) async throws -> Int? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let raw = http.value(forHTTPHeaderField: "Content-Length")
        else { return nil }
        return Int(raw)
    }
}

// MARK: - Notification

public struct NotificationTool: KernelTool {
    public init() {}

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "system.notification",
            title: "系统通知",
            summary: "发一条 macOS 通知（标题 + 正文）。适合在长任务完成后提醒用户。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "title": .object(["type": "string"]),
                    "body": .object(["type": "string"]),
                ]),
                "required": .array(["title", "body"]),
                "additionalProperties": false,
            ]),
            capability: Capability.notificationSend,
            risk: .low
        )
    }

    public func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        guard
            let title = arguments["title"]?.stringValue,
            let body = arguments["body"]?.stringValue
        else {
            throw ToolError.invalidArguments("title and body are required")
        }
        let escapedTitle = Self.escape(title)
        let escapedBody = Self.escape(body)
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        let captured = await ProcessPipes.drain(
            process: process,
            stdout: nil,
            stderr: stderr.fileHandleForReading,
            limit: 64 * 1024
        )
        guard process.terminationStatus == 0 else {
            let message = String(decoding: captured.stderr, as: UTF8.self)
            throw ToolError.failed("通知发送失败：\(message)")
        }
        return .object(["delivered": .bool(true)])
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

public enum DocumentTools {
    public static func all() -> [any KernelTool] {
        [PDFCreateTool(), DownloadFetchTool(), NotificationTool()]
    }
}
