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
}
