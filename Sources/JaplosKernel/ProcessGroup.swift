import Foundation
import Darwin

/// Runs a child process in its own process group, and reaps it on a dedicated
/// thread so no cooperative thread ever blocks on `waitpid`.
enum ProcessGroup {
    struct Child {
        let pid: pid_t
        let stdout: FileHandle
        let stderr: FileHandle
    }

    enum SpawnFailure: Error, CustomStringConvertible {
        case posix(Int32, String)

        var description: String {
            switch self {
            case let .posix(code, operation):
                return "\(operation) failed (errno \(code): \(String(cString: strerror(code))))"
            }
        }
    }

    /// `POSIX_SPAWN_SETPGROUP` with pgroup 0 makes the child the leader of a new
    /// group whose id is its pid, so a timeout can signal the whole tree with
    /// `kill(-pid, …)` — including children the shell put in the background.
    static func spawn(executable: String, arguments: [String], workingDirectory: URL?) throws -> Child {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw SpawnFailure.posix(errno, "pipe(stdout)") }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw SpawnFailure.posix(errno, "pipe(stderr)")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, outPipe[0])
        posix_spawn_file_actions_addclose(&actions, errPipe[0])
        posix_spawn_file_actions_addclose(&actions, outPipe[1])
        posix_spawn_file_actions_addclose(&actions, errPipe[1])
        if let cwd = workingDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, cwd.path)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable)]
        for argument in arguments { argv.append(strdup(argument)) }
        argv.append(nil)
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        close(outPipe[1])
        close(errPipe[1])
        guard result == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw SpawnFailure.posix(result, "posix_spawn(\(executable))")
        }

        return Child(
            pid: pid,
            stdout: FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true),
            stderr: FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true)
        )
    }

    /// Reaps one pid on its own thread and exposes a non-blocking poll.
    final class ExitWatcher {
        private let lock = NSLock()
        private var rawStatus: Int32?

        init(pid: pid_t) {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                var raw: Int32 = 0
                while true {
                    let result = waitpid(pid, &raw, 0)
                    if result == -1 && errno == EINTR { continue }
                    break
                }
                lock.lock()
                rawStatus = raw
                lock.unlock()
            }
        }

        /// Exit status, or nil while the child is still running.
        func poll() -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            guard let raw = rawStatus else { return nil }
            return Self.decode(raw)
        }

        /// Darwin wait status: low 7 bits are the signal, the next byte the
        /// exit code. Signal deaths use the shell convention 128 + signal.
        static func decode(_ status: Int32) -> Int32 {
            let signal = status & 0x7f
            if signal == 0 { return (status >> 8) & 0xff }
            return 128 + signal
        }
    }

    /// SIGTERM the group, give it a moment, then SIGKILL. Returns the exit
    /// status when the leader is reaped. The grace period watches the whole
    /// group, not just the leader: a child that survives its shell must not be
    /// left behind because the shell died first.
    static func terminate(_ pid: pid_t, watcher: ExitWatcher) async -> Int32? {
        kill(-pid, SIGTERM)
        let grace = Date().addingTimeInterval(1)
        while Date() < grace {
            if groupIsGone(pid) { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        if !groupIsGone(pid) {
            kill(-pid, SIGKILL)
        }
        let hard = Date().addingTimeInterval(2)
        while Date() < hard {
            if let status = watcher.poll() { return status }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return watcher.poll()
    }

    /// A process group still exists while any member is alive, even after its
    /// leader has been reaped.
    static func groupIsGone(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return true }
        if kill(-pid, 0) == 0 { return false }
        return errno == ESRCH
    }
}
