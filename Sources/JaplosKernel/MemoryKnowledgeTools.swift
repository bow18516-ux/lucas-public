import Foundation
import JaplosProtocol

/// Agent-facing memory + knowledge tools so the model can read/write during a turn.
public enum MemoryKnowledgeTools {
    public static func all(store: KernelStore) -> [any KernelTool] {
        [
            MemorySaveTool(store: store),
            MemorySearchTool(store: store),
            KnowledgeSearchTool(store: store),
            KnowledgeReadTool(store: store),
        ]
    }
}

private struct MemorySaveTool: KernelTool {
    let store: KernelStore

    var definition: ToolDefinition {
        ToolDefinition(
            name: "memory.save",
            title: "保存记忆",
            summary: "把关于用户的长期偏好、决定、事实写入持久化记忆。工作流中需要「以后都记住」时调用；不要存一次性临时信息。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "content": .object(["type": "string", "description": "要记住的短笔记"]),
                    "kind": .object(["type": "string", "description": "可选分类，默认 note"]),
                ]),
                "required": .array(["content"]),
                "additionalProperties": false,
            ]),
            capability: Capability.chatManage,
            risk: .low
        )
    }

    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        guard let content = arguments["content"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw ToolError.invalidArguments("content is required")
        }
        let kind = arguments["kind"]?.stringValue ?? "note"
        let id = UUID().uuidString
        let record: JSONValue = .object([
            "content": .string(content),
            "kind": .string(kind),
            "source": .string("tool.memory.save"),
        ])
        try store.upsertMemory(
            id: id,
            sessionID: context.sessionID,
            kind: kind,
            content: content,
            record: record
        )
        return .object(["id": .string(id), "saved": .bool(true)])
    }
}

private struct MemorySearchTool: KernelTool {
    let store: KernelStore

    var definition: ToolDefinition {
        ToolDefinition(
            name: "memory.search",
            title: "搜索记忆",
            summary: "按关键词检索已保存的用户记忆。回答前若需要确认偏好或过往决定，先搜再答。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "query": .object(["type": "string", "description": "关键词或短语"]),
                    "limit": .object(["type": "integer", "description": "最多条数，默认 8"]),
                ]),
                "required": .array(["query"]),
                "additionalProperties": false,
            ]),
            capability: Capability.chatRead,
            risk: .low,
            approval: .never
        )
    }

    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        let query = arguments["query"]?.stringValue ?? ""
        let limit = arguments["limit"]?.intValue ?? 8
        let items = try store.searchMemories(query: query, limit: limit)
        return .object([
            "count": .number(Double(items.count)),
            "items": .array(items),
        ])
    }
}

private struct KnowledgeSearchTool: KernelTool {
    let store: KernelStore

    var definition: ToolDefinition {
        ToolDefinition(
            name: "knowledge.search",
            title: "搜索知识库",
            summary: "检索知识库文档（本地混合：NLEmbedding 语义 + FTS/关键词）。回邮件/答业务问题前必须先搜相关资料。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "query": .object(["type": "string", "description": "关键词，如公司名、产品、客户名"]),
                    "library": .object([
                        "type": "string",
                        "description": "可选：company | client | all",
                    ]),
                    "limit": .object(["type": "integer", "description": "最多篇数，默认 6"]),
                ]),
                "required": .array(["query"]),
                "additionalProperties": false,
            ]),
            capability: Capability.chatRead,
            risk: .low,
            approval: .never
        )
    }

    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        let query = arguments["query"]?.stringValue ?? ""
        let library = arguments["library"]?.stringValue
        let limit = arguments["limit"]?.intValue ?? 6
        let items = try store.searchKnowledgeDocuments(query: query, library: library, limit: limit)
        // Trim bodies in search hits so tool payloads stay small.
        let trimmed = items.map { item -> JSONValue in
            guard var obj = item.objectValue else { return item }
            if var record = obj["record"]?.objectValue {
                if let body = record["body"]?.stringValue, body.count > 600 {
                    record["body"] = .string(String(body.prefix(600)) + "…")
                    record["truncated"] = .bool(true)
                }
                obj["record"] = .object(record)
            }
            return .object(obj)
        }
        return .object([
            "count": .number(Double(trimmed.count)),
            "items": .array(trimmed),
            "retrieval": .string(store.knowledgeRetrievalBackend()),
        ])
    }
}

private struct KnowledgeReadTool: KernelTool {
    let store: KernelStore

    var definition: ToolDefinition {
        ToolDefinition(
            name: "knowledge.read",
            title: "阅读知识文档",
            summary: "按 id 读取一篇知识库全文（可截断）。搜索命中后需要细节时调用。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "id": .object(["type": "string", "description": "文档 id"]),
                    "maxChars": .object(["type": "integer", "description": "正文最多字符，默认 4000"]),
                ]),
                "required": .array(["id"]),
                "additionalProperties": false,
            ]),
            capability: Capability.chatRead,
            risk: .low,
            approval: .never
        )
    }

    func invoke(arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        guard let id = arguments["id"]?.stringValue, !id.isEmpty else {
            throw ToolError.invalidArguments("id is required")
        }
        let maxChars = arguments["maxChars"]?.intValue ?? 4000
        let docs = try store.listKnowledgeDocuments(limit: 300)
        guard let match = docs.first(where: { $0["id"]?.stringValue == id }) else {
            throw ToolError.failed("文档不存在：\(id)")
        }
        var obj = match.objectValue ?? [:]
        if var record = obj["record"]?.objectValue,
           let body = record["body"]?.stringValue,
           body.count > maxChars {
            record["body"] = .string(String(body.prefix(maxChars)) + "…")
            record["truncated"] = .bool(true)
            obj["record"] = .object(record)
        }
        return .object(obj)
    }
}
