import Foundation
import JaplosProtocol

extension KernelCore {

    static func synthesizeSpeech(request: KernelRequest, store: KernelStore) async -> KernelResponse {
        let requestID = request.id
        guard let text = request.arguments["text"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .failure(.invalidArgument("text is required"), requestID: requestID)
        }

        let profile = (try? store.defaultSpeechProfile()) ?? .object([:])
        let record = profile["record"] ?? .object([:])
        let provider = (
            request.arguments["providerID"]?.stringValue
                ?? profile["providerID"]?.stringValue
                ?? record["provider"]?.stringValue
                ?? "system"
        ).lowercased()

        if provider != "volcengine" {
            return .success(.object([
                "provider": .string("system"),
                "fallback": .bool(true),
                "reason": .string("provider_is_system"),
            ]), requestID: requestID)
        }

        guard let credentials = store.resolvedVolcengineCredentials() else {
            FileHandle.standardError.write(Data("lucasd: speech.synthesize volcengine credentials missing → system fallback\n".utf8))
            return .success(.object([
                "provider": .string("system"),
                "fallback": .bool(true),
                "reason": .string("missing_credentials"),
            ]), requestID: requestID)
        }

        let voiceType = request.arguments["voiceType"]?.stringValue
            ?? record["volcengineVoiceType"]?.stringValue
            ?? "BV001_streaming"
        let cluster = request.arguments["cluster"]?.stringValue
            ?? record["volcengineCluster"]?.stringValue
            ?? "volcano_tts"
        let speed = request.arguments["speedRatio"]?.doubleValue
            ?? record["rate"]?.doubleValue.map { max(0.1, min(2.0, $0 * 2.0)) }
            ?? 1.0

        do {
            let result = try await VolcengineTTS.synthesize(
                text: text,
                appID: credentials.appID,
                token: credentials.token,
                voiceType: voiceType,
                cluster: cluster,
                encoding: "mp3",
                speedRatio: speed
            )
            return .success(.object([
                "provider": .string("volcengine"),
                "fallback": .bool(false),
                "encoding": .string(result.encoding),
                "data": .string(result.audioBase64),
                "reqID": .string(result.reqID),
            ]), requestID: requestID)
        } catch {
            let message = String(describing: error)
            FileHandle.standardError.write(Data("lucasd: speech.synthesize failed (\(message)) → system fallback\n".utf8))
            return .success(.object([
                "provider": .string("system"),
                "fallback": .bool(true),
                "reason": .string(message),
            ]), requestID: requestID)
        }
    }
}
