import CACLinuxShims
import Foundation
import NIOConcurrencyHelpers

/// systemd's file descriptor store (FileDescriptorStoreMax= in the unit):
/// descriptors the daemon hands to the service manager with `FDSTORE=1`
/// survive the daemon's own death, and the restarted daemon gets them back as
/// `LISTEN_FDS` (from 3) named by `LISTEN_FDNAMES`. Kept across a crash
/// restart; released when the unit stops for good. Outside such a unit
/// (`$FDSTORE` unset) every call here is a no-op.
// @port-skip linux-only: systemd fd store (macOS's app process owns its VMs' networking)
public enum FDStore {
    /// Whether the service manager gave us a store.
    // @port-skip linux-only: systemd fd store
    public static var available: Bool {
        let env = ProcessInfo.processInfo.environment
        return (env["NOTIFY_SOCKET"].map { !$0.isEmpty } ?? false) && (Int(env["FDSTORE"] ?? "") ?? 0) > 0
    }

    private static let received = NIOLockedValueBox<[String: [Int32]]?>(nil)

    /// The descriptors passed to this process, by name, taken once: the
    /// LISTEN_* variables are cleared (children must not see them) and the
    /// descriptors made close-on-exec. Unnamed ones are "unknown".
    // @port-skip linux-only: systemd fd store
    public static func take() -> [String: [Int32]] {
        received.withLockedValue { r in
            if let r { return r }
            let env = ProcessInfo.processInfo.environment
            var out: [String: [Int32]] = [:]
            if let pid = env["LISTEN_PID"].flatMap({ Int32($0) }), pid == getpid(),
               let n = env["LISTEN_FDS"].flatMap({ Int32($0) }), n > 0 {
                let names = (env["LISTEN_FDNAMES"] ?? "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                for i in 0..<n {
                    let fd = 3 + i
                    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                    out[Int(i) < names.count && !names[Int(i)].isEmpty ? names[Int(i)] : "unknown", default: []].append(fd)
                }
            }
            for v in ["LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES"] { unsetenv(v) }
            r = out
            return out
        }
    }

    /// Stores `fds` under `name`, replacing what was stored under it.
    // @port-skip linux-only: systemd fd store
    @discardableResult
    public static func store(_ name: String, _ fds: [Int32]) -> Bool {
        guard available else { return false }
        remove(name)
        return fds.withUnsafeBufferPointer { acl_sd_notify_fds("FDSTORE=1\nFDNAME=\(name)", $0.baseAddress, Int32($0.count)) } > 0
    }

    // @port-skip linux-only: systemd fd store
    public static func remove(_ name: String) {
        guard available else { return }
        _ = acl_sd_notify("FDSTOREREMOVE=1\nFDNAME=\(name)")
    }

    /// The pid a pidfd refers to (`Pid:` in its fdinfo); nil once it exited.
    // @port-skip linux-only: systemd fd store
    public static func pid(ofPidfd fd: Int32) -> Int32? {
        guard let info = try? String(contentsOfFile: "/proc/self/fdinfo/\(fd)", encoding: .utf8),
              let line = info.split(separator: "\n").first(where: { $0.hasPrefix("Pid:") }),
              let pid = Int32(line.dropFirst(4).trimmingCharacters(in: .whitespaces)), pid > 0 else { return nil }
        return pid
    }
}
