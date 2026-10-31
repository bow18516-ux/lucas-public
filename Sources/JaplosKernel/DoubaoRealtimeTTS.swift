import Foundation

/// Doubao / ByteDance OpenSpeech **realtime dialogue** TTS (Key-only).
/// Endpoint: `wss://openspeech.bytedance.com/api/v3/realtime/dialogue`
/// Auth headers: `X-Api-Key`, `X-Api-Resource-Id`, `X-Api-Connect-Id` (no AppID).
/// Speaks text via SAY_HELLO and collects pcm_s16le → WAV.
public enum DoubaoRealtimeTTS {
    public struct Result: Sendable {
        public var encoding: String
        public var audioBase64: String
        public var sampleRate: Int
        public var connectID: String
    }

    public enum Failure: Error, CustomStringConvertible {
        case missingAPIKey
        case connectFailed(String)
        case unexpectedEvent(expected: Int, got: Int?, detail: String)
        case timeout(String)
        case emptyAudio
        case transport(String)
        case protocolError(String)

        public var description: String {
            switch self {
            case .missingAPIKey:
                return "豆包 realtime API Key 未配置"
            case .connectFailed(let message):
                return "豆包 realtime 连接失败: \(message)"
            case .unexpectedEvent(let expected, let got, let detail):
                return "豆包 realtime 期望事件 \(expected)，收到 \(got.map(String.init) ?? "nil"): \(detail.prefix(160))"
            case .timeout(let message):
                return "豆包 realtime 超时: \(message)"
            case .emptyAudio:
                return "豆包 realtime 返回空音频"
            case .transport(let message):
                return "豆包 realtime 传输错误: \(message)"
            case .protocolError(let message):
                return "豆包 realtime 协议错误: \(message)"
            }
        }
    }

    public static func synthesize(
        text: String,
        apiKey: String,
        speaker: String = DoubaoRealtimeProtocol.defaultSpeaker,
        sampleRate: Int = DoubaoRealtimeProtocol.defaultSampleRate,
        resourceID: String = DoubaoRealtimeProtocol.defaultResourceID,
        url: URL = DoubaoRealtimeProtocol.defaultURL,
        session: URLSession = .shared
    ) async throws -> Result {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw Failure.missingAPIKey }

        let clipped = String(text.prefix(300))
        let connectID = UUID().uuidString
        let sessionID = UUID().uuidString

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(connectID, forHTTPHeaderField: "X-Api-Connect-Id")

        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        do {
            try await send(task, event: DoubaoRealtimeProtocol.startConnection, payload: [String: Any]())
            _ = try await expect(task, DoubaoRealtimeProtocol.connectionStarted, timeout: 10)

            let payload = DoubaoRealtimeProtocol.sessionPayload(speaker: speaker, sampleRate: sampleRate)
            try await send(task, event: DoubaoRealtimeProtocol.startSession, payload: payload, sessionID: sessionID)
            _ = try await expect(task, DoubaoRealtimeProtocol.sessionStarted, timeout: 10)

            try await send(
                task,
                event: DoubaoRealtimeProtocol.sayHello,
                payload: ["content": clipped],
                sessionID: sessionID
            )

            var pcm = Data()
            var first = true
            while true {
                let frame = try await receiveFrame(task, timeout: first ? 4 : 15)
                first = false
                if frame.msgType == DoubaoRealtimeProtocol.audioServer {
                    if let chunk = frame.payloadBytes, !chunk.isEmpty {
                        pcm.append(chunk)
                    }
                } else if frame.event == DoubaoRealtimeProtocol.ttsResponse,
                          let chunk = frame.payloadBytes, !chunk.isEmpty {
                    pcm.append(chunk)
                }
                if frame.event == DoubaoRealtimeProtocol.ttsEnded {
                    break
                }
                if frame.event == DoubaoRealtimeProtocol.dialogError {
            let detail: String
            if let json = frame.payloadJSON {
                detail = String(describing: json)
            } else if let bytes = frame.payloadBytes {
                detail = "\(bytes.count) bytes"
            } else {
                detail = ""
            }
                    throw Failure.protocolError(detail)
                }
                if frame.msgType == DoubaoRealtimeProtocol.errorType {
                    let detail = String(describing: frame.payloadJSON ?? [:])
                    throw Failure.protocolError("error code=\(frame.code.map(String.init) ?? "?") \(detail)")
                }
            }

            // Best-effort teardown; ignore failures.
            try? await send(task, event: DoubaoRealtimeProtocol.finishSession, payload: [String: Any](), sessionID: sessionID)
            try? await send(task, event: DoubaoRealtimeProtocol.finishConnection, payload: [String: Any]())

            guard !pcm.isEmpty else { throw Failure.emptyAudio }
            let wav = DoubaoRealtimeProtocol.wavFromPCM(pcm, sampleRate: sampleRate)
            return Result(
                encoding: "wav",
                audioBase64: wav.base64EncodedString(),
                sampleRate: sampleRate,
                connectID: connectID
            )
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.transport(String(describing: error))
        }
    }

    // MARK: - WebSocket helpers

    private static func send(
        _ task: URLSessionWebSocketTask,
        event: Int,
        payload: Any?,
        sessionID: String? = nil
    ) async throws {
        let data: Data
        do {
            data = try DoubaoRealtimeProtocol.encode(event: event, payload: payload, sessionID: sessionID)
        } catch {
            throw Failure.protocolError(String(describing: error))
        }
        try await task.send(.data(data))
    }

    private static func expect(
        _ task: URLSessionWebSocketTask,
        _ event: Int,
        timeout: TimeInterval
    ) async throws -> DoubaoRealtimeProtocol.Frame {
        let frame = try await receiveFrame(task, timeout: timeout)
        guard frame.event == event else {
            let detail: String
            if let json = frame.payloadJSON {
                detail = String(describing: json)
            } else if let bytes = frame.payloadBytes {
                detail = "\(bytes.count) bytes"
            } else {
                detail = ""
            }
            throw Failure.unexpectedEvent(expected: event, got: frame.event, detail: detail)
        }
        return frame
    }

    private static func receiveFrame(
        _ task: URLSessionWebSocketTask,
        timeout: TimeInterval
    ) async throws -> DoubaoRealtimeProtocol.Frame {
        let message = try await receiveMessage(task, timeout: timeout)
        let data: Data
        switch message {
        case .data(let d):
            data = d
        case .string(let s):
            data = Data(s.utf8)
        @unknown default:
            throw Failure.transport("unknown websocket message")
        }
        do {
            return try DoubaoRealtimeProtocol.decode(data)
        } catch {
            throw Failure.protocolError(String(describing: error))
        }
    }

    private static func receiveMessage(
        _ task: URLSessionWebSocketTask,
        timeout: TimeInterval
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask {
                try await task.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw Failure.timeout("\(timeout)s")
            }
            guard let first = try await group.next() else {
                throw Failure.timeout("no message")
            }
            group.cancelAll()
            return first
        }
    }
}
