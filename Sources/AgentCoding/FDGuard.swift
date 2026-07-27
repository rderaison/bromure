import Darwin
import Foundation
import os

#if os(macOS)
/// Kernel guarded-fd syscall (libsystem_kernel; the mechanism SQLite and
/// libdispatch use to police their own fds). Adds/removes a guard on an
/// existing fd; with GUARD_CLOSE set, any close(2) that doesn't present the
/// guard value terminates the process with EXC_GUARD at the offending call.
@_silgen_name("change_fdguard_np")
private func change_fdguard_np(
    _ fd: Int32,
    _ oldGuard: UnsafePointer<UInt64>?, _ oldFlags: UInt32,
    _ newGuard: UnsafePointer<UInt64>?, _ newFlags: UInt32,
    _ fdFlags: UnsafeMutablePointer<Int32>?) -> Int32

private let GUARD_CLOSE: UInt32 = 1 << 0
private let GUARD_DUP: UInt32 = 1 << 1
/// GUARD_DUP rides along because the kernel demands it (XNU's GUARD_REQUIRED
/// — a bare GUARD_CLOSE is EINVAL); it also means a dup() of a tracked fd
/// traps, which is fine: nothing dups these fds legitimately, and a dup would
/// create a second close path — exactly what this audit hunts.
private let GUARD_FLAGS: UInt32 = GUARD_CLOSE | GUARD_DUP
#endif

/// Debug-only fd-ownership auditor for hunting premature / double closes.
/// Every call is a strict pass-through (`close` == `Darwin.close`, the rest
/// no-ops) unless armed by env, so release behavior is unchanged:
///
///   BROMURE_FD_AUDIT=1 — userspace registry only: each tracked fd carries an
///     owner label; wrong-owner closes, double closes (EBADF) and adopts of
///     dead fds log a backtrace. Never crashes. Works on both platforms.
///
///   BROMURE_FD_GUARD=1 — registry PLUS kernel guard (macOS): any close of a
///     tracked fd that bypasses `FDGuard.close` — including code this audit
///     never touched — dies immediately with EXC_GUARD, and the faulting
///     thread's stack in the crash report is the culprit. This is the only
///     net that catches a wrong close which *succeeds* because the fd number
///     was already recycled; no EBADF check can see those.
///
/// Breadcrumbs: log stream --predicate 'subsystem == "io.bromure.fdguard"'
enum FDGuard {
    private static let kernelGuard: Bool = {
        #if os(macOS)
        return ProcessInfo.processInfo.environment["BROMURE_FD_GUARD"] == "1"
        #else
        return false
        #endif
    }()
    private static let auditing = kernelGuard
        || ProcessInfo.processInfo.environment["BROMURE_FD_AUDIT"] == "1"

    /// Arbitrary nonzero stamp; one process-wide value is enough — this hunts
    /// our own wrong closes, it doesn't defend subsystems from each other.
    private static let stamp: UInt64 = 0xB120_ACFD_600D_CAFE

    private static let logger = Logger(subsystem: "io.bromure.fdguard", category: "audit")
    private static let lock = NSLock()
    private static var owners: [Int32: String] = [:]

    /// Register `owner` as the sole legitimate closer of `fd` (and arm the
    /// kernel guard when enabled). Call at the point ownership is decided.
    static func adopt(_ fd: Int32, _ owner: String) {
        guard auditing, fd >= 0 else { return }
        lock.lock()
        let prev = owners.updateValue(owner, forKey: fd)
        lock.unlock()
        if let prev {
            report("adopt(\(fd), \(owner)): still tracked as '\(prev)' — that owner's close never came through FDGuard, or the number was closed untracked and recycled")
        }
        #if os(macOS)
        if kernelGuard {
            var g = stamp
            if change_fdguard_np(fd, nil, 0, &g, GUARD_FLAGS, nil) != 0 {
                report("adopt(\(fd), \(owner)): guard arm failed errno=\(errno) — dead or already-guarded fd?")
            }
        }
        #endif
        trace("adopt fd=\(fd) owner=\(owner)")
    }

    /// Ownership leaves the audited domain (e.g. the fd is handed to
    /// FatForward.splice, which closes it internally): drop the guard and the
    /// registry entry without closing.
    static func disown(_ fd: Int32, _ owner: String) {
        guard auditing, fd >= 0 else { return }
        unregister(fd, owner, verb: "disown")
        trace("disown fd=\(fd) owner=\(owner)")
    }

    /// The one legitimate close for adopted fds.
    @discardableResult
    static func close(_ fd: Int32, _ owner: String) -> Int32 {
        guard auditing else { return Darwin.close(fd) }
        guard fd >= 0 else { return -1 }
        unregister(fd, owner, verb: "close")
        let rc = Darwin.close(fd)
        if rc != 0 {
            report("close(\(fd), \(owner)): errno=\(errno)"
                + (errno == EBADF ? " EBADF — DOUBLE CLOSE (someone closed this fd first)" : ""))
        } else {
            trace("close fd=\(fd) owner=\(owner)")
        }
        return rc
    }

    private static func unregister(_ fd: Int32, _ owner: String, verb: String) {
        lock.lock()
        let prev = owners.removeValue(forKey: fd)
        lock.unlock()
        if prev == nil {
            report("\(verb)(\(fd), \(owner)): fd was never adopted — untracked close beat us to this number, or double \(verb)")
        } else if prev != owner {
            report("\(verb)(\(fd), \(owner)): registry says owner is '\(prev!)' — wrong-owner \(verb)")
        }
        #if os(macOS)
        if kernelGuard {
            var g = stamp
            if change_fdguard_np(fd, &g, GUARD_FLAGS, nil, 0, nil) != 0 {
                report("\(verb)(\(fd), \(owner)): guard drop failed errno=\(errno)")
            }
        }
        #endif
    }

    /// Breadcrumbs go to stderr as well as os_log — unified-log ingestion has
    /// proven unreliable for this app, and the stderr file is what gets read
    /// next to a crash report anyway.
    private static func trace(_ msg: String) {
        logger.notice("\(msg, privacy: .public)")
        FileHandle.standardError.write(Data("[fdguard] \(msg)\n".utf8))
    }

    private static func report(_ msg: String) {
        let stack = Thread.callStackSymbols.dropFirst(2).joined(separator: "\n")
        logger.fault("ANOMALY \(msg, privacy: .public)\n\(stack, privacy: .public)")
        FileHandle.standardError.write(Data("[fdguard] ANOMALY \(msg)\n\(stack)\n".utf8))
    }
}
