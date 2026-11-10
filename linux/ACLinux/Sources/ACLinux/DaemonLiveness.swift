import Foundation

extension Daemon {
    /// Whether each running guest still proves it can run a process (macOS:
    /// UbuntuSandboxVM's outbox poll reading `liveness.txt` into
    /// GuestLiveness, and onGuestResponsive): agentd rewrites the file about
    /// once a minute only if it could spawn something, so a wedged kernel
    /// and a guest too short of memory to fork both go silent. A paused VM
    /// (or one whose state can't be read) isn't expected to beat. Only ever
    /// a report, in its /vms entry and the session host's memory report:
    /// what to do about it stays the user's call.
    // partial: report only (log, /vms, memory report). No GuestLivenessStore restart hook
    // @port ACAppDelegate.wireSandboxCallbacks(_: UbuntuSandboxVM) / sandbox.onGuestResponsive h=830168a4222110a0 @d3ebbda2
    func observeGuestLiveness(now: TimeInterval = ProcessInfo.processInfo.systemUptime) async {
        var silent: Set<String> = []
        var seen: Set<String> = []
        for rec in registry.records where rec.state == .running {
            guard let pid = UUID(uuidString: rec.id), let (id, vm) = compromiseVM(pid), id == rec.id else { continue }
            seen.insert(id)
            let beat = GuestOutbox.read(vmDir(id) + "/outbox/liveness.txt")
            let running = await vm.isPaused() == false
            var l = guestLiveness[id] ?? GuestLiveness()
            if l.observe(beat, running: running, now: now) { silent.insert(id) }
            guestLiveness[id] = l
        }
        // VMs gone since: forgotten (a new boot starts with a fresh clock).
        for id in guestLiveness.keys where !seen.contains(id) { guestLiveness[id] = nil }
        for id in silent.subtracting(guestSilent) {
            FileHandle.standardError.write(Data("bromure-ac daemon: VM \(id.prefix(8)): the guest has stopped answering (no liveness beat for \(Int(GuestLiveness.patience)) s)\n".utf8))
        }
        for id in guestSilent.subtracting(silent) where seen.contains(id) {
            FileHandle.standardError.write(Data("bromure-ac daemon: VM \(id.prefix(8)): the guest answers again\n".utf8))
        }
        guestSilent = silent
        LinuxSessionHost.unresponsive.withLockedValue { $0 = Set(silent.compactMap { UUID(uuidString: $0) }) }
    }
}
