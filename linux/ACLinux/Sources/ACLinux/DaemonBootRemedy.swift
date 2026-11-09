import Foundation

/// A workspace whose boot dies on filesystem errors (systemd's fsck can't
/// fix the system disk and drops to an emergency shell nobody answers), as
/// macOS handles it (UbuntuSandboxVM.onBootFilesystemFailure, then
/// handleBootFilesystemFailure): the boot's serial console is scanned until
/// the guest's roster arrives; on a failure, every client is asked through
/// the prompt broker -- Repair (the native fsck on the host, then boot
/// again) first, Reset (the system disk re-cloned from the base image; the
/// home survives) once a repair was already tried -- and the chosen remedy
/// runs with the VM stopped, then it boots again.
extension Daemon {
    enum BootRemedy: Sendable { case repairDisk, resetDisk }

    /// Watches this boot's console (`console`: the serial log, from where
    /// this boot's lines start) until the roster arrives or the VM is gone.
    // partial: the console scanner of UbuntuSandboxVM for a workspace, over its serial log, wired to handleBootFilesystemFailure
    // @port ACAppDelegate.wireSandboxCallbacks(_: UbuntuSandboxVM) / sandbox.onBootFilesystemFailure h=de8e6317529f360e @4237c02e
    func startBootConsoleScan(_ id: String, console: (path: String, offset: UInt64)) {
        let bootedAt = Date()
        bootStartedAt[id] = bootedAt
        let tabs = vmDir(id) + "/outbox/tabs.txt"
        Task.detached { [weak self] in
            guard let self else { return }
            let match = await BootConsoleScan.scan(path: console.path, from: console.offset) {
                guard await self.isLive(id) else { return false }
                // The guest's roster this boot: it booted.
                if let m = (try? FileManager.default.attributesOfItem(atPath: tabs))?[.modificationDate] as? Date,
                   m > bootedAt { return false }
                return true
            }
            guard let match else { return }
            await self.handleBootFilesystemFailure(id, detail: match)
        }
    }

    // @port-skip linux-only: the daemon's live table
    func isLive(_ id: String) -> Bool { live[id] != nil }

    /// The failure seen: said, kept for the workspace list (bootFailure),
    /// and the remedy offered to every client until one is chosen, the VM
    /// goes, or a client says "Not Now".
    // @port ACAppDelegate.handleBootFilesystemFailure(profileID: Profile.ID, detail: String) h=1e68a7f27915b150 @4237c02e
    func handleBootFilesystemFailure(_ id: String, detail: String) {
        guard live[id] != nil, activeBootFailures[id] == nil, let rec = registry.find(id),
              let pid = UUID(uuidString: id) else { return }
        let name = existingProfile(for: rec)?.name ?? rec.name
        activeBootFailures[id] = detail
        FileHandle.standardError.write(Data("bromure-ac daemon: boot filesystem failure on '\(name)': \(detail)\n".utf8))
        Task { [weak self] in
            while true {
                guard let self, await self.bootFailureStillOpen(id) else { return }
                guard PendingPromptBroker.hasLiveListener() else {
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }
                let escalate = await self.bootRepairWasTried(id)
                let title = "“\(name)” can't boot — disk error"
                let message = escalate
                    ? "The filesystem is still failing after a repair.\n\n\(detail)\n\n"
                      + "Reset re-clones the OS from the base image. Anything installed "
                      + "with apt and changes under /etc are lost; the home folder "
                      + "(projects, dotfiles, keys) survives."
                    : "The system disk failed its boot-time filesystem check and the "
                      + "boot cannot continue.\n\n\(detail)\n\n"
                      + "Repair replays the disk's journal on the server and boots again. "
                      + "Nothing is deleted."
                let buttons = escalate ? ["Reset System Disk", "Not Now"] : ["Repair Disk", "Not Now"]
                // -1: no answer (timeout, client gone): keep offering.
                let choice = await PendingPromptBroker.shared.askAsync(
                    profileID: pid, title: title, message: message, buttons: buttons, fallback: -1, timeout: 600)
                guard await self.bootFailureStillOpen(id) else { return }
                switch choice {
                case 0: await self.performBootRemedy(id, escalate ? .resetDisk : .repairDisk); return
                case 1: return
                default: continue
                }
            }
        }
    }

    // @port-skip linux-only: see handleBootFilesystemFailure
    func bootFailureStillOpen(_ id: String) -> Bool {
        live[id] != nil && activeBootFailures[id] != nil && pendingBootRemedies[id] == nil
    }

    // @port-skip linux-only: see handleBootFilesystemFailure
    func bootRepairWasTried(_ id: String) -> Bool { bootRepairAttempted.contains(id) }

    /// Stops the wedged VM (an emergency shell answers no power button; its
    /// saved state is worthless), runs the remedy on its disk, and boots it
    /// again -- kept as rebooting throughout (a `--rm` workspace survives).
    // partial: the remedy runs here between the stop and the boot (macOS hands it to the relaunch path)
    // @port ACAppDelegate.performBootRemedy(_: Profile.ID, _: BootRemedy) h=9e99c78078ac6079 @4237c02e
    func performBootRemedy(_ id: String, _ remedy: BootRemedy) async {
        guard live[id] != nil, pendingBootRemedies[id] == nil, let rec = registry.find(id) else { return }
        pendingBootRemedies[id] = remedy
        if remedy == .repairDisk { bootRepairAttempted.insert(id) }
        rebooting.insert(id)
        defer { rebooting.remove(id); stopsDuringReboot.remove(id); pendingBootRemedies[id] = nil }
        try? FileManager.default.removeItem(atPath: snapshotDir(id))
        _ = await deleteVM(rec, action: "kill", partOfReboot: true)
        for _ in 0..<200 where live[id] != nil || stopping[id] != nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // The disk held while the remedy works on it (macOS: whileHoldingDisk):
        // a start meanwhile is refused as for a repair.
        guard repairMarks.insert(id) else { return }
        await repairMarks.whileMarked(id) { await executeBootRemedy(remedy, id: id) }
        // A stop asked meanwhile leaves the workspace off (a `--rm` one goes).
        if await stoppedDuringReboot(id) { return }
        guard var now = registry.find(id), live[id] == nil else { return }
        if now.state == .suspended { now.state = .stopped; try? registry.upsert(now) }
        let started = await start(now)
        if await stoppedDuringReboot(id) { return }
        if started.status >= 300 {
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(now.name)' didn't boot after its disk remedy: \(started.body["error"]?.stringValue ?? "HTTP \(started.status)")\n".utf8))
        }
    }

    /// The remedy on the stopped VM's system disk: a reset removes it (the
    /// next boot clones the base again; the home is its own image), a repair
    /// runs the native checker on it, under the repair mark.
    // partial: Linux's disk layout (<state>/vms/<id>/disk.raw); the event, the log, no pane
    // @port ACAppDelegate.executeBootRemedy(_: BootRemedy, profile: Profile, pane: SessionPane?) h=1df735222becd94a @4237c02e
    func executeBootRemedy(_ remedy: BootRemedy, id: String) async {
        activeBootFailures[id] = nil
        let name = registry.find(id).flatMap { existingProfile(for: $0)?.name } ?? id
        let disk = vmDir(id) + "/disk.raw"
        switch remedy {
        case .resetDisk:
            do {
                if FileManager.default.fileExists(atPath: disk) { try FileManager.default.removeItem(atPath: disk) }
                bootRepairAttempted.remove(id)
                if let pid = UUID(uuidString: id) {
                    BACEventEmitter.shared.emitDetached(profileID: pid, eventType: "vm.disk_reset",
                                                        eventData: ["reason": .string("boot_fsck_failure")])
                }
                FileHandle.standardError.write(Data("bromure-ac daemon: system disk of '\(name)' reset to base after boot failure\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("bromure-ac daemon: disk reset for '\(name)' failed: \(error)\n".utf8))
            }
        case .repairDisk:
            let result: Ext4Fsck.Result? = await SecureDir.offPool { try? Ext4Fsck.check(imagePath: disk, autoFix: true) }
            if let result {
                FileHandle.standardError.write(Data("bromure-ac daemon: native fsck on '\(name)': \(result.summary)\n\(result.output)\n".utf8))
            } else {
                FileHandle.standardError.write(Data("bromure-ac daemon: native fsck on '\(name)' could not open the disk\n".utf8))
            }
        }
    }

    /// A roster means the guest booted all the way to tmux: a failure cycle
    /// (detection, escalation) is over (macOS: onTabList).
    // @port-skip linux-only: the onTabList half of the boot failure, over the outbox roster
    func clearBootFailuresOnRoster() {
        for id in Set(activeBootFailures.keys).union(bootRepairAttempted) where live[id] != nil {
            // This boot's roster: the outbox keeps an earlier boot's.
            let tabs = vmDir(id) + "/outbox/tabs.txt"
            guard let bootedAt = bootStartedAt[id],
                  let m = (try? FileManager.default.attributesOfItem(atPath: tabs))?[.modificationDate] as? Date, m > bootedAt,
                  !GuestOutbox.parseRoster(GuestOutbox.read(tabs) ?? "").isEmpty else { continue }
            activeBootFailures[id] = nil
            bootRepairAttempted.remove(id)
        }
    }
}
