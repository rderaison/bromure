import Foundation

/// Reads a /proc file with plain open/read until EOF. Not Foundation's file
/// reading: a /proc file reports a size of 0, and another process's goes
/// away (or changes) while it is read -- under load, a daemon reading
/// /proc/<pid>/cmdline that way at its start (reapOrphansOfGoneDaemons)
/// crashed on a bad pointer dereference.
enum ProcFS {
    /// The file's bytes (at most `limit`), nil when it can't be opened or read.
    // @port-skip linux-only: /proc reads
    static func read(_ path: String, limit: Int = 1 << 20) -> Data? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while out.count < limit {
            let n = buf.withUnsafeMutableBytes { Foundation.read(fd, $0.baseAddress, min($0.count, limit - out.count)) }
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    /// The file as UTF-8 text.
    // @port-skip linux-only: /proc reads
    static func text(_ path: String, limit: Int = 1 << 20) -> String? {
        read(path, limit: limit).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A process's argv (/proc/<pid>/cmdline, NUL-separated); nil once it's gone.
    // @port-skip linux-only: /proc reads
    static func argv(_ pid: Int32) -> [String]? {
        read("/proc/\(pid)/cmdline", limit: 256 << 10).map { $0.split(separator: 0).map { String(decoding: $0, as: UTF8.self) } }
    }
}
