import Foundation

/// A guest that reboots itself (`reboot`, systemd's reboot.target) first
/// writes `outbox/reboot-intent`; Firecracker then exits instead of
/// restarting the guest. As macOS does (onGuestReboot, then
/// relaunchAfterGuestReboot), the stop that follows is taken for a reboot:
/// the workspace boots again, cold, rather than being left off. A stop the
/// daemon asked for (a client's shutdown, kill or suspend) still wins.
extension Daemon {
    /// Reads every running VM's reboot intent (the guest's marker, consumed).
    // @port-skip linux-only: the reboot-intent half of UbuntuSandboxVM.startOutboxPolling, on the host
    func readGuestRebootIntents() {
        for id in live.keys {
            let marker = vmDir(id) + "/outbox/reboot-intent"
            guard FileManager.default.fileExists(atPath: marker) else { continue }
            try? FileManager.default.removeItem(atPath: marker)
            noteGuestRebootIntent(id)
        }
    }

    /// The guest's going down for a reboot: its stop relaunches it. A saved
    /// state is stale across it, and the shell connections belong to the
    /// boot that is going away (macOS: onGuestReboot).
    // @port-skip linux-only: the daemon side of UbuntuSandboxVM.onGuestReboot (macOS: VZ restarts the guest in place)
    func noteGuestRebootIntent(_ id: String) {
        guard let l = live[id], guestRebootIntents.insert(id).inserted else { return }
        try? FileManager.default.removeItem(atPath: snapshotDir(id))
        let shell = l.shell
        Task { await shell.flushPool() }
        let name = registry.find(id).flatMap { existingProfile(for: $0)?.name } ?? id
        FileHandle.standardError.write(Data("bromure-ac daemon: guest reboot detected for '\(name)' — it boots again when it stops\n".utf8))
    }

    /// The VM stopped after its guest rebooted: boot it again, cold, kept
    /// as a reboot (a `--rm` workspace survives it) until the boot is done.
    // @port ACAppDelegate.relaunchAfterGuestReboot(_: Profile.ID) h=a54abd48d1aae658 @4bd8405e
    func relaunchAfterGuestReboot(_ id: String) async {
        defer { rebooting.remove(id) }
        for _ in 0..<200 where live[id] != nil || stopping[id] != nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? FileManager.default.removeItem(atPath: snapshotDir(id))
        guard var now = registry.find(id), live[id] == nil else { return }
        if now.state == .suspended { now.state = .stopped; try? registry.upsert(now) }
        let started = await start(now)
        guard started.status >= 300 else { return }
        FileHandle.standardError.write(Data("bromure-ac daemon: '\(now.name)' didn't boot again after its guest rebooted: \(started.body["error"]?.stringValue ?? "HTTP \(started.status)")\n".utf8))
        rebooting.remove(id)
        if let pid = UUID(uuidString: id) { await dropAbandonedEphemeral(pid) }
    }

    /// Whether the guest kernel's last reboot line on the serial console (its
    /// tail, this boot's end) is "Restarting system" rather than "Power down".
    // @port-skip linux-only: Firecracker exits on a guest reset (VZ restarts the guest in place)
    static func kernelSaidRestart(serialLog: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: serialLog) else { return false }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 8192 ? size - 8192 : 0)
        let tail = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        guard let last = tail.range(of: "reboot: ", options: .backwards) else { return false }
        return tail[last.upperBound...].hasPrefix("Restarting system")
    }

    /// A guest that powered itself off: Firecracker (x86, no ACPI power-off)
    /// keeps the halted guest's VM up, where macOS's VM stops and its session
    /// ends. Its kernel's last word on the serial console says so; the VM is
    /// then ended (a stop, not a reboot: it isn't booted again).
    // @port-skip linux-only: Firecracker keeps a powered-off guest's VM up (VZ stops it)
    func endPoweredOffGuests() async {
        for (id, l) in live where !starting.contains(id) && stopping[id] == nil && !rebooting.contains(id) {
            guard let log = l.config.serialLog, Self.kernelSaidPowerDown(serialLog: log),
                  let rec = registry.find(id) else { continue }
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': its guest powered off; ending the VM\n".utf8))
            _ = await deleteVM(rec, action: "kill")
        }
    }

    /// Whether the kernel's last reboot line on the console is a power-off
    /// ("Power down", or the halt it falls back to without ACPI).
    // @port-skip linux-only: see endPoweredOffGuests
    static func kernelSaidPowerDown(serialLog: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: serialLog) else { return false }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 8192 ? size - 8192 : 0)
        let tail = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        guard let last = tail.range(of: "reboot: ", options: .backwards) else { return false }
        // "Power down", or (no ACPI power-off: Firecracker on x86) "Power off
        // not available: System halted instead".
        let rest = tail[last.upperBound...]
        return rest.hasPrefix("Power down") || rest.hasPrefix("Power off not available")
    }
}

