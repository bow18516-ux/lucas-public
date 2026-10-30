import AppKit
import SwiftUI
import UniformTypeIdentifiers
import JaplosProtocol
import JaplosClient

struct MemoryKnowledgeBackupCard: View {
    @ObservedObject var model: AppModel
    var scopeLabel: String = "记忆 + 知识库"
    @State private var note: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "externaldrive.badge.timemachine")
                    .font(.system(size: SettingsMetrics.bodySize))
                    .foregroundStyle(Theme.textSecondary)
                Text("备份")
                    .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(scopeLabel)
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
            }

            Text("导出到本机指定文件夹，或从备份目录导入。包含记忆、知识库文档正文，以及 KnowledgeFiles 原件副本；按 id 合并，可往返。")
                .font(.system(size: SettingsMetrics.captionSize))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    exportBackup()
                } label: {
                    Text(busy ? "处理中…" : "导出到文件夹…")
                        .font(.system(size: SettingsMetrics.cardSubtitleSize))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.pressable)
                .disabled(busy)

                Button {
                    importBackup()
                } label: {
                    Text("从备份导入…")
                        .font(.system(size: SettingsMetrics.cardSubtitleSize))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
                }
                .buttonStyle(.pressable)
                .disabled(busy)
            }

            if let note {
                Text(note)
                    .font(.system(size: SettingsMetrics.captionSize))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .panel(padding: SettingsMetrics.cardPadding)
    }

    private func exportBackup() {
        guard let folder = MemoryKnowledgeBackup.pickExportFolder() else { return }
        busy = true
        note = "正在导出…"
        Task {
            let result = await model.exportMemoryKnowledgeBackup(toParent: folder)
            note = result
            busy = false
        }
    }

    private func importBackup() {
        guard let folder = MemoryKnowledgeBackup.pickImportFolder() else { return }
        busy = true
        note = "正在导入…"
        Task {
            let result = await model.importMemoryKnowledgeBackup(from: folder)
            note = result
            busy = false
        }
    }
}

// MARK: - Alarms settings

struct MemorySettingsPane: View {
    @ObservedObject var model: AppModel
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(
                title: "记忆",
                subtitle: "持久化短笔记（memory.list / upsert / delete），与会话聊天分开存放",
                model: model
            )

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: SettingsMetrics.bodySize))
                                .foregroundStyle(Theme.textSecondary)
                            Text("记一条")
                                .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("\(model.memoryNotes.count) 条")
                                .font(.system(size: SettingsMetrics.captionSize, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                        }

                        HStack(spacing: 10) {
                            TextField("写下要长期记住的内容…", text: $draft, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: SettingsMetrics.bodySize))
                                .lineLimit(2...4)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))
                            Button("保存") {
                                let text = draft
                                draft = ""
                                Task {
                                    await model.rememberNote(text, reloadScopedToCurrentSession: false)
                                }
                            }
                            .buttonStyle(.pressable)
                            .font(.system(size: SettingsMetrics.cardSubtitleSize))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        Button("记上条用户发言") {
                            Task {
                                await model.rememberLatestUserMessage()
                                await model.loadMemories(scopedToCurrentSession: false)
                            }
                        }
                        .buttonStyle(.pressable)
                        .font(.system(size: SettingsMetrics.cardSubtitleSize))
                        .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .panel(padding: SettingsMetrics.cardPadding)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("已保存")
                            .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)

                        if model.memoryNotes.isEmpty {
                            Text("暂无持久化记忆。在上方写入后点「保存」。")
                                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            ForEach(model.memoryNotes) { note in
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(note.content)
                                            .font(.system(size: SettingsMetrics.labelSize))
                                            .foregroundStyle(Theme.textPrimary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        HStack(spacing: 8) {
                                            Text(note.kind)
                                                .font(.system(size: SettingsMetrics.captionSize))
                                                .foregroundStyle(Theme.textSecondary)
                                            if !note.sessionID.isEmpty {
                                                Text("会话 \(note.sessionID.prefix(8))")
                                                    .font(.system(size: SettingsMetrics.captionSize, design: .monospaced))
                                                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                                            }
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Button {
                                        Task {
                                            await model.deleteMemory(id: note.id, reloadScopedToCurrentSession: false)
                                        }
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: SettingsMetrics.captionSize))
                                            .foregroundStyle(Color.red.opacity(0.8))
                                    }
                                    .buttonStyle(.pressable)
                                }
                                .padding(.vertical, 6)
                                if note.id != model.memoryNotes.last?.id {
                                    Divider().overlay(Theme.panelBorder.opacity(0.6))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .panel(padding: SettingsMetrics.cardPadding)

                    MemoryKnowledgeBackupCard(model: model, scopeLabel: "记忆 + 知识库")
                }
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.bottom, 28)
            }
        }
        .task {
            await model.loadMemories(limit: 100, scopedToCurrentSession: false)
        }
    }
}

struct KnowledgeLibraryPane: View {
    /// Initial library from sidebar / deep-link; user can switch via in-pane chips.
    let nav: KnowledgeNav
    @ObservedObject var model: AppModel
    @State private var selectedLibrary: KnowledgeNav
    @State private var titleDraft = ""
    @State private var bodyDraft = ""
    @State private var typeFilter: String = "全部"
    @State private var importNote: String?

    init(nav: KnowledgeNav, model: AppModel) {
        self.nav = nav
        self.model = model
        _selectedLibrary = State(initialValue: nav)
    }

    private static let typeFilters = ["全部", "md", "txt", "pdf", "csv", "xlsx", "pptx", "chat", "其他"]

    private var visibleDocs: [AppModel.KnowledgeDocument] {
        model.knowledgeDocuments.filter { doc in
            if selectedLibrary.libraryID != "all", doc.library != selectedLibrary.libraryID {
                return false
            }
            if typeFilter == "全部" { return true }
            let ft = doc.fileType.lowercased()
            if typeFilter == "其他" {
                return !["md", "txt", "pdf", "csv", "xlsx", "pptx", "chat", "markdown"].contains(ft)
            }
            if typeFilter == "md" {
                return ft == "md" || ft == "markdown"
            }
            return ft == typeFilter
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(
                title: "知识库",
                subtitle: selectedLibrary.subtitle + " · 上传后参与每轮检索；类型/库标签可筛选",
                model: model
            )

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: SettingsMetrics.bodySize))
                                .foregroundStyle(Theme.textSecondary)
                            Text("上传文件")
                                .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("\(visibleDocs.count) 篇")
                                .font(.system(size: SettingsMetrics.captionSize, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                        }

                        Text("支持 md / txt / pdf / csv / xlsx / pptx（OOXML 正文尽力抽取）。聊天导出可用 txt / md / json。")
                            .font(.system(size: SettingsMetrics.captionSize))
                            .foregroundStyle(Theme.textSecondary)

                        HStack(spacing: 10) {
                            Button("选择本地文件…") {
                                pickAndImport()
                            }
                            .buttonStyle(.pressable)
                            .font(.system(size: SettingsMetrics.cardSubtitleSize))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))

                            if let importNote {
                                Text(importNote)
                                    .font(.system(size: SettingsMetrics.captionSize))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .panel(padding: SettingsMetrics.cardPadding)

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: SettingsMetrics.bodySize))
                                .foregroundStyle(Theme.textSecondary)
                            Text("手动添加")
                                .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }

                        TextField("标题", text: $titleDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: SettingsMetrics.bodySize))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))

                        TextField("正文…", text: $bodyDraft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: SettingsMetrics.bodySize))
                            .lineLimit(3...8)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.panelBorder, lineWidth: 0.7))

                        HStack {
                            Spacer()
                            Button("保存") {
                                let title = titleDraft
                                let body = bodyDraft
                                titleDraft = ""
                                bodyDraft = ""
                                Task {
                                    await model.upsertKnowledgeDocument(
                                        title: title,
                                        body: body,
                                        library: selectedLibrary.libraryID == "all" ? "all" : selectedLibrary.libraryID,
                                        fileType: "note"
                                    )
                                }
                            }
                            .buttonStyle(.pressable)
                            .font(.system(size: SettingsMetrics.cardSubtitleSize))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                            .disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .panel(padding: SettingsMetrics.cardPadding)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("已入库")
                                .font(.system(size: SettingsMetrics.cardTitleSize, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(KnowledgeNav.allCases) { lib in
                                    let selected = selectedLibrary == lib
                                    Button(lib.rawValue) {
                                        selectedLibrary = lib
                                        Task {
                                            await model.loadKnowledgeDocuments(
                                                library: lib.libraryID == "all" ? nil : lib.libraryID
                                            )
                                        }
                                    }
                                    .buttonStyle(.pressable)
                                    .font(.system(size: SettingsMetrics.captionSize, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Color.black.opacity(0.85) : Theme.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        selected ? Theme.accent : Color.white.opacity(0.06),
                                        in: Capsule()
                                    )
                                }
                            }
                        }

                        if selectedLibrary == .all {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(Self.typeFilters, id: \.self) { tag in
                                        let selected = typeFilter == tag
                                        Button(tag) { typeFilter = tag }
                                            .buttonStyle(.pressable)
                                            .font(.system(size: SettingsMetrics.captionSize, weight: selected ? .semibold : .regular))
                                            .foregroundStyle(selected ? Color.black.opacity(0.85) : Theme.textSecondary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(
                                                selected ? Theme.accent : Color.white.opacity(0.06),
                                                in: Capsule()
                                            )
                                    }
                                }
                            }
                        }

                        if visibleDocs.isEmpty {
                            Text("暂无文档。上传本地文件或手动添加标题与正文。")
                                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            ForEach(visibleDocs) { doc in
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 8) {
                                            Text(doc.title)
                                                .font(.system(size: SettingsMetrics.labelSize, weight: .medium))
                                                .foregroundStyle(Theme.textPrimary)
                                            Text(libraryLabel(doc.library))
                                                .font(.system(size: SettingsMetrics.captionSize))
                                                .foregroundStyle(Theme.textSecondary)
                                            if !doc.fileType.isEmpty {
                                                Text(doc.fileType)
                                                    .font(.system(size: SettingsMetrics.captionSize, design: .monospaced))
                                                    .foregroundStyle(Theme.textSecondary.opacity(0.85))
                                            }
                                        }
                                        if doc.extractStatus != "ok" && !doc.extractStatus.isEmpty {
                                            Text(extractStatusLabel(doc))
                                                .font(.system(size: SettingsMetrics.captionSize))
                                                .foregroundStyle(Color.orange.opacity(0.9))
                                        }
                                        if !doc.body.isEmpty {
                                            Text(doc.body)
                                                .font(.system(size: SettingsMetrics.cardSubtitleSize))
                                                .foregroundStyle(Theme.textSecondary)
                                                .lineLimit(3)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Button {
                                        Task { await model.deleteKnowledgeDocument(id: doc.id) }
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: SettingsMetrics.captionSize))
                                            .foregroundStyle(Color.red.opacity(0.8))
                                    }
                                    .buttonStyle(.pressable)
                                }
                                .padding(.vertical, 6)
                                if doc.id != visibleDocs.last?.id {
                                    Divider().overlay(Theme.panelBorder.opacity(0.6))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .panel(padding: SettingsMetrics.cardPadding)

                    MemoryKnowledgeBackupCard(model: model, scopeLabel: "记忆 + 知识库")
                }
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.bottom, 28)
            }
        }
        .task {
            await model.loadKnowledgeDocuments(library: selectedLibrary.libraryID == "all" ? nil : selectedLibrary.libraryID)
        }
    }

    private func libraryLabel(_ id: String) -> String {
        switch id {
        case "company": return "公司"
        case "client": return "客户"
        default: return "全部"
        }
    }

    private func extractStatusLabel(_ doc: AppModel.KnowledgeDocument) -> String {
        switch doc.extractStatus {
        case "partial":
            return "正文抽取不完整" + (doc.extractNote.isEmpty ? "" : "：\(doc.extractNote)")
        case "unsupported":
            return "此格式暂不支持正文抽取，已登记文件" + (doc.extractNote.isEmpty ? "" : "：\(doc.extractNote)")
        case "empty":
            return "未读出正文"
        default:
            return doc.extractNote
        }
    }

    private func pickAndImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "选择要加入「\(selectedLibrary.rawValue)」的本地文件"
        var types: [UTType] = [.plainText, .utf8PlainText, .text, .pdf, .commaSeparatedText]
        for ext in ["md", "markdown", "json", "csv", "xlsx", "xls", "pptx", "ppt", "txt"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }
        importNote = "正在导入 \(urls.count) 个文件…"
        Task {
            let result = await model.importKnowledgeFiles(
                urls: urls,
                library: selectedLibrary.libraryID == "all" ? "all" : selectedLibrary.libraryID
            )
            importNote = result
            await model.loadKnowledgeDocuments(library: selectedLibrary.libraryID == "all" ? nil : selectedLibrary.libraryID)
        }
    }
}
