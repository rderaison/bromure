import Foundation

/// Whether a guest still proves it can run a process. agentd spawns one about
/// once a minute and rewrites `liveness.txt` only if that worked, so a kernel
/// that has wedged and a guest too short of memory to fork look the same from
/// here: the file stops changing. (`vmstat.txt` can't say this: agentd's own
/// loop can keep reading /proc on a guest that can't start anything, and the
/// host re-reads the last copy after the guest has stopped altogether.)
///
/// Only ever a report. A guest out of memory can come back when the OOM killer
/// has done its work, so what to do about one stays the user's call.
struct GuestLiveness {
    /// Two missed beats and a bit, so one slow spawn or a late poll is no alarm.
    static let patience: TimeInterval = 150

    private var lastBeat: String?
    private var lastBeatAt: TimeInterval?

    /// Whether the guest has gone silent, given the file's contents now. A
    /// guest that has never beaten (an older agentd, one still booting) is never
    /// silent, and a VM not running (paused, suspending) isn't expected to beat.
    /// `now` must not advance while the Mac sleeps: `ProcessInfo.systemUptime`.
    mutating func observe(_ beat: String?, running: Bool, now: TimeInterval) -> Bool {
        if let beat, !beat.isEmpty, beat != lastBeat {
            lastBeat = beat
            lastBeatAt = now
        }
        guard let at = lastBeatAt else { return false }
        guard running else {
            lastBeatAt = now
            return false
        }
        return now - at >= Self.patience
    }
}
