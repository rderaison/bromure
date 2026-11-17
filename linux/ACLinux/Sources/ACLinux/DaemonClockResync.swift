import Foundation
#if canImport(Glibc)
import Glibc
#endif

extension Daemon {
    /// Tell the guest its clock is behind: write the host's time to its
    /// meta share's `.resume-signal`. agentd (resume_watcher_service) reads
    /// it every 2 s and sets the clock to it when it is ahead of the guest's;
    /// on a strict workspace, the root bromure-clockd does. The guest runs no
    /// time daemon, so without this its clock stays behind after a pause.
    /// Best-effort: no meta share, no resync.
    // @port UbuntuSandboxVM.signalClockResync() h=c9e974ca0e4fa904 @d7bd69f5
    func signalClockResync(_ id: String) {
        let meta = vmDir(id) + "/meta"
        guard FileManager.default.fileExists(atPath: meta) else { return }
        try? "\(Int(Date().timeIntervalSince1970))".write(toFile: meta + "/.resume-signal", atomically: true, encoding: .utf8)
    }

    /// The host woke from sleep: every running VM's clock stood still while
    /// it slept, so each is told, as a resume does. Returns how many were.
    // @port UbuntuSandboxVM.static resyncClocksAfterHostWake() h=6a15fe7ffadb747f @d7bd69f5
    @discardableResult
    func resyncClocksAfterHostWake() -> Int {
        let running = registry.records.filter { $0.state == .running && live[$0.id] != nil }
        for rec in running { signalClockResync(rec.id) }
        return running.count
    }

    /// How long the host has slept since boot: CLOCK_BOOTTIME counts a
    /// suspend, CLOCK_MONOTONIC doesn't.
    // @port-skip linux-only: suspend detection (macOS: NSWorkspace.didWakeNotification)
    static func sleptSinceBoot() -> TimeInterval {
        var boot = timespec(), mono = timespec()
        // Monotonic first: read second, it would be the later and could
        // come out ahead of boottime by the gap between the reads.
        clock_gettime(CLOCK_MONOTONIC, &mono)
        clock_gettime(CLOCK_BOOTTIME, &boot)
        return Double(boot.tv_sec - mono.tv_sec) + Double(boot.tv_nsec - mono.tv_nsec) / 1e9
    }

    /// Watches for the host waking from sleep (macOS: applicationDidFinish-
    /// Launching's didWakeNotification observer): every 5 s, a jump of over
    /// 2 s in the time slept means a suspend just ended.
    // @port-skip linux-only: the didWakeNotification observer, polled
    func startHostWakeWatch() {
        guard !isTestRun() else { return }
        Task { [weak self] in
            var slept = Self.sleptSinceBoot()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                let now = Self.sleptSinceBoot()
                defer { slept = now }
                guard now - slept > 2, let self else { continue }
                let n = await self.resyncClocksAfterHostWake()
                if n > 0 {
                    FileHandle.standardError.write(Data(
                        "bromure-ac daemon: host woke: resyncing the clock of \(n) VM(s)\n".utf8))
                }
            }
        }
    }
}
