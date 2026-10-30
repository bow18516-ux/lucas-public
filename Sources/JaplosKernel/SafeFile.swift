import Darwin
import Foundation

/// Writes files without following symlinks.
///
/// Trust-root resolution happens before the write, so a path that was safe when
/// it was checked could be swapped for a symlink before the bytes land. Opening
/// with `O_NOFOLLOW` closes that window: the kernel refuses the link itself.
enum SafeFile {
    private static let writeFlags = O_WRONLY | O_CREAT | O_NOFOLLOW

    static func write(_ data: Data, to url: URL, exclusive: Bool = false) throws {
        var flags = writeFlags
        flags |= exclusive ? O_EXCL : O_TRUNC
        let descriptor = open(url.path, flags, 0o644)
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP {
                throw ToolError.denied("拒绝通过符号链接写入：\(url.path)")
            }
            if code == EEXIST {
                throw ToolError.denied("拒绝覆盖已有文件：\(url.path)")
            }
            throw ToolError.failed("无法写入 \(url.path)（errno \(code)）")
        }
        defer { close(descriptor) }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ToolError.failed("写入 \(url.path) 失败（errno \(errno)）")
                }
                offset += written
            }
        }
    }
}
