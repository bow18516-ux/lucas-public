import Foundation
import JaplosProtocol

/// Agent-facing tools mirroring Japlos `runtime.wechat.*` / `runtime.feishu.*`.
public enum ChannelTools {
    public static func all(wechat: WeChatChannel, feishu: FeishuChannel) -> [any KernelTool] {
        [
            WeChatStatusTool(channel: wechat),
            WeChatConnectTool(channel: wechat),
            WeChatDisconnectTool(channel: wechat),
            WeChatVerifyTool(channel: wechat),
            FeishuStatusTool(channel: feishu),
            FeishuConnectTool(channel: feishu),
            FeishuDisconnectTool(channel: feishu),
            FeishuSessionTool(channel: feishu),
            FeishuSendTextTool(channel: feishu),
            FeishuConfigureTool(channel: feishu),
        ]
    }
}

private struct WeChatStatusTool: KernelTool {
    let channel: WeChatChannel
    var definition: ToolDefinition {
        ToolDefinition(
            name: "runtime.wechat.status",
            title: "微信通道状态",
            summary: "读取当前 Agent 的官方微信 ClawBot 连接状态与已连接账号数。不暴露二维码、微信 ID 或令牌。",
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
        try channel.status()
    }
}

private struct WeChatConnectTool: KernelTool {
    let channel: WeChatChannel
    var definition: ToolDefinition {
        ToolDefinition(
            name: "runtime.wechat.connect",
            title: "连接微信",
            summary: "打开二维码，通过官方微信 ClawBot 通道绑定账号。无需 AppID/AppSecret。登录异步进行，用 runtime.wechat.status 查询扫码结果。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "additionalProperties": false,
            ]),
            capability: Capability.channelManage,
            risk: .medium
        )
    }
    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        try await channel.connect()
    }
}

private struct WeChatDisconnectTool: KernelTool {
    let channel: WeChatChannel
    var definition: ToolDefinition {
        ToolDefinition(
            name: "runtime.wechat.disconnect",
            title: "断开微信",
            summary: "断开当前 Agent 全部微信 ClawBot 账号并删除本地 iLink 凭据。仅在用户明确要求解绑/退出时调用。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "additionalProperties": false,
            ]),
            capability: Capability.channelManage,
            risk: .high
        )
    }
    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        try channel.disconnect()
    }
}

private struct WeChatVerifyTool: KernelTool {
    let channel: WeChatChannel
    var definition: ToolDefinition {
        ToolDefinition(
            name: "runtime.wechat.verify",
            title: "微信验证码",
            summary: "仅当 runtime.wechat.status 报告 verification_required 时，提交微信显示的短数字验证码。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "code": .object(["type": "string"]),
                ]),
                "required": .array(["code"]),
                "additionalProperties": false,
            ]),
            capability: Capability.channelManage,
            risk: .medium
        )
    }
    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        let code = arguments["code"]?.stringValue ?? ""
        return try channel.verify(code: code)
    }
}

// Unregistered until iLink can deliver. The RPC names are retired in KernelRetiredOperations.
private struct WeChatSendTextTool: KernelTool {
    let channel: WeChatChannel
    var definition: ToolDefinition {
        ToolDefinition(
            name: "runtime.wechat.send_text",
            title: "微信发文本",
            summary: "向已连接的微信 ClawBot 账号主动发送文本。未连接时失败。不要枚举回执字段名，除非用户明确要求。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "text": .object(["type": "string"]),
                    "suppressAck": .object(["type": "boolean"]),
                ]),
                "required": .array(["text"]),
                "additionalProperties": false,
            ]),
            capability: Capability.channelManage,
            risk: .high
        )
    }
    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        let text = arguments["text"]?.stringValue ?? ""
        let suppress = arguments["suppressAck"]?.boolValue ?? false
        return try channel.sendText(text: text, suppressAck: suppress)
    }
}

private struct WeChatSendFileTool: KernelTool {
    let channel: WeChatChannel
    var definition: ToolDefinition {
        ToolDefinition(
            name: "runtime.wechat.send_file",
            title: "微信发文件",
            summary: "向已连接微信账号发送本地文件/图片。附件本身可构成完整回复时设 suppressTextReplyOnSuccess=true。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "path": .object(["type": "string"]),
                    "suppressTextReplyOnSuccess": .object(["type": "boolean"]),
                ]),
                "required": .array(["path"]),
                "additionalProperties": false,
            ]),
            capability: Capability.channelManage,
            risk: .high
        )
    }
    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        let path = arguments["path"]?.stringValue ?? ""
        let suppress = arguments["suppressTextReplyOnSuccess"]?.boolValue ?? false
        return try channel.sendFile(path: path, suppressTextReplyOnSuccess: suppress)
    }
}

private struct FeishuStatusTool: KernelTool {
    let channel: FeishuChannel
    var definition: ToolDefinition {
        ToolDefinition(
            name: "runtime.feishu.status",
            title: "飞书通道状态",
            summary: "读取飞书连接状态。awaitingConfiguration 表示已请求配置对话框，不等于已连接。",
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
        try channel.status()
    }
}

private struct FeishuConnectTool: KernelTool {
    let channel: FeishuChannel
    var definition: ToolDefinition {
        ToolDefinition(
            name: "runtime.feishu.connect",
            title: "连接飞书",
            summary: "使用本地已配置的 App ID/Secret 连接飞书。本工具不接受凭据；用户在设置页填写。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "additionalProperties": false,
            ]),
            capability: Capability.channelManage,
            risk: .medium
        )
    }
    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        try await channel.connect()
    }
}

private struct FeishuDisconnectTool: KernelTool {
    let channel: FeishuChannel
    var definition: ToolDefinition {
        ToolDefinition(
            name: "runtime.feishu.disconnect",
            title: "断开飞书",
            summary: "断开飞书会话（保留本地 App ID/Secret）。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "additionalProperties": false,
            ]),
            capability: Capability.channelManage,
            risk: .high
        )
    }
    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        try channel.disconnect()
    }
}

private struct FeishuSessionTool: KernelTool {
    let channel: FeishuChannel
    var definition: ToolDefinition {
        ToolDefinition(
            name: "runtime.feishu.session",
            title: "飞书会话",
            summary: "读取飞书会话摘要（无密钥）。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "additionalProperties": false,
            ]),
            capability: Capability.channelRead,
            risk: .low
        )
    }
    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        try channel.session()
    }
}

private struct FeishuSendTextTool: KernelTool {
    let channel: FeishuChannel
    var definition: ToolDefinition {
        ToolDefinition(
            name: "runtime.feishu.send_text",
            title: "飞书发文本",
            summary: "向指定 receive_id 发送文本。需要已连接飞书。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "text": .object(["type": "string"]),
                    "receive_id": .object(["type": "string"]),
                    "receive_id_type": .object([
                        "type": "string",
                        "enum": .array(["open_id", "user_id", "union_id", "email", "chat_id"]),
                    ]),
                ]),
                "required": .array(["text", "receive_id"]),
                "additionalProperties": false,
            ]),
            capability: Capability.channelManage,
            risk: .high
        )
    }
    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        let text = arguments["text"]?.stringValue ?? ""
        let rid = arguments["receive_id"]?.stringValue ?? arguments["receiveID"]?.stringValue
        let rtype = arguments["receive_id_type"]?.stringValue ?? arguments["receiveIDType"]?.stringValue ?? "open_id"
        return try await channel.sendTextAsync(text: text, receiveID: rid, receiveIDType: rtype)
    }
}

private struct FeishuConfigureTool: KernelTool {
    let channel: FeishuChannel
    var definition: ToolDefinition {
        ToolDefinition(
            name: "feishu.connection.configure",
            title: "配置飞书",
            summary: "写入飞书 App ID/Secret（通常由设置页调用；勿在对话中索要 Secret）。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "app_id": .object(["type": "string"]),
                    "app_secret": .object(["type": "string"]),
                    "verification_token": .object(["type": "string"]),
                ]),
                "additionalProperties": false,
            ]),
            capability: Capability.channelManage,
            risk: .high
        )
    }
    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        try channel.configure(
            appID: arguments["app_id"]?.stringValue ?? arguments["appId"]?.stringValue,
            appSecret: arguments["app_secret"]?.stringValue ?? arguments["appSecret"]?.stringValue,
            verificationToken: arguments["verification_token"]?.stringValue ?? arguments["verificationToken"]?.stringValue
        )
    }
}
