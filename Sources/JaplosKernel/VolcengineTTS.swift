import Foundation
import JaplosProtocol

/// Minimal Volcengine / ByteDance OpenSpeech HTTP TTS client (v1 non-streaming).
/// Docs: POST https://openspeech.bytedance.com/api/v1/tts
/// Authorization: Bearer;${token}  (semicolon, not a space)
public enum VolcengineTTS {
    public static let endpoint = URL(string: "https://openspeech.bytedance.com/api/v1/tts")!

    public struct Result: Sendable {
        public var encoding: String
        public var audioBase64: String
        public var reqID: String
    }

    public enum Failure: Error, CustomStringConvertible {
        case missingCredentials
        case httpStatus(Int, String)
        case apiError(String)
        case emptyAudio
        case transport(String)

        public var description: String {
            switch self {
            case .missingCredentials:
                return "Volcengine App ID / Token 未配置"
            case .httpStatus(let code, let body):
                return "Volcengine HTTP \(code): \(body.prefix(200))"
            case .apiError(let message):
                return message
            case .emptyAudio:
                return "Volcengine 返回空音频"
            case .transport(let message):
                return message
            }
        }
    }

    public static func synthesize(
        text: String,
        appID: String,
        token: String,
        voiceType: String = "BV001_streaming",
        cluster: String = "volcano_tts",
        encoding: String = "mp3",
        speedRatio: Double = 1.0,
        session: URLSession = .shared
    ) async throws -> Result {
        let cleanApp = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanApp.isEmpty, !cleanToken.isEmpty else { throw Failure.missingCredentials }

        let clipped = String(text.prefix(300))
        let reqID = UUID().uuidString
        let body: [String: Any] = [
            "app": [
                "appid": cleanApp,
                "token": cleanToken,
                "cluster": cluster.isEmpty ? "volcano_tts" : cluster,
            ],
            "user": ["uid": "lucas-local"],
            "audio": [
                "voice_type": voiceType.isEmpty ? "BV001_streaming" : voiceType,
                "encoding": encoding,
                "speed_ratio": speedRatio,
            ],
            "request": [
                "reqid": reqID,
                "text": clipped,
                "operation": "query",
            ],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Volcengine uses "Bearer;token" with a semicolon (documented quirk).
        request.setValue("Bearer;\(cleanToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(String(describing: error))
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(status) else {
            throw Failure.httpStatus(status, raw)
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw Failure.apiError("无法解析 Volcengine JSON")
        }

        if let code = object["code"] as? Int, code != 3000 {
            let message = (object["message"] as? String) ?? "code \(code)"
            throw Failure.apiError("Volcengine \(message)")
        }
        if let code = object["code"] as? String, code != "3000", Int(code) != 3000 {
            let message = (object["message"] as? String) ?? "code \(code)"
            throw Failure.apiError("Volcengine \(message)")
        }

        guard let audio = object["data"] as? String, !audio.isEmpty else {
            throw Failure.emptyAudio
        }

        return Result(encoding: encoding, audioBase64: audio, reqID: reqID)
    }
}
