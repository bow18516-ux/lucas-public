import XCTest
@testable import JaplosKernel
import Foundation

/// Byte-level fixtures aligned with Xiaoling `tests/test_protocol.py`.
final class DoubaoRealtimeProtocolTests: XCTestCase {
    func testStartConnectionBytesMatchDoc() throws {
        let data = try DoubaoRealtimeProtocol.encode(
            event: DoubaoRealtimeProtocol.startConnection,
            payload: [String: Any]()
        )
        XCTAssertEqual(
            [UInt8](data),
            [17, 20, 16, 0, 0, 0, 0, 1, 0, 0, 0, 2, 123, 125]
        )
    }

    func testStartSessionBytesMatchDoc() throws {
        let sid = "75a6126e-427f-49a1-a2c1-621143cb9db3"
        let payload: [String: Any] = [
            "dialog": [
                "bot_name": "豆包",
                "dialog_id": "",
                "extra": NSNull(),
            ] as [String: Any],
        ]
        let data = try DoubaoRealtimeProtocol.encode(
            event: DoubaoRealtimeProtocol.startSession,
            payload: payload,
            sessionID: sid
        )
        let json = "{\"dialog\":{\"bot_name\":\"豆包\",\"dialog_id\":\"\",\"extra\":null}}".data(using: .utf8)!
        // JSONSerialization key order may differ — compare structurally via decode + header fields.
        let decoded = try DoubaoRealtimeProtocol.decode(data)
        XCTAssertEqual(decoded.event, DoubaoRealtimeProtocol.startSession)
        XCTAssertEqual(decoded.sessionID, sid)
        XCTAssertEqual(decoded.msgType, DoubaoRealtimeProtocol.fullClient)

        // When key order matches Python fixture, full bytes should match.
        // Re-encode with exact JSON body by checking length of our compact JSON.
        let ourJSON = try DoubaoRealtimeProtocol.compactJSON(payload)
        // Accept either exact fixture or same semantic content.
        if ourJSON == json {
            var expected = Data([17, 20, 16, 0, 0, 0, 0, 100])
            expected.append(contentsOf: [0, 0, 0, 36])
            expected.append(sid.data(using: .utf8)!)
            var len = UInt32(json.count).bigEndian
            expected.append(Data(bytes: &len, count: 4))
            expected.append(json)
            XCTAssertEqual(data, expected)
        } else {
            let dialog = decoded.payloadJSON?["dialog"] as? [String: Any]
            XCTAssertEqual(dialog?["bot_name"] as? String, "豆包")
            XCTAssertEqual(dialog?["dialog_id"] as? String, "")
            XCTAssertTrue(dialog?["extra"] is NSNull)
        }
    }

    func testConnectEventsCarryNoSessionID() throws {
        let data = try DoubaoRealtimeProtocol.encode(
            event: DoubaoRealtimeProtocol.finishConnection,
            payload: [String: Any]()
        )
        XCTAssertEqual([UInt8](data.prefix(12)), [17, 20, 16, 0, 0, 0, 0, 2, 0, 0, 0, 2])
    }

    func testDecodeTTSResponseDocExample() throws {
        let sid = "3c791a7d-227a-4446-993b-24f9e302cc98"
        var data = Data([17, 180, 0, 0, 0, 0, 1, 96, 0, 0, 0, 36])
        data.append(sid.data(using: .utf8)!)
        var size = UInt32(4).bigEndian
        data.append(Data(bytes: &size, count: 4))
        data.append(contentsOf: "OggS".utf8)
        let frame = try DoubaoRealtimeProtocol.decode(data)
        XCTAssertEqual(frame.msgType, DoubaoRealtimeProtocol.audioServer)
        XCTAssertEqual(frame.event, 352)
        XCTAssertEqual(frame.sessionID, sid)
        XCTAssertEqual(frame.payloadBytes, Data("OggS".utf8))
    }

    func testDecodeGzipJSONServerFrame() throws {
        let json = try JSONSerialization.data(
            withJSONObject: ["results": [["text": "你好", "is_interim": false]]],
            options: []
        )
        let body = try DoubaoRealtimeProtocol.gzipCompress(json)
        var srv = Data([0x11, UInt8((DoubaoRealtimeProtocol.fullServer << 4) | DoubaoRealtimeProtocol.flagEvent), 0x11, 0])
        var event = UInt32(451).bigEndian
        srv.append(Data(bytes: &event, count: 4))
        var sidLen = UInt32(3).bigEndian
        srv.append(Data(bytes: &sidLen, count: 4))
        srv.append(contentsOf: "abc".utf8)
        var bodyLen = UInt32(body.count).bigEndian
        srv.append(Data(bytes: &bodyLen, count: 4))
        srv.append(body)
        let frame = try DoubaoRealtimeProtocol.decode(srv)
        XCTAssertEqual(frame.event, 451)
        XCTAssertEqual(frame.sessionID, "abc")
        let results = frame.payloadJSON?["results"] as? [[String: Any]]
        XCTAssertEqual(results?.first?["text"] as? String, "你好")
    }

    func testAudioFrameRoundtrip() throws {
        // Match Python: b"\x00\x01" * 320
        var pcm = Data()
        for _ in 0..<320 {
            pcm.append(contentsOf: [0x00, 0x01])
        }
        let encoded = try DoubaoRealtimeProtocol.encode(
            event: DoubaoRealtimeProtocol.taskRequest,
            payload: pcm,
            sessionID: "s2",
            audio: true
        )
        let frame = try DoubaoRealtimeProtocol.decode(encoded)
        XCTAssertEqual(frame.msgType, DoubaoRealtimeProtocol.audioClient)
        XCTAssertEqual(frame.event, DoubaoRealtimeProtocol.taskRequest)
        XCTAssertEqual(frame.sessionID, "s2")
        XCTAssertEqual(frame.payloadBytes, pcm)
    }

    func testErrorOnShortFrame() {
        XCTAssertThrowsError(try DoubaoRealtimeProtocol.decode(Data([0x11]))) { error in
            XCTAssertTrue(String(describing: error).contains("too short"), "\(error)")
        }
    }

    func testGunzipRefusesToExpandPastLimit() throws {
        // Compress 2 MiB of zeros; refuse to expand past 1 KiB.
        let bomb = try DoubaoRealtimeProtocol.gzipCompress(Data(repeating: 0, count: 2 << 20))
        XCTAssertThrowsError(try DoubaoRealtimeProtocol.gunzip(bomb, limit: 1024)) { error in
            XCTAssertTrue(String(describing: error).contains("limit") || String(describing: error).contains("gzip"), "\(error)")
        }
    }

    func testWavFromPCMHasRIFFHeader() {
        let pcm = Data(repeating: 0, count: 48)
        let wav = DoubaoRealtimeProtocol.wavFromPCM(pcm, sampleRate: 24_000)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(wav.count, 44 + pcm.count)
    }

    func testSessionPayloadDefaults() {
        let payload = DoubaoRealtimeProtocol.sessionPayload()
        let tts = payload["tts"] as? [String: Any]
        let audio = tts?["audio_config"] as? [String: Any]
        XCTAssertEqual(audio?["sample_rate"] as? Int, 24_000)
        XCTAssertEqual(audio?["format"] as? String, "pcm_s16le")
        XCTAssertEqual(tts?["speaker"] as? String, DoubaoRealtimeProtocol.defaultSpeaker)
    }
}
