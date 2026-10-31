import Combine
import Foundation
import JaplosProtocol
import JaplosClient
import PDFKit
import AppKit

@MainActor
extension AppModel {
    // MARK: - Chat

    /// Starts a turn on a child task so `stop()` can cancel it.
    func send(_ text: String) {
        guard sendTask == nil else { return }
        sendTask = Task { [weak self] in
            await self?.performSend(text)
            self?.sendTask = nil
        }
    }

    func stop() {
        sendTask?.cancel()
        sendTask = nil
        voice.stop()
        currentStream = nil
        pendingApproval = nil
        isSending = false
        Task { await recordCancellation(state: "user_stop") }
    }

    func resolveApproval(_ approved: Bool) {
        guard let approval = pendingApproval else { return }
        currentStream?.approve(callID: approval.callID, approved: approved)
        pendingApproval = nil
    }

    func performSend(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if currentSessionID == nil { await createSession() }
        guard let sessionID = currentSessionID else { return }

        isSending = true
        errorText = nil
        voice.beginReply()
        messages.append(Message(role: "user", text: trimmed))
        messages.append(Message(role: "assistant", text: ""))
        let index = messages.count - 1

        do {
            var finished = false
            let stream = client.streamChat(sessionID: sessionID, text: trimmed)
            currentStream = stream
            for try await event in stream.events {
                switch event["event"]?.stringValue {
                case "delta":
                    let delta = event["text"]?.stringValue ?? ""
                    messages[index].text += delta
                    voice.feedReply(delta)
                case "tool":
                    messages[index].steps.append(ToolStep(
                        name: event["name"]?.stringValue ?? "tool",
                        ok: event["ok"]?.boolValue ?? false,
                        detail: String((event["detail"]?.stringValue ?? "").prefix(220))
                    ))
                case "approval":
                    pendingApproval = Approval(
                        callID: event["callID"]?.stringValue ?? "",
                        name: event["name"]?.stringValue ?? "tool",
                        title: event["title"]?.stringValue ?? "",
                        summary: AppModel.approvalSummary(event["arguments"])
                    )
                case "approvalResolved":
                    // WeChat / timeout / other channel settled — keep desktop card in sync.
                    let callID = event["callID"]?.stringValue ?? ""
                    if let pending = pendingApproval, callID.isEmpty || pending.callID == callID {
                        pendingApproval = nil
                    }
                case "done":
                    finished = true
                    if let finalText = event["text"]?.stringValue, !finalText.isEmpty {
                        messages[index].text = finalText
                    }
                    voice.finishReply(event["text"]?.stringValue ?? "")
                    if let stepArray = event["steps"]?.arrayValue, !stepArray.isEmpty {
                        messages[index].steps = stepArray.map { step in
                            let error = step["error"]?.stringValue ?? ""
                            let output = step["output"]
                            let path = output?["path"]?.stringValue
                            let track = output?["track"]?.stringValue
                            let detail: String
                            if !error.isEmpty {
                                detail = error
                            } else if let path, !path.isEmpty {
                                detail = path
                            } else if let track, !track.isEmpty {
                                let artist = output?["artist"]?.stringValue ?? ""
                                let state = output?["state"]?.stringValue ?? ""
                                detail = [state, track, artist].filter { !$0.isEmpty }.joined(separator: " · ")
                            } else {
                                detail = ""
                            }
                            return ToolStep(
                                name: step["tool"]?.stringValue ?? "tool",
                                ok: step["ok"]?.boolValue ?? false,
                                detail: String(detail.prefix(220))
                            )
                        }
                    }
                default:
                    break
                }
            }

            if Task.isCancelled {
                voice.stop()
                if messages[index].text.isEmpty {
                    messages[index].text = "（已停止）"
                } else {
                    messages[index].text += "\n\n（已停止）"
                }
            } else if !finished && messages[index].text.isEmpty {
                messages[index].text = "（内核提前结束了响应）"
            }
            if !finished { voice.finishReply("") }
            await loadSessions()
        } catch is CancellationError {
            voice.stop()
            if messages[index].text.isEmpty {
                messages[index].text = "（已停止）"
            } else {
                messages[index].text += "\n\n（已停止）"
            }
        } catch {
            let message = (error as? ClientError)?.description ?? String(describing: error)
            if case .kernel(let failure) = error as? ClientError ?? .transport(""), failure.code == "model_not_configured" {
                let completed = UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
                let skipped = UserDefaults.standard.bool(forKey: Self.onboardingSkippedKey)
                if completed || skipped {
                    settingsPresented = true
                } else {
                    onboardingPresented = true
                }
            }
            errorText = message
            if messages[index].text.isEmpty {
                messages[index].text = "请求失败：\(message)"
            } else {
                messages[index].text += "\n\n（中断：\(message)）"
            }
        }
        if !messages[index].steps.isEmpty {
            await persistAgentTask(
                sessionID: sessionID,
                steps: messages[index].steps,
                preview: trimmed
            )
        }
        await loadMemories()
        await loadRecentTasks()
        isSending = false
    }

    /// - Parameter scopedToCurrentSession: when true (default), filter by `currentSessionID` if set.
    ///   Settings 「记忆」 pane passes false to list every persisted note.
    func loadMemories(limit: Int = 40, scopedToCurrentSession: Bool = true) async {
        do {
            var args: [String: JSONValue] = ["limit": .number(Double(limit))]
            if scopedToCurrentSession, let sessionID = currentSessionID {
                args["sessionID"] = .string(sessionID)
            }
            let result = try await client.callAsync(.memoryList, arguments: .object(args))
            memoryNotes = (result.arrayValue ?? []).compactMap { item in
                guard let id = item["id"]?.stringValue else { return nil }
                let content = item["content"]?.stringValue
                    ?? item["record"]?["content"]?.stringValue
                    ?? ""
                guard !content.isEmpty else { return nil }
                return MemoryNote(
                    id: id,
                    content: content,
                    kind: item["kind"]?.stringValue ?? "note",
                    sessionID: item["sessionID"]?.stringValue ?? ""
                )
            }
        } catch {
            // Soft-fail when kernel is offline.
        }
    }

    func rememberNote(_ content: String, reloadScopedToCurrentSession: Bool = true) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            var args: [String: JSONValue] = [
                "content": .string(trimmed),
                "kind": .string("note"),
            ]
            if let sessionID = currentSessionID {
                args["sessionID"] = .string(sessionID)
            }
            _ = try await client.callAsync(.memoryUpsert, arguments: .object(args))
            await loadMemories(scopedToCurrentSession: reloadScopedToCurrentSession)
        } catch {
            errorText = (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func deleteMemory(id: String, reloadScopedToCurrentSession: Bool = true) async {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await client.callAsync(.memoryDelete, arguments: .object(["id": .string(trimmed)]))
            await loadMemories(scopedToCurrentSession: reloadScopedToCurrentSession)
        } catch {
            errorText = (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    func rememberLatestUserMessage() async {
        guard let last = messages.last(where: { $0.role == "user" }) else { return }
        await rememberNote(String(last.text.prefix(280)))
    }


    func loadKnowledgeDocuments(limit: Int = 80, library: String? = nil) async {
        do {
            var args: [String: JSONValue] = ["limit": .number(Double(limit))]
            if let library, !library.isEmpty, library != "all" {
                args["library"] = .string(library)
            }
            let result = try await client.callAsync(
                .knowledgeDocumentsList,
                arguments: .object(args)
            )
            knowledgeDocuments = (result.arrayValue ?? []).compactMap { item in
                guard let id = item["id"]?.stringValue else { return nil }
                let record = item["record"]
                let title = item["title"]?.stringValue ?? record?["title"]?.stringValue ?? ""
                let body = record?["body"]?.stringValue
                    ?? record?["text"]?.stringValue
                    ?? item["body"]?.stringValue
                    ?? ""
                let updated = item["updatedAt"]?.stringValue.flatMap(ISO8601.date(from:)) ?? Date()
                return KnowledgeDocument(
                    id: id,
                    title: title,
                    body: body,
                    updatedAt: updated,
                    library: record?["library"]?.stringValue ?? "all",
                    fileType: record?["fileType"]?.stringValue ?? "",
                    extractStatus: record?["extractStatus"]?.stringValue ?? "ok",
                    extractNote: record?["extractNote"]?.stringValue ?? "",
                    sourcePath: record?["sourcePath"]?.stringValue ?? ""
                )
            }
        } catch {
            // Soft-fail when kernel offline.
        }
    }

    func upsertKnowledgeDocument(
        title: String,
        body: String,
        id: String? = nil,
        library: String = "all",
        fileType: String = "note",
        extractStatus: String = "ok",
        extractNote: String = "",
        sourcePath: String = ""
    ) async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        do {
            var record: [String: JSONValue] = [
                "title": .string(trimmedTitle),
                "body": .string(trimmedBody),
                "library": .string(library),
                "fileType": .string(fileType),
                "extractStatus": .string(extractStatus),
            ]
            if !extractNote.isEmpty { record["extractNote"] = .string(extractNote) }
            if !sourcePath.isEmpty { record["sourcePath"] = .string(sourcePath) }
            var args: [String: JSONValue] = [
                "title": .string(trimmedTitle),
                "body": .string(trimmedBody),
                "library": .string(library),
                "fileType": .string(fileType),
                "extractStatus": .string(extractStatus),
                "record": .object(record),
            ]
            if !extractNote.isEmpty { args["extractNote"] = .string(extractNote) }
            if !sourcePath.isEmpty { args["sourcePath"] = .string(sourcePath) }
            if let id, !id.isEmpty {
                args["id"] = .string(id)
            }
            _ = try await client.callAsync(.knowledgeDocumentsUpsert, arguments: .object(args))
            await loadKnowledgeDocuments(library: library == "all" ? nil : library)
        } catch {
            errorText = (error as? ClientError)?.description ?? String(describing: error)
        }
    }

    /// Import local files into knowledge_documents with best-effort text extract.
    @discardableResult
    func importKnowledgeFiles(urls: [URL], library: String) async -> String {
        var ok = 0
        var partial = 0
        var failed = 0
        let destRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lucas/KnowledgeFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)

        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let extracted = Self.extractKnowledgeFile(url: url)
            let stamp = ISO8601.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let destName = "\(stamp)_\(url.lastPathComponent)"
            let dest = destRoot.appendingPathComponent(destName)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                // Still upsert even if copy fails; keep original path.
            }
            let storedPath = FileManager.default.fileExists(atPath: dest.path) ? dest.path : url.path
            let title = url.deletingPathExtension().lastPathComponent
            await upsertKnowledgeDocument(
                title: title,
                body: extracted.body,
                library: library,
                fileType: extracted.fileType,
                extractStatus: extracted.status,
                extractNote: extracted.note,
                sourcePath: storedPath
            )
            switch extracted.status {
            case "ok": ok += 1
            case "partial", "unsupported", "empty": partial += 1
            default: failed += 1
            }
        }
        return "导入完成：完整 \(ok)，部分/未抽正文 \(partial)，失败 \(failed)"
    }

    private struct ExtractedKnowledge {
        var body: String
        var fileType: String
        var status: String
        var note: String
    }

    private static func extractKnowledgeFile(url: URL) -> ExtractedKnowledge {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "txt", "text", "csv", "json", "log":
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let fileType = (ext == "json" || ext == "log") ? (ext == "json" ? "chat" : "txt") : (ext == "markdown" ? "md" : ext)
                if trimmed.isEmpty {
                    return ExtractedKnowledge(body: "", fileType: fileType, status: "empty", note: "文件为空")
                }
                // Cap stored body to keep SQLite rows reasonable.
                let capped = String(trimmed.prefix(200_000))
                return ExtractedKnowledge(body: capped, fileType: fileType, status: "ok", note: "")
            }
            return ExtractedKnowledge(body: "", fileType: ext, status: "empty", note: "无法按文本读取")
        case "pdf":
            if let doc = PDFDocument(url: url) {
                var chunks: [String] = []
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i), let s = page.string else { continue }
                    chunks.append(s)
                    if chunks.joined().count > 200_000 { break }
                }
                let body = String(chunks.joined(separator: "\n").prefix(200_000))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty {
                    return ExtractedKnowledge(body: "", fileType: "pdf", status: "empty", note: "PDF 无文本层（可能是扫描件）")
                }
                return ExtractedKnowledge(body: body, fileType: "pdf", status: "ok", note: "")
            }
            return ExtractedKnowledge(body: "", fileType: "pdf", status: "empty", note: "无法打开 PDF")
        case "xlsx", "xls":
            if ext == "xls" {
                return ExtractedKnowledge(
                    body: "",
                    fileType: "xlsx",
                    status: "unsupported",
                    note: "旧版 .xls（非 OOXML）暂不支持；请另存为 .xlsx 后重试"
                )
            }
            let r = OfficeKnowledgeExtract.extractXLSX(url: url)
            return ExtractedKnowledge(body: r.body, fileType: "xlsx", status: r.status, note: r.note)
        case "pptx", "ppt":
            if ext == "ppt" {
                return ExtractedKnowledge(
                    body: "",
                    fileType: "pptx",
                    status: "unsupported",
                    note: "旧版 .ppt（非 OOXML）暂不支持；请另存为 .pptx 后重试"
                )
            }
            let r = OfficeKnowledgeExtract.extractPPTX(url: url)
            return ExtractedKnowledge(body: r.body, fileType: "pptx", status: r.status, note: r.note)
        default:
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8),
               text.contains(where: { !$0.isWhitespace }) {
                return ExtractedKnowledge(
                    body: String(text.prefix(200_000)),
                    fileType: ext.isEmpty ? "其他" : ext,
                    status: "partial",
                    note: "按纯文本尝试读取"
                )
            }
            return ExtractedKnowledge(
                body: "",
                fileType: ext.isEmpty ? "其他" : ext,
                status: "unsupported",
                note: "不支持的格式"
            )
        }
    }

    func deleteKnowledgeDocument(id: String) async {
        guard !id.isEmpty else { return }
        do {
            _ = try await client.callAsync(.knowledgeDocumentsDelete, arguments: .object([
                "id": .string(id),
            ]))
            await loadKnowledgeDocuments()
        } catch {
            errorText = (error as? ClientError)?.description ?? String(describing: error)
        }
    }
}
