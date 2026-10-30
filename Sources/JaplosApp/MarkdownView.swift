import AppKit
import SwiftUI

/// Lightweight Markdown rendering: fenced code blocks get their own surface,
/// everything else is parsed as inline Markdown by Foundation.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Block.parse(text)) { block in
                switch block.kind {
                case .paragraph(let content):
                    Text(Self.inline(content))
                        .font(.system(size: 17))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .heading(let level, let content):
                    Text(Self.inline(content))
                        .font(.system(size: level <= 2 ? 17 : 15, weight: .semibold))
                        .textSelection(.enabled)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
    }

    static func inline(_ string: String) -> AttributedString {
        var normalized = string
        // Turn "### 标题" style headings into bold text when they appear inline.
        let lines = normalized.components(separatedBy: "\n").map { line -> String in
            if line.hasPrefix("- ") { return "• " + line.dropFirst(2) }
            if line.hasPrefix("* ") { return "• " + line.dropFirst(2) }
            return line
        }
        normalized = lines.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: normalized, options: options)) ?? AttributedString(normalized)
    }
}

struct Block: Identifiable {
    enum Kind {
        case paragraph(String)
        case heading(Int, String)
        case code(String?, String)
    }

    let id = UUID()
    let kind: Kind

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var buffer: [String] = []
        var codeBuffer: [String] = []
        var language: String?
        var inCode = false

        func flushParagraph() {
            let paragraph = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeAll()
            guard !paragraph.isEmpty else { return }
            if paragraph.hasPrefix("#") {
                let hashes = paragraph.prefix { $0 == "#" }.count
                let content = paragraph.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                blocks.append(Block(kind: .heading(min(hashes, 6), content)))
            } else {
                blocks.append(Block(kind: .paragraph(paragraph)))
            }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(Block(kind: .code(language, codeBuffer.joined(separator: "\n"))))
                    codeBuffer.removeAll()
                    language = nil
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                }
                continue
            }
            if inCode {
                codeBuffer.append(line)
            } else {
                buffer.append(line)
            }
        }

        if inCode {
            blocks.append(Block(kind: .code(language, codeBuffer.joined(separator: "\n"))))
        } else {
            flushParagraph()
        }
        return blocks
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language?.uppercased() ?? "CODE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}
