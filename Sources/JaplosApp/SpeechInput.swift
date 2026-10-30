import AVFoundation
import Foundation
import Speech

/// Push-to-talk speech input built on the system recognizer.
/// The daemon never sees audio; only the final transcript is sent as a message.
@MainActor
final class SpeechInput: ObservableObject {
    @Published private(set) var isRecording = false
    @Published var transcript = ""
    @Published var errorText: String?

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()

    func toggle() {
        if isRecording {
            stop()
        } else {
            start()
        }
    }

    func start(language: String = "zh-CN", deviceUID: String = "") {
        guard !isRecording else { return }
        transcript = ""
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.errorText = "需要在系统设置中允许语音识别"
                    return
                }
                self.requestMicrophone(language: language, deviceUID: deviceUID)
            }
        }
    }

    private func requestMicrophone(language: String, deviceUID: String) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.errorText = "需要在系统设置中允许麦克风访问"
                    return
                }
                self.begin(language: language, deviceUID: deviceUID)
            }
        }
    }

    private func begin(language: String, deviceUID: String) {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language))
        self.recognizer = recognizer
        guard let recognizer, recognizer.isAvailable else {
            errorText = "当前没有可用的语音识别服务"
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            errorText = "没有可用的麦克风输入"
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        if let device = AudioDevices.deviceID(forUID: deviceUID), let unit = input.audioUnit {
            var deviceID = device
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            errorText = "麦克风启动失败：\(error.localizedDescription)"
            return
        }

        isRecording = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil, !self.transcript.isEmpty {
                    self.stop()
                }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
    }
}
