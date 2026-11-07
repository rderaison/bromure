import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Small platform differences behind one function each, so the code that
// needs them reads the same on Apple platforms and on Linux.

/// A raw Thread never drains its implicit autorelease pool on Apple
/// platforms: per-iteration work wraps itself in one. Elsewhere there is no
/// autorelease pool.
@inline(__always)
func threadAutoreleasepool<T>(_ body: () throws -> T) rethrows -> T {
#if canImport(ObjectiveC)
    try autoreleasepool(invoking: body)
#else
    try body()
#endif
}

/// An IPv4 TCP socket: SOCK_STREAM is an Int32 in Darwin, an enum in Glibc.
func tcpSocket() -> Int32 {
#if os(Linux)
    socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
#else
    socket(AF_INET, SOCK_STREAM, 0)
#endif
}

/// BSD's sockaddr_in starts with its length; Linux's has no such field.
func setSockaddrLength(_ addr: inout sockaddr_in) {
#if !os(Linux)
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
}

/// A copy-on-write clone of `src` at `dst` (APFS clonefile); -1 with errno
/// set when the filesystem can't, and the caller copies instead. Linux:
/// ENOTSUP, always (a FICLONE reflink could come later).
func cloneFile(_ src: String, _ dst: String) -> Int32 {
#if canImport(Darwin)
    clonefile(src, dst, 0)
#else
    errno = ENOTSUP
    return -1
#endif
}

/// A file's modification time from stat(2): `st_mtimespec` in Darwin,
/// `st_mtim` in Glibc.
func statModificationTime(_ st: stat) -> timespec {
#if canImport(Darwin)
    st.st_mtimespec
#else
    st.st_mtim
#endif
}

/// read(2), write(2), close(2) and a write-side shutdown(2), for a type whose
/// own `read`/`write`/`close` members shadow the C ones (Darwin.close in
/// Darwin, Glibc.close in Glibc).
func fdRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int) -> Int {
#if canImport(Darwin)
    Darwin.read(fd, buf, count)
#else
    Glibc.read(fd, buf, count)
#endif
}

func fdWrite(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int {
#if canImport(Darwin)
    Darwin.write(fd, buf, count)
#else
    Glibc.write(fd, buf, count)
#endif
}

@discardableResult
func fdClose(_ fd: Int32) -> Int32 {
#if canImport(Darwin)
    Darwin.close(fd)
#else
    Glibc.close(fd)
#endif
}

/// Half-close: no more writes on `fd` (SHUT_WR is an Int32 in Darwin, an Int
/// in Glibc).
@discardableResult
func fdShutdownWrite(_ fd: Int32) -> Int32 {
#if canImport(Darwin)
    shutdown(fd, SHUT_WR)
#else
    shutdown(fd, Int32(SHUT_WR))
#endif
}

/// Both directions shut: a thread blocked reading `fd` wakes (with an EOF),
/// as a bare close(2) only guarantees on Darwin.
@discardableResult
func fdShutdownBoth(_ fd: Int32) -> Int32 {
#if canImport(Darwin)
    shutdown(fd, SHUT_RDWR)
#else
    shutdown(fd, Int32(SHUT_RDWR))
#endif
}

/// State behind a lock, with OSAllocatedUnfairLock's `withLock` shape, for
/// code that also builds where Apple's `os` module isn't there.
final class LockedState<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(initialState: State) { state = initialState }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&state)
    }
}
