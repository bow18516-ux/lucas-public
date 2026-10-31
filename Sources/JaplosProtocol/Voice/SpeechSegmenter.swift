import Foundation

/// Cuts a streaming assistant reply into speakable sentences so TTS can start
/// on the first sentence while the model is still writing (original Japlos
/// streamed playback; Lucas ≤0.5.10 waited for `done` + the whole clip).
///
/// Skips fenced code, strips markdown markers, caps total spoken characters.
public struct SpeechSegmenter: Sendable {
    public static let terminators: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "…"]

    public let maxTotal: Int
    public private(set) var emittedCharacters = 0
    private var buffer = ""
    private var inCode = false
    /// True while `buffer` starts at the beginning of a source line.
    private var atLineStart = true

    public init(maxTotal: Int = 600) {
        self.maxTotal = maxTotal
    }

    /// Feed a delta; returns sentences that are complete and ready to speak.
    public mutating func append(_ delta: String) -> [String] {
        buffer += delta
        var out: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            out += takeLine(line, complete: true)
            atLineStart = true
        }
        out += takePartial()
        return cap(out)
    }

    /// Flush whatever is left once the reply is done.
    public mutating func finish() -> [String] {
        let rest = buffer
        buffer = ""
        let out = takeLine(rest, complete: true)
        atLineStart = true
        inCode = false
        return cap(out)
    }

    private mutating func takeLine(_ line: String, complete: Bool) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if atLineStart, trimmed.hasPrefix("```") {
            inCode.toggle()
            return []
        }
        if inCode { return [] }
        let clean = Self.clean(trimmed, atLineStart: atLineStart)
        return clean.isEmpty ? [] : [Self.terminate(clean)]
    }

    /// Emit each finished sentence of an unfinished line.
    private mutating func takePartial() -> [String] {
        if inCode { return [] }
        let head = buffer.trimmingCharacters(in: .whitespaces)
        if atLineStart {
            // Could still become a ``` fence line: wait.
            if head.count < 3, "```".hasPrefix(head) { return [] }
            if head.hasPrefix("```") { return [] }
        }
        var out: [String] = []
        while let cut = buffer.firstIndex(where: { Self.terminators.contains($0) }) {
            let piece = String(buffer[...cut])
            buffer.removeSubrange(...cut)
            let clean = Self.clean(piece.trimmingCharacters(in: .whitespaces), atLineStart: atLineStart)
            atLineStart = false
            if !clean.isEmpty { out.append(clean) }
        }
        return out
    }

    private mutating func cap(_ pieces: [String]) -> [String] {
        var out: [String] = []
        for piece in pieces {
            let room = maxTotal - emittedCharacters
            guard room > 0 else { break }
            let taken = String(piece.prefix(room))
            emittedCharacters += taken.count
            out.append(taken)
        }
        return out
    }

    static func terminate(_ text: String) -> String {
        guard let last = text.last else { return text }
        if terminators.contains(last) || "，,：:".contains(last) { return text }
        return text + "。"
    }

    public static func clean(_ text: String, atLineStart: Bool) -> String {
        var clean = text
        for marker in ["**", "__", "`"] {
            clean = clean.replacingOccurrences(of: marker, with: "")
        }
        if atLineStart {
            if clean.hasPrefix("#") {
                clean = clean.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            }
            if clean.hasPrefix("- ") || clean.hasPrefix("* ") { clean = String(clean.dropFirst(2)) }
        }
        clean = clean.replacingOccurrences(of: "（见上方链接）", with: "")
        return clean.trimmingCharacters(in: .whitespaces)
    }
}

/// When a Space key event should drive push-to-talk instead of typing.
/// Mirrors original Japlos: foreground, no settings sheet, not editing text
/// (composer empty), no IME composition, no modifiers.
public enum PushToTalkGate {
    public static func shouldHandle(
        isSpace: Bool,
        hasModifiers: Bool,
        appActive: Bool,
        overlayPresented: Bool,
        composerText: String,
        imeComposing: Bool,
        focusInOtherTextField: Bool
    ) -> Bool {
        guard isSpace, !hasModifiers, appActive, !overlayPresented, !imeComposing, !focusInOtherTextField else {
            return false
        }
        return composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
