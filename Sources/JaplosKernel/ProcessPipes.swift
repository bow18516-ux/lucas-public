import Foundation

/// Reads process pipes while the process is still running so a full pipe
/// cannot deadlock `waitUntilExit`.
enum ProcessPipes {
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

    /// Start readers, wait for exit, then return the capped output.
    static func drain(
        process: Process,
        stdout: FileHandle?,
        stderr: FileHandle?,
        limit: Int
    ) -> (stdout: Data, stderr: Data, truncated: Bool) {
        let bucket = Bucket(limit: limit)
        let group = DispatchGroup()
        func read(_ handle: FileHandle?, isStdout: Bool) {
            guard let handle else { return }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                while true {
                    let chunk = handle.readData(ofLength: 16 * 1024)
                    if chunk.isEmpty { break }
                    bucket.append(chunk, stdout: isStdout)
                }
            }
        }
        read(stdout, isStdout: true)
        read(stderr, isStdout: false)
        process.waitUntilExit()
        group.wait()
        return bucket.snapshot()
    }
}
