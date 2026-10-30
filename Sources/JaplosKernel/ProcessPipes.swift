import Foundation
import Darwin

/// Reads process pipes while the process is still running so a full pipe
/// cannot deadlock, and never blocks a cooperative thread waiting for EOF.
enum ProcessPipes {
    struct Capture {
        let stdout: Data
        let stderr: Data
        let truncated: Bool
        /// A child left running in the background still holds the pipe, so we
        /// stopped reading instead of waiting for an EOF that may never come.
        let detachedBackground: Bool
    }

    final class Bucket: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        private var outBytes = 0
        private var errBytes = 0
        let limit: Int

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ data: Data, stdout: Bool) {
            guard !data.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            if stdout {
                outBytes += data.count
                if out.count < limit {
                    out.append(data.prefix(limit - out.count))
                }
            } else {
                errBytes += data.count
                if err.count < limit {
                    err.append(data.prefix(limit - err.count))
                }
            }
        }

        func snapshot() -> (stdout: Data, stderr: Data, truncated: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (out, err, outBytes > out.count || errBytes > err.count)
        }
    }

    /// Reader threads that can be stopped: `poll` wakes every 200 ms to check
    /// the flag, so the owner can abandon a pipe a background child still
    /// holds without closing a file descriptor another thread is blocked on.
    final class ReaderSet: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var stopping = false
        private let handles: [(FileHandle, Bool)]
        private let bucket: Bucket

        init(stdout: FileHandle?, stderr: FileHandle?, bucket: Bucket) {
            var list: [(FileHandle, Bool)] = []
            if let stdout { list.append((stdout, true)) }
            if let stderr { list.append((stderr, false)) }
            handles = list
            self.bucket = bucket
        }

        func start() {
            for (handle, isStdout) in handles {
                lock.lock()
                active += 1
                lock.unlock()
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    read(handle: handle, isStdout: isStdout)
                    lock.lock()
                    active -= 1
                    lock.unlock()
                }
            }
        }

        var isDone: Bool {
            lock.lock()
            defer { lock.unlock() }
            return active == 0
        }

        func stop() {
            lock.lock()
            stopping = true
            lock.unlock()
        }

        func close() {
            for (handle, _) in handles {
                try? handle.close()
            }
        }

        private var shouldStop: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopping
        }

        private func read(handle: FileHandle, isStdout: Bool) {
            let fd = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                if shouldStop { return }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 200)
                if ready == 0 { continue }
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                let count = buffer.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.read(fd, base, raw.count)
                }
                if count <= 0 { return }
                bucket.append(Data(buffer[0..<count]), stdout: isStdout)
            }
        }
    }

    /// Wait for EOF with a grace period, then abandon a pipe a background
    /// child still holds. Never blocks the cooperative thread pool.
    static func finish(readers: ReaderSet, bucket: Bucket) async -> Capture {
        var detached = false
        let grace = Date().addingTimeInterval(1)
        while !readers.isDone && Date() < grace {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if !readers.isDone {
            detached = true
            readers.stop()
            let hard = Date().addingTimeInterval(0.3)
            while !readers.isDone && Date() < hard {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            readers.close()
        }
        let snapshot = bucket.snapshot()
        return Capture(
            stdout: snapshot.stdout,
            stderr: snapshot.stderr,
            truncated: snapshot.truncated,
            detachedBackground: detached
        )
    }

    static func capture(readers: ReaderSet, bucket: Bucket) -> Capture {
        var detached = false
        let grace = Date().addingTimeInterval(1)
        while !readers.isDone && Date() < grace {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if !readers.isDone {
            detached = true
            readers.stop()
            let hard = Date().addingTimeInterval(0.3)
            while !readers.isDone && Date() < hard {
                Thread.sleep(forTimeInterval: 0.01)
            }
            readers.close()
        }
        let snapshot = bucket.snapshot()
        return Capture(
            stdout: snapshot.stdout,
            stderr: snapshot.stderr,
            truncated: snapshot.truncated,
            detachedBackground: detached
        )
    }

    /// Await a `Process` exit without blocking, then collect capped output.
    static func drain(
        process: Process,
        stdout: FileHandle?,
        stderr: FileHandle?,
        limit: Int
    ) async -> Capture {
        let bucket = Bucket(limit: limit)
        let readers = ReaderSet(stdout: stdout, stderr: stderr, bucket: bucket)
        readers.start()
        await waitForExit(process)
        return await finish(readers: readers, bucket: bucket)
    }

    /// Blocking variant for synchronous call sites (the Team ID probe). The
    /// reader wait is still bounded, so a leaked child cannot wedge it.
    static func drainBlocking(
        process: Process,
        stdout: FileHandle?,
        stderr: FileHandle?,
        limit: Int
    ) -> Capture {
        let bucket = Bucket(limit: limit)
        let readers = ReaderSet(stdout: stdout, stderr: stderr, bucket: bucket)
        readers.start()
        process.waitUntilExit()
        return capture(readers: readers, bucket: bucket)
    }

    private static func waitForExit(_ process: Process) async {
        guard process.isRunning else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            process.terminationHandler = { _ in once.resume() }
            if !process.isRunning { once.resume() }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resume() {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }
}
