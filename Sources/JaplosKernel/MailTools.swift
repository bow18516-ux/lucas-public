import Foundation
import JaplosProtocol

public enum MailTools {
    public static func all(mail: MailChannel) -> [any KernelTool] {
        [
            MailListTool(mail: mail),
            MailReadTool(mail: mail),
            MailSendTool(mail: mail),
            MailStatusTool(mail: mail),
        ]
    }
}

private struct MailStatusTool: KernelTool {
    let mail: MailChannel

    var definition: ToolDefinition {
        ToolDefinition(
            name: "mail.status",
            title: "邮箱状态",
            summary: "查看当前 IMAP/SMTP 邮箱是否已配置与连接（不回显密码）。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "additionalProperties": false,
            ]),
            capability: Capability.channelRead,
            risk: .low,
            approval: .never
        )
    }

    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        try mail.status()
    }
}

private struct MailListTool: KernelTool {
    let mail: MailChannel

    var definition: ToolDefinition {
        ToolDefinition(
            name: "mail.list",
            title: "列出邮件",
            summary: "通过 IMAP 列出收件箱邮件（UID/发件人/主题/日期）。未配置邮箱时返回明确提示，不伪造数据。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "folder": .object(["type": "string", "description": "邮箱文件夹，默认 INBOX"]),
                    "limit": .object(["type": "integer", "description": "最多条数，默认 10，上限 50"]),
                    "unread_only": .object(["type": "boolean", "description": "只列未读，默认 false"]),
                ]),
                "additionalProperties": false,
            ]),
            capability: Capability.channelRead,
            risk: .low,
            approval: .never
        )
    }

    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        let folder = arguments["folder"]?.stringValue ?? "INBOX"
        let limit = arguments["limit"]?.intValue ?? 10
        let unread = arguments["unread_only"]?.boolValue
            ?? arguments["unreadOnly"]?.boolValue
            ?? false
        do {
            return try await mail.listMessages(folder: folder, limit: limit, unreadOnly: unread)
        } catch let err as MailError {
            return .object([
                "ok": .bool(false),
                "error": .string(err.localizedDescription),
                "action": .string("设置 → 通道 → 邮箱账户"),
            ])
        }
    }
}

private struct MailReadTool: KernelTool {
    let mail: MailChannel

    var definition: ToolDefinition {
        ToolDefinition(
            name: "mail.read",
            title: "读取邮件",
            summary: "按 IMAP UID 读取一封邮件正文。先 mail.list 再读。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "uid": .object(["type": "string", "description": "IMAP UID"]),
                    "folder": .object(["type": "string", "description": "默认 INBOX"]),
                ]),
                "required": .array(["uid"]),
                "additionalProperties": false,
            ]),
            capability: Capability.channelRead,
            risk: .low,
            approval: .never
        )
    }

    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        guard let uid = arguments["uid"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uid.isEmpty else {
            throw ToolError.invalidArguments("uid is required")
        }
        let folder = arguments["folder"]?.stringValue ?? "INBOX"
        do {
            return try await mail.readMessage(uid: uid, folder: folder)
        } catch let err as MailError {
            return .object([
                "ok": .bool(false),
                "error": .string(err.localizedDescription),
            ])
        }
    }
}

private struct MailSendTool: KernelTool {
    let mail: MailChannel

    var definition: ToolDefinition {
        ToolDefinition(
            name: "mail.send",
            title: "发送邮件",
            summary: "发送邮件。审批通过即实发（审批就是唯一的确认），会保留一份本地草稿副本备查。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "to": .object(["type": "string", "description": "收件人，逗号分隔"]),
                    "subject": .object(["type": "string"]),
                    "body": .object(["type": "string"]),
                    "cc": .object(["type": "string"]),
                ]),
                "required": .array(["to", "subject", "body"]),
                "additionalProperties": false,
            ]),
            capability: Capability.channelManage,
            risk: .high
        )
    }

    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        guard let to = arguments["to"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !to.isEmpty else {
            throw ToolError.invalidArguments("to is required")
        }
        guard let subject = arguments["subject"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subject.isEmpty else {
            throw ToolError.invalidArguments("subject is required")
        }
        let body = arguments["body"]?.stringValue ?? ""
        let cc = arguments["cc"]?.stringValue
        do {
            return try mail.send(
                to: to,
                subject: subject,
                body: body,
                cc: cc
            )
        } catch let err as MailError {
            return .object([
                "ok": .bool(false),
                "sent": .bool(false),
                "error": .string(err.localizedDescription),
            ])
        }
    }
}
