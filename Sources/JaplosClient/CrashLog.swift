import Darwin
import Foundation

/// Records fatal signals without doing anything a signal handler may not do.
///
/// The file is opened once at install time; the handler only calls `write(2)`
/// with a preallocated buffer and a stack-formatted number. No `String`, no
/// allocation, no locks — anything else can deadlock inside a crashed process.
public enum CrashLog {
    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Lucas/crash.log")
    }

    /// Descriptor of the crash log, or -1 when it could not be opened.
    public private(set) static var descriptor: Int32 = -1

    private static let capacity = 96
    private static let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
    private static var prefixLength = 0
    private static let prefix = Array("signal ".utf8)

    /// Opens the log and installs the handlers. Safe to call twice.
    public static func install(url: URL = defaultURL()) {
        _ = buffer  // force the lazy global to exist before a handler runs
        guard descriptor < 0 else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        let length = min(prefix.count, capacity)
        for index in 0..<length {
            buffer[index] = CChar(bitPattern: prefix[index])
        }
        prefixLength = length

        for signalNumber in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(signalNumber, handle)
        }
    }

    /// The body of the handler, split out so it can be exercised directly.
    public static func record(_ signalNumber: Int32) {
        let fd = descriptor
        guard fd >= 0 else { return }
        if prefixLength > 0 {
            _ = write(fd, buffer, prefixLength)
        }
        var digits = (
            CChar(0), CChar(0), CChar(0), CChar(0), CChar(0),
            CChar(0), CChar(0), CChar(0), CChar(0), CChar(0)
        )
        withUnsafeMutableBytes(of: &digits) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var value = signalNumber
            var index = bytes.count
            repeat {
                index -= 1
                bytes[index] = UInt8(ascii: "0") + UInt8(value % 10)
                value /= 10
            } while value > 0
            guard let base = bytes.baseAddress else { return }
            _ = write(fd, base.advanced(by: index), bytes.count - index)
        }
        var newline: UInt8 = 10
        _ = write(fd, &newline, 1)
    }

    private static let handle: @convention(c) (Int32) -> Void = { signalNumber in
        record(signalNumber)
        signal(signalNumber, SIG_DFL)
        raise(signalNumber)
    }
}
