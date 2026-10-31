import AVFoundation
import Foundation
import JaplosProtocol

/// Text-to-speech for assistant replies.
/// Default provider is system `AVSpeechSynthesizer`. Preferred cloud path is
/// `doubao-realtime` (OpenSpeech realtime dialogue, user-supplied Key only).
/// Legacy `volcengine` HTTP TTS (AppID+Token) remains available but is not
/// the primary product path. Any cloud failure falls back to system.
@MainActor
final class SpeechOutput: NSObject, ObservableObject {
    enum Provider: String, CaseIterable, Identifiable {
        case system
        case doubaoRealtime = "doubao-realtime"
        case volcengine
        case openaiCompatible = "openai-compatible"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "系统语音 · Apple"
            case .doubaoRealtime: return "豆包 realtime（推荐）"
            case .volcengine: return "火山 HTTP TTS（旧）"
            case .openaiCompatible: return "OpenAI 兼容（占位）"
            }
        }
    }

    @Published private(set) var isSpeaking = false
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }
    @Published var provider: Provider {
        didSet { defaults.set(provider.rawValue, forKey: Keys.provider) }
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
    /// Draft fields for Volcengine settings UI (token not persisted to UserDefaults).
    @Published var volcengineAppID: String = ""
    @Published var volcengineToken: String = ""
    @Published var volcengineVoiceType: String {
        didSet { defaults.set(volcengineVoiceType, forKey: Keys.volcVoice) }
    }
    @Published var volcengineCluster: String {
        didSet { defaults.set(volcengineCluster, forKey: Keys.volcCluster) }
    }
    @Published private(set) var volcengineConfigured = false
    /// Draft Doubao realtime API Key (never written to UserDefaults; SecretStore via kernel).
    @Published var doubaoAPIKey: String = ""
    @Published var doubaoSpeaker: String {
        didSet { defaults.set(doubaoSpeaker, forKey: Keys.doubaoSpeaker) }
    }
    @Published private(set) var doubaoConfigured = false
    @Published private(set) var lastCloudError: String?

    /// Injected by AppModel so cloud TTS can call the kernel without coupling.
    var cloudSynthesize: ((String) async -> (Data, String)?)?

    var onSpeakingChanged: ((Bool) -> Void)?

    private enum Keys {
        static let enabled = "japlos.voice.output.enabled"
        static let provider = "japlos.voice.output.provider"
        static let voice = "japlos.voice.output.voice"
        static let rate = "japlos.voice.output.rate"
        static let pitch = "japlos.voice.output.pitch"
        static let language = "japlos.voice.language"
        static let input = "japlos.voice.input"
        static let volcVoice = "japlos.voice.volc.voiceType"
        static let volcCluster = "japlos.voice.volc.cluster"
        static let doubaoSpeaker = "japlos.voice.doubao.speaker"
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let defaults = UserDefaults.standard
    private var audioPlayer: AVAudioPlayer?
    private var speakTask: Task<Void, Never>?

    override init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        let rawProvider = defaults.string(forKey: Keys.provider) ?? Provider.system.rawValue
        provider = Provider(rawValue: rawProvider) ?? .system
        voiceIdentifier = defaults.string(forKey: Keys.voice) ?? ""
        rate = defaults.object(forKey: Keys.rate) as? Double ?? 0.50
        pitch = defaults.object(forKey: Keys.pitch) as? Double ?? 1.0
        languageCode = defaults.string(forKey: Keys.language) ?? "zh-CN"
        inputDeviceUID = defaults.string(forKey: Keys.input) ?? ""
        volcengineVoiceType = defaults.string(forKey: Keys.volcVoice) ?? "BV001_streaming"
        volcengineCluster = defaults.string(forKey: Keys.volcCluster) ?? "volcano_tts"
        doubaoSpeaker = defaults.string(forKey: Keys.doubaoSpeaker) ?? DoubaoVoicePresets.defaultSpeaker
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

    func markVolcengineConfigured(_ configured: Bool) {
        volcengineConfigured = configured
    }

    func markDoubaoConfigured(_ configured: Bool) {
        doubaoConfigured = configured
    }

    func noteCloudError(_ message: String?) {
        lastCloudError = message
    }

    func speak(_ text: String) {
        guard enabled else { return }
        let clean = Self.speakable(text)
        guard !clean.isEmpty else { return }
        stop()

        switch provider {
        case .system, .openaiCompatible:
            // openai-compatible is a stub — always system until wired.
            speakSystem(clean)
        case .doubaoRealtime, .volcengine:
            speakTask = Task { [weak self] in
                guard let self else { return }
                let label = self.provider == .doubaoRealtime ? "doubao-realtime" : "volcengine"
                if let cloud = self.cloudSynthesize, let (data, _) = await cloud(clean) {
                    await MainActor.run {
                        if Task.isCancelled { return }
                        if self.playCloudAudio(data) { return }
                        AppLog.write("speech: cloud audio play failed → system fallback")
                        self.noteCloudError("cloud_audio_play_failed")
                        self.speakSystem(clean)
                    }
                } else {
                    await MainActor.run {
                        if Task.isCancelled { return }
                        let reason = self.lastCloudError ?? "unavailable"
                        AppLog.write("speech: \(label) unavailable (\(reason)) → system fallback")
                        self.speakSystem(clean)
                    }
                }
            }
        }
    }

    func stop() {
        speakTask?.cancel()
        speakTask = nil
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        if isSpeaking {
            isSpeaking = false
            onSpeakingChanged?(false)
        }
    }

    private func speakSystem(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        if !voiceIdentifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: languageCode.isEmpty ? "zh-CN" : languageCode)
        }
        utterance.rate = Float(min(max(rate, 0.35), 0.65))
        utterance.pitchMultiplier = Float(min(max(pitch, 0.5), 2.0))
        synthesizer.speak(utterance)
    }

    @discardableResult
    private func playCloudAudio(_ data: Data) -> Bool {
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            audioPlayer = player
            guard player.play() else { return false }
            isSpeaking = true
            onSpeakingChanged?(true)
            return true
        } catch {
            lastCloudError = String(describing: error)
            return false
        }
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

extension SpeechOutput: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isSpeaking = false
            self.onSpeakingChanged?(false)
            self.audioPlayer = nil
        }
    }
}
