import Foundation
import JaplosKernel
import JaplosProtocol

/// Builds per-turn memory / knowledge / open-task context blocks for the system prompt.
/// Retrieval is keyword-based (no vector DB) — honest v1.
public enum ContextInjector {
    public static func build(
        store: KernelStore,
        query: String,
        isFirstMessageInSession: Bool = false
    ) -> String {
        var parts: [String] = []

        let memoryBlock = memoriesBlock(store: store, query: query)
        if !memoryBlock.isEmpty { parts.append(memoryBlock) }

        let knowledgeBlock = knowledgeBlock(store: store, query: query)
        if !knowledgeBlock.isEmpty { parts.append(knowledgeBlock) }

        let tasksBlock = openTasksBlock(store: store, emphasize: isFirstMessageInSession)
        if !tasksBlock.isEmpty { parts.append(tasksBlock) }

        return parts.joined(separator: "\n\n")
    }

    public static let policyGuidance = """
    记忆与知识库（动态）：
    - 系统会注入与本轮相关的记忆和知识摘要；不够用时调用 memory.search / knowledge.search / knowledge.read。
    - 用户说出长期偏好、决定、公司/客户事实时，用 memory.save 写入；知识库文件由用户在设置里上传，你只检索与引用。
    - 知识库会持续更新：不要假设自己已经读过全部，回答业务问题前先检索。
    - 若注入了「未完成事项」，在合适时机主动问要不要继续；不要每次开场都机械复读。
    """

    private static func memoriesBlock(store: KernelStore, query: String) -> String {
        let matched = (try? store.searchMemories(query: query, limit: 8)) ?? []
        let items: [JSONValue]
        if matched.isEmpty {
            items = (try? store.listMemories(sessionID: nil, limit: 6)) ?? []
        } else {
            items = matched
        }
        guard !items.isEmpty else { return "" }
        let lines = items.compactMap { item -> String? in
            let content = item["content"]?.stringValue ?? ""
            guard !content.isEmpty else { return nil }
            let kind = item["kind"]?.stringValue ?? "note"
            return "- [\(kind)] \(String(content.prefix(280)))"
        }
        guard !lines.isEmpty else { return "" }
        return "相关记忆（已注入，可再 memory.search）：\n" + lines.joined(separator: "\n")
    }

    private static func knowledgeBlock(store: KernelStore, query: String) -> String {
        var docs = (try? store.searchKnowledgeDocuments(query: query, library: nil, limit: 5)) ?? []
        if docs.isEmpty {
            docs = (try? store.listKnowledgeDocuments(limit: 4)) ?? []
        }
        guard !docs.isEmpty else { return "" }
        let lines = docs.compactMap { doc -> String? in
            guard let obj = doc.objectValue else { return nil }
            let id = obj["id"]?.stringValue ?? ""
            let title = obj["title"]?.stringValue ?? "无标题"
            let record = obj["record"]?.objectValue ?? [:]
            let library = record["library"]?.stringValue ?? "all"
            let body = record["body"]?.stringValue ?? ""
            let extract = record["extractStatus"]?.stringValue ?? "ok"
            let snippet = body.isEmpty
                ? (record["extractNote"]?.stringValue ?? "（无正文摘要）")
                : String(body.prefix(500))
            var line = "- [\(library)] \(title) (id=\(id))"
            if extract != "ok" {
                line += " · 抽取:\(extract)"
            }
            line += "\n  \(snippet)"
            return line
        }
        guard !lines.isEmpty else { return "" }
        return "相关知识库（关键词检索；细节用 knowledge.read）：\n" + lines.joined(separator: "\n")
    }

    private static func openTasksBlock(store: KernelStore, emphasize: Bool) -> String {
        let tasks = (try? store.listOpenAgentTasks(limit: 5)) ?? []
        guard !tasks.isEmpty else { return "" }
        let lines = tasks.compactMap { item -> String? in
            let title = item["title"]?.stringValue ?? ""
            guard !title.isEmpty else { return nil }
            let state = item["state"]?.stringValue ?? "open"
            return "- [\(state)] \(String(title.prefix(160)))"
        }
        guard !lines.isEmpty else { return "" }
        let header = emphasize
            ? "未完成事项（本会话较早消息；若合适可主动问要不要继续）："
            : "未完成事项（可择机跟进）："
        return header + "\n" + lines.joined(separator: "\n")
    }

    /// Heuristic: if the user asks to remember something, upsert a memory note.
    @discardableResult
    public static func maybeCaptureExplicitMemory(store: KernelStore, sessionID: String?, text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let triggers = ["记住", "帮我记", "记一下", "以后都", "别忘了记住"]
        guard triggers.contains(where: { trimmed.contains($0) }) else { return nil }
        // Prefer text after the first trigger.
        var content = trimmed
        for t in triggers {
            if let range = content.range(of: t) {
                content = String(content[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        content = content.trimmingCharacters(in: CharacterSet(charactersIn: "：:，,。 "))
        guard content.count >= 2 else { return nil }
        let id = UUID().uuidString
        let note = String(content.prefix(400))
        try? store.upsertMemory(
            id: id,
            sessionID: sessionID,
            kind: "auto",
            content: note,
            record: .object([
                "content": .string(note),
                "kind": .string("auto"),
                "source": .string("explicit_utterance"),
            ])
        )
        return id
    }
}
