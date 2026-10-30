import AVFoundation
import Foundation

/// System text-to-speech for assistant replies. The original product streams
/// cloud TTS; this clone uses the built-in voices so it works offline and
/// without credentials.
@MainActor
final class SpeechOutput: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }
    @Published var voiceIdentifier: String {
        didSet { defaults.set(voiceIdentifier, forKey: Keys.voice) }
    }
    @Published var rate: Double {
        didSet { defaults.set(rate, forKey: Keys.rate) }
    }
    @Published var pitch: Double {
        didSet { defaults.set(pitch, forKey: Keys.pitch) }
    }
    @Published var languageCode: String {
        didSet { defaults.set(languageCode, forKey: Keys.language) }
    }
    @Published var inputDeviceUID: String {
        didSet { defaults.set(inputDeviceUID, forKey: Keys.input) }
    }

    var onSpeakingChanged: ((Bool) -> Void)?

    private enum Keys {
        static let enabled = "japlos.voice.output.enabled"
        static let voice = "japlos.voice.output.voice"
        static let rate = "japlos.voice.output.rate"
        static let pitch = "japlos.voice.output.pitch"
        static let language = "japlos.voice.language"
        static let input = "japlos.voice.input"
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let defaults = UserDefaults.standard

    override init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        voiceIdentifier = defaults.string(forKey: Keys.voice) ?? ""
        rate = defaults.object(forKey: Keys.rate) as? Double ?? 0.50
        pitch = defaults.object(forKey: Keys.pitch) as? Double ?? 1.0
        languageCode = defaults.string(forKey: Keys.language) ?? "zh-CN"
        inputDeviceUID = defaults.string(forKey: Keys.input) ?? ""
        super.init()
        synthesizer.delegate = self
    }

    static var chineseVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
            .sorted { $0.name < $1.name }
    }

    static var englishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { $0.name < $1.name }
    }

    func speak(_ text: String) {
        guard enabled else { return }
        let clean = Self.speakable(text)
        guard !clean.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: clean)
        if !voiceIdentifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        utterance.rate = Float(min(max(rate, 0.35), 0.65))
        utterance.pitchMultiplier = Float(min(max(pitch, 0.5), 2.0))
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Speech should not read code fences, markdown markers or long URLs.
    static func speakable(_ text: String) -> String {
        var result = ""
        var inCode = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode { continue }
            var clean = trimmed
            clean = clean.replacingOccurrences(of: "**", with: "")
            clean = clean.replacingOccurrences(of: "__", with: "")
            clean = clean.replacingOccurrences(of: "`", with: "")
            if clean.hasPrefix("#") {
                clean = clean.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            }
            if clean.hasPrefix("- ") { clean = String(clean.dropFirst(2)) }
            if clean.hasPrefix("* ") { clean = String(clean.dropFirst(2)) }
            clean = clean.replacingOccurrences(of: "（见上方链接）", with: "")
            if !clean.isEmpty { result += clean + "。" }
        }
        let collapsed = result.replacingOccurrences(of: "。。", with: "。")
        return String(collapsed.prefix(600))
    }
}

extension SpeechOutput: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = true
            self.onSpeakingChanged?(true)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.onSpeakingChanged?(false)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.onSpeakingChanged?(false)
        }
    }
}
