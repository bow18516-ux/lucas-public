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

        switch provider {
        case "doubao-realtime", "doubao_realtime", "doubao":
            return await synthesizeDoubaoRealtime(text: text, request: request, record: record, store: store, requestID: requestID)
        case "volcengine":
            return await synthesizeVolcengineHTTP(text: text, request: request, record: record, store: store, requestID: requestID)
        default:
            return .success(.object([
                "provider": .string("system"),
                "fallback": .bool(true),
                "reason": .string("provider_is_system"),
            ]), requestID: requestID)
        }
    }

    private static func synthesizeDoubaoRealtime(
        text: String,
        request: KernelRequest,
        record: JSONValue,
        store: KernelStore,
        requestID: String
    ) async -> KernelResponse {
        guard let apiKey = store.resolvedDoubaoAPIKey() else {
            FileHandle.standardError.write(Data("lucasd: speech.synthesize doubao-realtime key missing → system fallback\n".utf8))
            return .success(.object([
                "provider": .string("system"),
                "fallback": .bool(true),
                "reason": .string("missing_credentials"),
            ]), requestID: requestID)
        }

        let speaker = DoubaoRealtimeProtocol.normalizeSpeaker(
            request.arguments["speaker"]?.stringValue
                ?? request.arguments["voiceType"]?.stringValue
                ?? record["doubaoSpeaker"]?.stringValue
        )

        do {
            let result = try await DoubaoRealtimeTTS.synthesize(
                text: text,
                apiKey: apiKey,
                speaker: speaker
            )
            return .success(.object([
                "provider": .string("doubao-realtime"),
                "fallback": .bool(false),
                "encoding": .string(result.encoding),
                "data": .string(result.audioBase64),
                "sampleRate": .number(Double(result.sampleRate)),
                "connectID": .string(result.connectID),
            ]), requestID: requestID)
        } catch {
            let message = String(describing: error)
            // Never include the API key in logs — Failure.description already avoids it.
            FileHandle.standardError.write(Data("lucasd: speech.synthesize doubao-realtime failed (\(message)) → system fallback\n".utf8))
            return .success(.object([
                "provider": .string("system"),
                "fallback": .bool(true),
                "reason": .string(message),
            ]), requestID: requestID)
        }
    }

    private static func synthesizeVolcengineHTTP(
        text: String,
        request: KernelRequest,
        record: JSONValue,
        store: KernelStore,
        requestID: String
    ) async -> KernelResponse {
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
