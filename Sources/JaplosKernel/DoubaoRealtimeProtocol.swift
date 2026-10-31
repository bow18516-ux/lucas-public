import Foundation
import JaplosProtocol
import zlib

/// Binary frame codec for Doubao realtime dialogue 2.0
/// (`wss://openspeech.bytedance.com/api/v3/realtime/dialogue`).
/// Wire layout and event ids align with Xiaoling `voice_runtime.protocol` (no secrets).
public enum DoubaoRealtimeProtocol {
    public static let defaultURL = URL(string: "wss://openspeech.bytedance.com/api/v3/realtime/dialogue")!
    public static let defaultResourceID = "volc.speech.dialog"
    public static let defaultModel = "1.2.1.1"
    public static let defaultSpeaker = DoubaoVoicePresets.defaultSpeaker
    public static let defaultSampleRate = 24_000
    public static let speakerPresets = DoubaoVoicePresets.all

    public static func speakerLabel(for id: String) -> String {
        DoubaoVoicePresets.label(for: id)
    }

    public static func normalizeSpeaker(_ id: String?) -> String {
        DoubaoVoicePresets.normalize(id)
    }


    public static let fullClient = 0b0001
    public static let audioClient = 0b0010
    public static let fullServer = 0b1001
    public static let audioServer = 0b1011
    public static let errorType = 0b1111

    public static let flagSeqPos = 0b0001
    public static let flagSeqLast = 0b0010
    public static let flagSeqNeg = 0b0011
    public static let flagEvent = 0b0100

    public static let serRaw = 0
    public static let serJSON = 1
    public static let noComp = 0
    public static let gzipComp = 1

    public static let startConnection = 1
    public static let finishConnection = 2
    public static let startSession = 100
    public static let finishSession = 102
    public static let taskRequest = 200
    public static let sayHello = 300
    public static let chatTTSText = 500

    public static let connectionStarted = 50
    public static let connectionFailed = 51
    public static let connectionFinished = 52
    public static let sessionStarted = 150
    public static let sessionFinished = 152
    public static let sessionFailed = 153
    public static let ttsResponse = 352
    public static let ttsEnded = 359
    public static let dialogError = 599

    public static let connectEvents: Set<Int> = [
        startConnection, finishConnection,
        connectionStarted, connectionFailed, connectionFinished,
    ]

    public struct Frame {
        public var msgType: Int
        public var event: Int?
        public var sessionID: String?
        public var payloadJSON: [String: Any]?
        public var payloadBytes: Data?
        public var code: Int?
        public var sequence: Int?
        public var connectID: String?

        public init(
            msgType: Int,
            event: Int? = nil,
            sessionID: String? = nil,
            payloadJSON: [String: Any]? = nil,
            payloadBytes: Data? = nil,
            code: Int? = nil,
            sequence: Int? = nil,
            connectID: String? = nil
        ) {
            self.msgType = msgType
            self.event = event
            self.sessionID = sessionID
            self.payloadJSON = payloadJSON
            self.payloadBytes = payloadBytes
            self.code = code
            self.sequence = sequence
            self.connectID = connectID
        }
    }

    public enum CodecError: Error, CustomStringConvertible {
        case frameTooShort
        case gzipExpandLimit
        case gzipFailed
        case invalidJSON

        public var description: String {
            switch self {
            case .frameTooShort: return "doubao frame too short"
            case .gzipExpandLimit: return "doubao gzip expands past limit"
            case .gzipFailed: return "doubao gzip failed"
            case .invalidJSON: return "doubao invalid JSON payload"
            }
        }
    }

    private static func header(msgType: Int, flags: Int, ser: Int, comp: Int = noComp) -> Data {
        Data([0x11, UInt8((msgType << 4) | flags), UInt8((ser << 4) | comp), 0x00])
    }

    private static func packU32(_ value: Int, signed: Bool = false) -> Data {
        let host: UInt32 = signed ? UInt32(bitPattern: Int32(value)) : UInt32(value)
        var be = host.bigEndian
        return Data(bytes: &be, count: 4)
    }

    public static func compactJSON(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodecError.invalidJSON
        }
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    public static func encode(
        event: Int,
        payload: Any? = nil,
        sessionID: String? = nil,
        audio: Bool = false,
        compress: Bool = false
    ) throws -> Data {
        let body: Data
        let head: Data
        if audio {
            body = (payload as? Data) ?? Data()
            head = header(msgType: audioClient, flags: flagEvent, ser: serRaw, comp: compress ? gzipComp : noComp)
        } else {
            let object: Any = payload ?? [String: Any]()
            body = try compactJSON(object)
            head = header(msgType: fullClient, flags: flagEvent, ser: serJSON, comp: compress ? gzipComp : noComp)
        }
        var wireBody = body
        if compress {
            wireBody = try gzipCompress(body)
        }
        var out = Data()
        out.append(head)
        out.append(packU32(event))
        if !connectEvents.contains(event) {
            let sid = Data((sessionID ?? "").utf8)
            out.append(packU32(sid.count))
            out.append(sid)
        }
        out.append(packU32(wireBody.count))
        out.append(wireBody)
        return out
    }

    public static func decode(_ data: Data, gunzipLimit: Int = 16 << 20) throws -> Frame {
        guard data.count >= 4 else { throw CodecError.frameTooShort }
        let bytes = [UInt8](data)
        let hsize = Int(bytes[0] & 0x0F) * 4
        let msgType = Int(bytes[1] >> 4)
        let flags = Int(bytes[1] & 0x0F)
        let ser = Int(bytes[2] >> 4)
        let comp = Int(bytes[2] & 0x0F)
        var p = hsize

        func u32(signed: Bool = false) throws -> Int {
            guard p + 4 <= bytes.count else { throw CodecError.frameTooShort }
            let b0 = UInt32(bytes[p])
            let b1 = UInt32(bytes[p + 1])
            let b2 = UInt32(bytes[p + 2])
            let b3 = UInt32(bytes[p + 3])
            p += 4
            let host = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            if signed { return Int(Int32(bitPattern: host)) }
            return Int(host)
        }

        var frame = Frame(msgType: msgType)
        if msgType == errorType {
            frame.code = try u32()
        }
        if flags == flagSeqPos || flags == flagSeqNeg {
            frame.sequence = try u32(signed: true)
        }
        if (flags & flagEvent) != 0 {
            frame.event = try u32()
        }
        if [fullServer, audioServer, fullClient, audioClient].contains(msgType), frame.event != nil {
            let n = try u32(signed: true)
            if n > 0 {
                guard p + n <= bytes.count else { throw CodecError.frameTooShort }
                let ident = String(bytes: bytes[p..<p + n], encoding: .utf8) ?? ""
                p += n
                if let event = frame.event, connectEvents.contains(event) {
                    frame.connectID = ident
                } else {
                    frame.sessionID = ident
                }
            }
        }
        let size = try u32()
        guard p + size <= bytes.count else { throw CodecError.frameTooShort }
        var body = Data(bytes[p..<p + size])
        if comp == gzipComp, !body.isEmpty {
            body = try gunzip(body, limit: gunzipLimit)
        }
        if ser == serJSON, msgType != audioServer {
            if body.isEmpty {
                frame.payloadJSON = [:]
            } else if let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                frame.payloadJSON = obj
            } else if let raw = String(data: body, encoding: .utf8) {
                frame.payloadJSON = ["_raw": raw]
            } else {
                throw CodecError.invalidJSON
            }
        } else if msgType == errorType {
            if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                frame.payloadJSON = obj
            } else if let raw = String(data: body, encoding: .utf8) {
                frame.payloadJSON = ["error": raw]
            }
        } else {
            frame.payloadBytes = body
        }
        return frame
    }

    public static func sessionPayload(
        speaker: String = defaultSpeaker,
        sampleRate: Int = defaultSampleRate,
        model: String = defaultModel,
        systemRole: String = "你是老板的私人助理，说话简短自然。"
    ) -> [String: Any] {
        [
            "asr": [
                "extra": [
                    "end_smooth_window_ms": 500,
                    "enable_custom_vad": true,
                ] as [String: Any],
            ] as [String: Any],
            "tts": [
                "speaker": speaker,
                "audio_config": [
                    "channel": 1,
                    "format": "pcm_s16le",
                    "sample_rate": sampleRate,
                ] as [String: Any],
                "extra": [String: Any](),
            ] as [String: Any],
            "dialog": [
                "bot_name": "助手",
                "dialog_id": "",
                "system_role": systemRole,
                "speaking_style": "语速适中，口语化。",
                "extra": [
                    "strict_audit": false,
                    "model": model,
                    "enable_loudness_norm": true,
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    public static func wavFromPCM(_ pcm: Data, sampleRate: Int = defaultSampleRate, channels: Int = 1) -> Data {
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func le32(_ v: Int) {
            var x = UInt32(v).littleEndian
            data.append(Data(bytes: &x, count: 4))
        }
        func le16(_ v: Int) {
            var x = UInt16(v).littleEndian
            data.append(Data(bytes: &x, count: 2))
        }
        ascii("RIFF")
        le32(36 + pcm.count)
        ascii("WAVE")
        ascii("fmt ")
        le32(16)
        le16(1)
        le16(channels)
        le32(sampleRate)
        le32(byteRate)
        le16(blockAlign)
        le16(bitsPerSample)
        ascii("data")
        le32(pcm.count)
        data.append(pcm)
        return data
    }

    public static func gzipCompress(_ input: Data) throws -> Data {
        var stream = z_stream()
        var status = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            15 + 16, // gzip
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw CodecError.gzipFailed }
        defer { deflateEnd(&stream) }

        var output = Data()
        var inputCopy = input
        try inputCopy.withUnsafeMutableBytes { src in
            stream.next_in = src.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(input.count)
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let produced: Int = buffer.withUnsafeMutableBufferPointer { dst in
                    stream.next_out = dst.baseAddress
                    stream.avail_out = uInt(dst.count)
                    status = deflate(&stream, Z_FINISH)
                    return dst.count - Int(stream.avail_out)
                }
                if produced > 0 {
                    output.append(buffer, count: produced)
                }
                if status == Z_STREAM_END { break }
                if status != Z_OK { throw CodecError.gzipFailed }
            }
        }
        return output
    }

    public static func gunzip(_ input: Data, limit: Int = 16 << 20) throws -> Data {
        var stream = z_stream()
        var status = inflateInit2_(
            &stream,
            15 + 32, // gzip/zlib auto
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw CodecError.gzipFailed }
        defer { inflateEnd(&stream) }

        var output = Data()
        var inputCopy = input
        try inputCopy.withUnsafeMutableBytes { src in
            stream.next_in = src.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(input.count)
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let produced: Int = buffer.withUnsafeMutableBufferPointer { dst in
                    stream.next_out = dst.baseAddress
                    stream.avail_out = uInt(dst.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return dst.count - Int(stream.avail_out)
                }
                if produced > 0 {
                    output.append(buffer, count: produced)
                    if output.count > limit {
                        throw CodecError.gzipExpandLimit
                    }
                }
                if status == Z_STREAM_END { break }
                if status != Z_OK { throw CodecError.gzipFailed }
            }
        }
        return output
    }
}
