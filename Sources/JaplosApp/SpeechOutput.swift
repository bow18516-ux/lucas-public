import AVFoundation
import Foundation
import JaplosProtocol

/// Text-to-speech for assistant replies.
/// Default provider is system `AVSpeechSynthesizer`. Preferred cloud path is
/// `doubao-realtime` (OpenSpeech realtime dialogue, user-supplied Key only).
/// Only two providers exist (0.5.10+); legacy ids migrate via
/// `SpeechProviderPolicy`. Any cloud failure falls back to system.
@MainActor
final class SpeechOutput: NSObject, ObservableObject {
    enum Provider: String, CaseIterable, Identifiable {
        case system
        case doubaoRealtime = "doubao-realtime"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "系统语音（苹果）"
            case .doubaoRealtime: return "豆包实时语音（推荐）"
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
        static let doubaoSpeaker = "japlos.voice.doubao.speaker"
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let defaults = UserDefaults.standard
    private var audioPlayer: AVAudioPlayer?
    private var speakTask: Task<Void, Never>?

    override init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        // Key presence is unknown until the kernel profile loads; AppModel
        // re-resolves with `hasDoubaoKey` then. Legacy ids → system here.
        let resolved = SpeechProviderPolicy.resolve(defaults.string(forKey: Keys.provider), hasDoubaoKey: false)
        provider = Provider(rawValue: resolved) ?? .system
        voiceIdentifier = defaults.string(forKey: Keys.voice) ?? ""
        rate = defaults.object(forKey: Keys.rate) as? Double ?? 0.50
        pitch = defaults.object(forKey: Keys.pitch) as? Double ?? 1.0
        languageCode = defaults.string(forKey: Keys.language) ?? "zh-CN"
        inputDeviceUID = defaults.string(forKey: Keys.input) ?? ""
        doubaoSpeaker = defaults.string(forKey: Keys.doubaoSpeaker) ?? DoubaoVoicePresets.defaultSpeaker
        super.init()
        defaults.set(provider.rawValue, forKey: Keys.provider)
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

    func markDoubaoConfigured(_ configured: Bool) {
        doubaoConfigured = configured
    }

    func noteCloudError(_ message: String?) {
        lastCloudError = message
    }

    // MARK: Streaming reply playback
    //
    // Root cause of the ~5 s lag (≤0.5.10): speech only started on `done`,
    // and the Doubao path opened a fresh WebSocket and buffered the WHOLE
    // clip before returning it. Now replies are cut into sentences while the
    // model streams; sentence N+1 synthesises while sentence N plays.

    private struct PendingClip {
        let text: String
        var job: Task<Data?, Never>?
    }

    private var segmenter = SpeechSegmenter()
    private var replyActive = false
    private var replySawDelta = false
    private var clips: [PendingClip] = []
    private var clipPlaying = false
    private var playbackTask: Task<Void, Never>?
    private var generation = 0
    private var playContinuation: CheckedContinuation<Bool, Never>?
    private var systemContinuation: CheckedContinuation<Void, Never>?
    private var replyStartedAt: Date?
    private var replyDoneAt: Date?
    private var firstAudioLogged = false
    private static let prefetchWindow = 2

    /// Call when a new assistant reply starts streaming.
    func beginReply() {
        stop()
        guard enabled else { return }
        segmenter = SpeechSegmenter()
        replyActive = true
        replySawDelta = false
        replyStartedAt = Date()
        replyDoneAt = nil
        firstAudioLogged = false
    }

    func feedReply(_ delta: String) {
        guard replyActive, enabled, !delta.isEmpty else { return }
        replySawDelta = true
        enqueue(segmenter.append(delta))
    }

    /// `finalText` is spoken only if no deltas arrived (non-streaming turn).
    func finishReply(_ finalText: String) {
        guard replyActive else { return }
        replyDoneAt = Date()
        if !replySawDelta, enabled { enqueue(segmenter.append(finalText)) }
        if enabled { enqueue(segmenter.finish()) }
        replyActive = false
        settleIfIdle()
    }

    func speak(_ text: String) {
        beginReply()
        guard replyActive else { return }
        finishReply(text)
    }

    private func enqueue(_ segments: [String]) {
        guard !segments.isEmpty else { return }
        for segment in segments where !segment.isEmpty {
            clips.append(PendingClip(text: segment, job: nil))
        }
        pump()
    }

    private func pump() {
        if provider == .doubaoRealtime {
            for index in clips.indices.prefix(Self.prefetchWindow) where clips[index].job == nil {
                let text = clips[index].text
                clips[index].job = Task { [weak self] in
                    guard let self, let cloud = self.cloudSynthesize else { return nil }
                    return await cloud(text)?.0
                }
            }
        }
        guard !clipPlaying, !clips.isEmpty else { return }
        clipPlaying = true
        let clip = clips.removeFirst()
        let gen = generation
        pump()
        playbackTask = Task { [weak self] in
            guard let self else { return }
            var played = false
            if let job = clip.job, let data = await job.value, gen == self.generation, !Task.isCancelled {
                played = await self.playAndWait(data)
                if !played, gen == self.generation, self.provider == .doubaoRealtime, self.lastCloudError == nil {
                    self.noteCloudError("cloud_audio_play_failed")
                }
            }
            guard gen == self.generation, !Task.isCancelled else { return }
            if !played {
                if self.provider == .doubaoRealtime {
                    AppLog.write("speech: doubao-realtime unavailable (\(self.lastCloudError ?? "unavailable")) → system fallback")
                }
                await self.speakSystemAndWait(clip.text)
            }
            guard gen == self.generation else { return }
            self.clipPlaying = false
            self.pump()
            self.settleIfIdle()
        }
    }

    private func settleIfIdle() {
        guard !replyActive, !clipPlaying, clips.isEmpty, isSpeaking else { return }
        isSpeaking = false
        onSpeakingChanged?(false)
    }

    private func noteAudioStarted() {
        if !isSpeaking {
            isSpeaking = true
            onSpeakingChanged?(true)
        }
        guard !firstAudioLogged, let start = replyStartedAt else { return }
        firstAudioLogged = true
        let now = Date()
        let sinceStart = Int(now.timeIntervalSince(start) * 1000)
        let sinceDone = replyDoneAt.map { "\(Int(now.timeIntervalSince($0) * 1000))ms after done" } ?? "before done"
        AppLog.write("speech: first audio \(provider.rawValue) +\(sinceStart)ms from reply start (\(sinceDone))")
    }

    private func playAndWait(_ data: Data) async -> Bool {
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: data)
        } catch {
            lastCloudError = String(describing: error)
            return false
        }
        player.delegate = self
        player.prepareToPlay()
        audioPlayer = player
        guard player.play() else { return false }
        noteAudioStarted()
        return await withCheckedContinuation { continuation in
            playContinuation = continuation
        }
    }

    private func speakSystemAndWait(_ text: String) async {
        speakSystem(text)
        noteAudioStarted()
        await withCheckedContinuation { continuation in
            systemContinuation = continuation
        }
    }

    func stop() {
        generation += 1
        replyActive = false
        for clip in clips { clip.job?.cancel() }
        clips.removeAll()
        clipPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        playContinuation?.resume(returning: false)
        playContinuation = nil
        systemContinuation?.resume()
        systemContinuation = nil
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
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {}

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.systemContinuation?.resume()
            self.systemContinuation = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.systemContinuation?.resume()
            self.systemContinuation = nil
        }
    }
}

extension SpeechOutput: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.audioPlayer === player else { return }
            self.audioPlayer = nil
            self.playContinuation?.resume(returning: true)
            self.playContinuation = nil
        }
    }
}
