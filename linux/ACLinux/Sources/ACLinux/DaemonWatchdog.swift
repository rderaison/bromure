import Foundation
import NIOConcurrencyHelpers

extension Daemon {
    /// Tests: the owner's answer to a watchdog quarantine (nil: asked
    /// through the broker).
    static let watchdogAnswerForTesting = NIOLockedValueBox<(@Sendable (UUID) async -> Int)?>(nil)
    /// The daemon whose hooks AgentWatchdog holds (a test's daemon stopping
    /// leaves another's alone).
    static let watchdogOwner = NIOLockedValueBox<ObjectIdentifier?>(nil)

    /// The agent watchdog's wiring (macOS: launch's modeProvider, onTrip and
    /// 5 s egress sampler): each workspace's mode from its profile, a trip
    /// handed to handleWatchdogTrip, the switch's outbound bytes sampled.
    // @port-skip linux-only: the daemon's share of ACAppDelegate's watchdog wiring
    func wireWatchdog() {
        Self.refreshWatchdogModes()
        Self.watchdogOwner.withLockedValue { $0 = ObjectIdentifier(self) }
        AgentWatchdog.shared.modeProvider = { OpenShellAdvisorModeCache.shared.watchdogMode(for: $0) }
        AgentWatchdog.shared.onTrip = { [weak self] pid, mode, signals in
            Task { await self?.handleWatchdogTrip(pid, mode: mode, signals: signals) }
        }
        watchdogSampler?.cancel()
        watchdogSampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await self.sampleWatchdogBytes(interval: 5)
                // The same 5 s tick reads the guests' heartbeats.
                await self.observeGuestLiveness()
            }
        }
    }

    /// The daemon stops: no sampler, and no hooks into it left behind.
    // @port-skip linux-only: the daemon's share of ACAppDelegate's watchdog wiring
    func unwireWatchdog() {
        guard let sampler = watchdogSampler else { return }
        sampler.cancel()
        watchdogSampler = nil
        let mine = Self.watchdogOwner.withLockedValue { owner in
            guard owner == ObjectIdentifier(self) else { return false }
            owner = nil
            return true
        }
        guard mine else { return }
        AgentWatchdog.shared.onTrip = nil
        AgentWatchdog.shared.modeProvider = { _ in .off }
    }

    /// The workspaces' watchdog modes, re-read from the store (macOS: the
    /// profiles' didSet refreshes the same cache).
    // @port-skip linux-only: ACAppDelegate.profiles' didSet refresh, from the Linux store
    static func refreshWatchdogModes() {
        OpenShellAdvisorModeCache.shared.refresh(ProfileStore().loadAll())
    }

    /// Each running workspace's off-subnet bytes, from its VM's switch port.
    // @port-skip linux-only: the sampler's body over the daemon's running VMs
    func sampleWatchdogBytes(interval: TimeInterval) {
        for rec in registry.records where live[rec.id] != nil {
            guard let pid = UUID(uuidString: rec.id) else { continue }
            AgentWatchdog.shared.sampleBytes(profileID: pid, total: sw.egress.egressByteCount(for: MAC(InterimSwitch.mac(rec.mac))),
                                             interval: interval)
        }
    }

    // MARK: Pause holds (shared with the compromise handler)

    /// The VM `id` paused for one more question (the first pauses it): a
    /// watchdog quarantine and a compromise alert can be up at once, and
    /// neither resumes the other's pause.
    // @port-skip linux-only: the Linux daemon's pause bookkeeping (macOS answers one modal at a time)
    func holdPause(_ id: String, _ vm: any CompromiseVM) async throws {
        pauseHolds[id, default: 0] += 1
        if pauseHolds[id] == 1 { try await vm.pause() }
    }

    /// One question about the VM `id` answered: the last one resumes it, if
    /// it's paused, after a Release that waited for it re-opens its network.
    // @port-skip linux-only: see holdPause
    func letGoPause(_ id: String, _ vm: any CompromiseVM) async {
        let left = (pauseHolds[id] ?? 1) - 1
        pauseHolds[id] = left > 0 ? left : nil
        guard left <= 0 else { return }
        let paused = await vm.isPaused()
        // Another question took the VM meanwhile: it lets go later (and a
        // Release waiting stays waiting).
        guard pauseHolds[id] == nil else { return }
        let released = releaseWhenFree.remove(id) != nil
        if released, let rec = registry.find(id) {
            sw.egress.setQuarantined(false, for: MAC(InterimSwitch.mac(rec.mac)))
            Self.clearQuarantineMark(vmDir(id))
        }
        // Resumed unless it's known to be running (an API that didn't
        // answer must not leave it paused for ever).
        if paused != false {
            try? await vm.resume()
            // A question that came during the resume holds it again.
            if pauseHolds[id] != nil { try? await vm.pause() }
        }
        // Resumed first, then a fresh window (macOS's order).
        if released, let pid = UUID(uuidString: id) { AgentWatchdog.shared.release(profileID: pid) }
    }

    /// The VM `id` stopped: no questions hold it any more.
    // @port-skip linux-only: see holdPause
    func clearPauseHolds(_ id: String) {
        pauseHolds[id] = nil
        releaseWhenFree.remove(id)
    }

    // MARK: Quarantine

    /// The quarantine's mark in the VM's directory: a restarted daemon that
    /// takes the VM back cuts its port again and asks again.
    // @port-skip linux-only: the Linux daemon's restart survival (macOS's app and VMs end together)
    static func quarantineMark(_ dir: String) -> String { dir + "/watchdog-quarantine" }

    // @port-skip linux-only: see quarantineMark
    static func clearQuarantineMark(_ dir: String) { try? FileManager.default.removeItem(atPath: quarantineMark(dir)) }

    /// A taken-back VM that was quarantined: its port is cut before it's
    /// attached (adoptRunning), then its owner is asked again, unless its
    /// workspace's watchdog is no longer in quarantine mode (the mark goes).
    // @port-skip linux-only: see quarantineMark
    func readoptQuarantine(_ rec: VMRecord) -> Bool {
        guard FileManager.default.fileExists(atPath: Self.quarantineMark(vmDir(rec.id))) else { return false }
        guard let pid = UUID(uuidString: rec.id), AgentWatchdog.shared.modeProvider(pid) == .quarantine else {
            Self.clearQuarantineMark(vmDir(rec.id))
            return false
        }
        AgentWatchdog.shared.markTripped(profileID: pid)
        sw.egress.setQuarantined(true, for: MAC(InterimSwitch.mac(rec.mac)))
        FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': watchdog: still quarantined after the restart; asking again\n".utf8))
        return true
    }

    /// A taken-back VM found paused with no quarantine to re-ask (a
    /// restart during a compromise alert, or between a Release and its
    /// resume): the alert's question is gone with the old daemon, so one
    /// whose workspace was marked compromised is stopped (the mark was its
    /// answer), and any other resumed.
    // @port-skip linux-only: the Linux daemon's restart survival (macOS's app and VMs end together)
    func readoptPaused(_ id: String) async {
        guard pauseHolds[id] == nil, let pid = UUID(uuidString: id), let (vid, vm) = compromiseVM(pid), vid == id,
              await vm.isPaused() == true, pauseHolds[id] == nil, let rec = registry.find(id) else { return }
        if let profile = existingProfile(for: rec), Self.isCompromised(profile, store: profileStore) {
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': taken back paused and marked compromised: stopped\n".utf8))
            _ = await deleteVM(rec, action: "kill")
            return
        }
        FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': taken back paused with no question up: resumed\n".utf8))
        try? await vm.resume()
    }

    /// A tripped watchdog in quarantine mode: the VM's port drops every IP
    /// frame, the VM is paused, and its owner is asked through the client
    /// (PendingPromptBroker, as macOS asks a headless session): Shut down,
    /// Keep quarantined (resumed, network still cut), or Release (network
    /// back, resumed, then a fresh window). No answer in 180 s keeps it
    /// quarantined. Alert mode only records (the watchdog's own event).
    // @port ACAppDelegate.handleWatchdogTrip(_: UUID, mode: AgentWatchdogMode, signals: [AgentWatchdog.Signal]) h=3eb8b5650bd7464b @a0266d0e
    func handleWatchdogTrip(_ pid: UUID, mode: AgentWatchdogMode, signals: [AgentWatchdog.Signal]) async {
        guard mode == .quarantine else { return }
        await quarantineAndAsk(pid, signals: signals)
    }

    /// Cuts the VM's port (and marks it), pauses it and asks; `signals`
    /// empty: asked again after a restart.
    // @port-skip linux-only: handleWatchdogTrip's body, shared with the restart's re-ask
    func quarantineAndAsk(_ pid: UUID, signals: [AgentWatchdog.Signal]) async {
        guard let (id, machine) = compromiseVM(pid), let rec = registry.find(id) else { return }
        // One watchdog question per VM at a time.
        guard watchdogAsking.insert(id).inserted else { return }
        defer { watchdogAsking.remove(id) }
        let port = MAC(InterimSwitch.mac(rec.mac))
        let name = existingProfile(for: rec)?.name ?? rec.name
        sw.egress.setQuarantined(true, for: port)
        try? Data().write(to: URL(fileURLWithPath: Self.quarantineMark(vmDir(id))), options: .atomic)
        FileHandle.standardError.write(Data("bromure-ac daemon: '\(name)': watchdog: quarantined\n".utf8))
        do { try await holdPause(id, machine) } catch {
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(name)': watchdog: pause failed (\(error))\n".utf8))
        }
        let (title, message, buttons) = Self.watchdogQuestion(name, signals: signals)
        let choice: Int
        if let answer = Self.watchdogAnswerForTesting.withLockedValue({ $0 }) {
            choice = await answer(pid)
        } else {
            choice = await PendingPromptBroker.shared.askAsync(
                profileID: pid, title: title, message: message, buttons: buttons, fallback: 1, timeout: 180)
        }
        // The answer is about that VM: one stopped (or replaced) meanwhile
        // gets none of it (its port's quarantine went with it).
        guard let now = compromiseVM(pid), now.vm === machine, now.id == id else {
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(name)': watchdog: the VM it was about is gone; answer \(choice) dropped\n".utf8))
            return
        }
        switch choice {
        case 2:
            // Network back once no other question holds the VM (a
            // compromise alert up meanwhile keeps it cut and paused).
            releaseWhenFree.insert(id)
            await letGoPause(id, machine)
        case 1:
            // Kept: a Release still waiting from an earlier question doesn't
            // override this answer.
            releaseWhenFree.remove(id)
            await letGoPause(id, machine)
        default:
            // Paused and untrusted: killed, not shut down cleanly.
            if let rec = registry.find(id) { _ = await deleteVM(rec, action: "kill") }
        }
    }

    /// The question's title, text and buttons (macOS: handleWatchdogTrip's
    /// alert, localized the same way).
    // @port-skip linux-only: handleWatchdogTrip's alert text, for the broker
    static func watchdogQuestion(_ workspace: String, signals: [AgentWatchdog.Signal]) -> (String, String, [String]) {
        let kinds = Array(Set(signals.map(\.kind))).sorted().joined(separator: ", ")
        let title = NSLocalizedString("The agent watchdog quarantined this workspace", comment: "watchdog alert title")
        var info = String(format: NSLocalizedString(
            "“%@” behaved outside its normal pattern (%@) within a minute. Its network is cut and the VM is paused.",
            comment: "watchdog alert body"), workspace, kinds.isEmpty ? "asked again after a restart" : kinds) + "\n\n"
        for s in signals.suffix(8) { info += "  • \(s.kind): \(s.detail)\n" }
        let buttons = [NSLocalizedString("Shut down", comment: ""),
                       NSLocalizedString("Keep quarantined", comment: "watchdog: resume with network cut"),
                       NSLocalizedString("Release", comment: "watchdog: restore network and resume")]
        return (title, info, buttons)
    }
}
