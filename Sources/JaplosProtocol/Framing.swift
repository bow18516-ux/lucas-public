import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum FrameCodec {
    /// Mirrors the original transport limit.
    public static let maximumFrameSize = 16 * 1024 * 1024

    public enum FrameError: Error, CustomStringConvertible {
        case closedBeforeCompleteFrame
        case frameTooLarge(Int)
        case writeFailed(Int32)
        case readFailed(Int32)
        case timedOut

        public var description: String {
            switch self {
            case .closedBeforeCompleteFrame: return "Connection closed before a complete frame arrived"
            case .frameTooLarge(let size): return "Frame exceeds maximum size (\(size) bytes)"
            case .writeFailed(let code): return "Write failed with errno \(code)"
            case .readFailed(let code): return "Read failed with errno \(code)"
            case .timedOut: return "Timed out while waiting for a frame"
            }
        }
    }

    public static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(payload)
        return data
    }

    public static func decodeFrameCount(from header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        return Int(header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
    }

    /// Reads exactly one length-prefixed frame from a blocking socket.
    public static func readFrame(from fd: Int32, timeout: TimeInterval? = nil) throws -> Data {
        let header = try readExactly(fd: fd, count: 4, timeout: timeout)
        guard let size = decodeFrameCount(from: header) else {
            throw FrameError.closedBeforeCompleteFrame
        }
        guard size <= maximumFrameSize else {
            throw FrameError.frameTooLarge(size)
        }
        if size == 0 { return Data() }
        return try readExactly(fd: fd, count: size, timeout: timeout)
    }

    public static func writeFrame(_ payload: Data, to fd: Int32, timeout: TimeInterval? = nil) throws {
        let framed = encode(payload)
        try framed.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                if let timeout { try wait(fd: fd, events: Int16(POLLOUT), timeout: timeout) }
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written == 0 {
                    throw FrameError.closedBeforeCompleteFrame
                } else if errno == EINTR {
                    continue
                } else {
                    throw FrameError.writeFailed(errno)
                }
            }
        }
    }

    public static func readExactly(fd: Int32, count: Int, timeout: TimeInterval?) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            if let timeout { try wait(fd: fd, events: Int16(POLLIN), timeout: timeout) }
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
            }
            if n > 0 {
                offset += n
            } else if n == 0 {
                throw FrameError.closedBeforeCompleteFrame
            } else if errno == EINTR {
                continue
            } else {
                throw FrameError.readFailed(errno)
            }
        }
        return Data(buffer)
    }

    private static func wait(fd: Int32, events: Int16, timeout: TimeInterval) throws {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let milliseconds = Int32(max(0, min(Double(Int32.max), timeout * 1000)))
        let result = poll(&descriptor, 1, milliseconds)
        if result == 0 { throw FrameError.timedOut }
        if result < 0 && errno != EINTR { throw FrameError.readFailed(errno) }
    }
}

public enum ProtocolCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ISO8601.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date")
            }
            return date
        }
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }
}

public enum ISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func string(from date: Date) -> String {
        fractional.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}
