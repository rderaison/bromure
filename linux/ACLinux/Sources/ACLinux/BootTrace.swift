import Foundation
import NIOConcurrencyHelpers

/// A workspace start's phases with their times, to see where a boot goes:
/// `[boot] <vm> +<ms> <phase>` on stderr (the journal), each since that VM's
/// start began. Off unless BROMURE_BOOT_TRACE is set.
// @port-skip linux-only: the Linux daemon's boot timing (macOS has none)
public enum BootTrace {
    static let enabled = ProcessInfo.processInfo.environment["BROMURE_BOOT_TRACE"] != nil
    private static let starts = NIOLockedValueBox<[String: ContinuousClock.Instant]>([:])

    /// A start begins for `vm` (its short id or name).
    // @port-skip linux-only: see BootTrace
    public static func begin(_ vm: String) {
        guard enabled else { return }
        starts.withLockedValue { $0[vm] = .now }
        mark(vm, "start")
    }

    // @port-skip linux-only: see BootTrace
    public static func mark(_ vm: String, _ phase: String) {
        guard enabled else { return }
        let ms = starts.withLockedValue { $0[vm] }.map { t in
            let d = ContinuousClock.now - t
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        } ?? 0
        FileHandle.standardError.write(Data(String(format: "[boot] %@ +%.0f ms %@\n", vm, ms, phase).utf8))
    }
}
