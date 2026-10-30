import Foundation
import Network

/// Minimal TLS line-oriented client for IMAP/SMTP (Network.framework, no MailCore).
final class MailTLSClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "lucas.mail.tls")
    private var buffer = Data()
    private let lock = NSLock()

    init(host: String, port: Int, timeout: TimeInterval) throws {
        let tls = NWProtocolTLS.Options()
        let tcp = NWProtocolTCP.Options()
        let params = NWParameters(tls: tls, tcp: tcp)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw MailError.invalidArgument("invalid port \(port)")
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let sem = DispatchSemaphore(value: 0)
        var startError: Error?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                sem.signal()
            case .failed(let err):
                startError = err
                sem.signal()
            case .cancelled:
                startError = MailError.protocolFailure("connection cancelled")
                sem.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            throw MailError.protocolFailure("TLS connect timeout \(host):\(port)")
        }
        if let startError { throw startError }
    }

    func close() {
        connection.cancel()
    }

    func writeLine(_ line: String) throws {
        try write(Data((line + "\r\n").utf8), timeout: 20)
    }

    func write(_ data: Data, timeout: TimeInterval) throws {
        let sem = DispatchSemaphore(value: 0)
        var writeError: Error?
        connection.send(content: data, completion: .contentProcessed { err in
            writeError = err
            sem.signal()
        })
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            throw MailError.protocolFailure("write timeout")
        }
        if let writeError { throw writeError }
    }

    func readLine(timeout: TimeInterval = 20) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock()
            if let range = buffer.range(of: Data([0x0D, 0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                lock.unlock()
                return String(decoding: lineData, as: UTF8.self)
            }
            lock.unlock()
            if Date() > deadline {
                throw MailError.protocolFailure("read line timeout")
            }
            try receiveMore(timeout: max(0.1, deadline.timeIntervalSinceNow))
        }
    }

    func readUntil(timeout: TimeInterval = 30, predicate: (String) -> Bool) throws -> [String] {
        var lines: [String] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let line = try readLine(timeout: max(0.1, deadline.timeIntervalSinceNow))
            lines.append(line)
            if predicate(line) { return lines }
        }
        throw MailError.protocolFailure("readUntil timeout")
    }

    func readExact(count: Int, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock()
            if buffer.count >= count {
                let out = Data(buffer.prefix(count))
                buffer.removeFirst(count)
                lock.unlock()
                return out
            }
            lock.unlock()
            if Date() > deadline {
                throw MailError.protocolFailure("readExact timeout")
            }
            try receiveMore(timeout: max(0.1, deadline.timeIntervalSinceNow))
        }
    }

    private func receiveMore(timeout: TimeInterval) throws {
        let sem = DispatchSemaphore(value: 0)
        var recvError: Error?
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                self?.lock.lock()
                self?.buffer.append(data)
                self?.lock.unlock()
            }
            if let error { recvError = error }
            if isComplete && (data == nil || data?.isEmpty == true) {
                recvError = recvError ?? MailError.protocolFailure("connection closed")
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            throw MailError.protocolFailure("receive timeout")
        }
        if let recvError { throw recvError }
    }
}

enum MailError: LocalizedError {
    case notConfigured(String)
    case invalidArgument(String)
    case notFound(String)
    case protocolFailure(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let s), .invalidArgument(let s), .notFound(let s), .protocolFailure(let s):
            return s
        }
    }
}
