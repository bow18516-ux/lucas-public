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
            summary: "把纯文本渲染成多页 PDF 并保存到指定路径。返回页数与文件大小。",
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
            risk: .low
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
            path = try FilesystemTool.allowedURL(path: explicit).path
        } else {
            let stamp = ISO8601.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/japlos-\(stamp).pdf").path
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let pages = try render(text: text, to: url)
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
            risk: .medium
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
            destination = try FilesystemTool.allowedURL(path: explicit)
        } else {
            let suggested = response.suggestedFilename ?? remote.lastPathComponent
            let name = suggested.isEmpty ? "download-\(Int(Date().timeIntervalSince1970))" : suggested
            destination = try FilesystemTool.allowedURL(
                path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/\(name)").path
            )
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return .object([
            "path": .string(destination.path),
            "bytes": .number(Double(size)),
        ])
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
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
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
