import XCTest
@testable import JaplosClient
import JaplosProtocol

/// A Unix-socket server that reads one request and hangs up without answering.
/// It counts requests so a client-side retry is observable.
final class SilentUnixServer: @unchecked Sendable {
    private let listenFD: Int32
    private let path: String
    private let lock = NSLock()
    private var count = 0

    init(path: String) throws {
        self.path = path
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw XCTSkip("socket() failed: \(errno)") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(listenFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listenFD, 8) == 0 else {
            close(listenFD)
            throw XCTSkip("bind/listen failed: \(errno)")
        }
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            var header = [UInt8](repeating: 0, count: 4)
            if read(client, &header, 4) == 4 {
                let size = (Int(header[0]) << 24) | (Int(header[1]) << 16)
                    | (Int(header[2]) << 8) | Int(header[3])
                var body = [UInt8](repeating: 0, count: size)
                var received = 0
                while received < size {
                    let n = read(client, &body[received], size - received)
                    if n <= 0 { break }
                    received += n
                }
                lock.lock()
                count += 1
                lock.unlock()
            }
            // Hang up without a response: the client sees a transport failure.
            close(client)
        }
    }

    func stop() {
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        unlink(path)
    }
}

final class TransportRetryTests: XCTestCase {
    func testTransportFailureIsNotRetried() throws {
        let directory = URL(fileURLWithPath: "/tmp/lucas-silent-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("kernel.sock").path
        let server = try SilentUnixServer(path: socketPath)
        defer { server.stop() }

        let client = KernelClient(socketPath: socketPath)
        let started = Date()
        XCTAssertThrowsError(try client.call(.kernelPing, arguments: .object([:]), timeout: 3)) { error in
            guard case ClientError.transport = error else {
                return XCTFail("expected a transport failure, got \(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(
            server.requestCount,
            1,
            "a timeout or mid-stream disconnect must not be retried: the server saw \(server.requestCount) requests"
        )
        XCTAssertLessThan(elapsed, 3, "the client must fail fast instead of retrying")
        XCTAssertTrue(
            DaemonRestartTests.daemonPIDs(socket: socketPath).isEmpty,
            "a transport failure must not launch a daemon"
        )
    }
}
