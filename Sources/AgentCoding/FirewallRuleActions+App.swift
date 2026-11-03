import AppKit
import SandboxEngine

/// One firewall editor's live edits (issue #48): each valid change to the
/// rule table is committed at once — saved and in force on the running
/// workspace, its timer armed — as a Guardrails grant is, instead of waiting
/// for Save (a test meant Save, closing the window, reopening; and a timed
/// rule extended in the table still expired on the old, saved clock).
/// Closing the editor without saving puts back the rules it opened with,
/// with what changed elsewhere meanwhile (a timeline quick action, an
/// expiry) carried over, and nothing that expired since brought back.
@MainActor final class FirewallLiveEdit {
    /// Commit rules: persist and apply. True when they're in force.
    typealias Commit = (String) -> Bool

    let profileID: UUID
    private let commit: Commit
    /// What closing without saving puts back.
    private(set) var restore: String
    /// The last rules this editor put in force; nil: none yet.
    private(set) var applied: String?
    /// Every text this editor committed: their change notices (which may
    /// arrive after a later edit) are its own, not changes made elsewhere.
    private var ownCommits: Set<String> = []
    private var finished = false
    /// A save is on its way (a fat client's: its document reaches the host
    /// after the live commits already sent): no more edits go out, and a
    /// close meanwhile reverts only if the save fails.
    private var saving = false
    private var revertIfSaveFails = false
    /// The table's latest text: if the save fails with the editor still
    /// open, what it shows goes in force (through the usual settle).
    private var latest: String?
    var isSaving: Bool { saving }
    private var observer: NSObjectProtocol?
    /// Typing settles first: a host half typed isn't put in force.
    private let settle: TimeInterval
    private var pending: DispatchWorkItem?

    init(profileID: UUID, opening: String, settle: TimeInterval = 0.4,
         commit: @escaping Commit, observeChanges: Bool = true) {
        self.profileID = profileID
        self.restore = opening
        self.settle = settle
        self.commit = commit
        guard observeChanges else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .bromureFirewallRulesChanged, object: profileID, queue: .main) { [weak self] note in
            guard let new = note.userInfo?["rules"] as? String else { return }
            let previous = note.userInfo?["previous"] as? String
            MainActor.assumeIsolated { self?.changedElsewhere(previous: previous, new: new) }
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    /// The table changed: in force once the typing settles, when it parses
    /// (a half-typed rule waits for the next keystroke).
    func edited(_ text: String) {
        guard !finished else { return }
        latest = text
        guard !saving else { return }
        pending?.cancel()
        pending = nil
        guard settle > 0 else { apply(text); return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.apply(text) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
    }

    private func apply(_ text: String) {
        pending = nil
        guard !finished, !saving, text != (applied ?? restore), (try? EgressPolicy.parse(text)) != nil else { return }
        // Marked first: the host may announce the change before returning.
        ownCommits.insert(text)
        if commit(text) { applied = text }
    }

    /// The rules changed by another path while the editor is open: carried
    /// into what a cancel restores. Our own commits come back here too.
    func changedElsewhere(previous: String?, new: String) {
        guard !finished, !ownCommits.contains(new) else { return }
        if let previous {
            // The restore point already had it, or takes it rule by rule;
            // unmergeable, the newest rules in force are the safer ones.
            restore = FirewallRuleActions.merge(external: previous, new, into: restore) ?? new
        } else {
            restore = new
        }
    }

    /// Save pressed: the saved document carries the latest rules, so the
    /// edit still settling is dropped and nothing more is sent after it.
    func beginSave() {
        pending?.cancel()
        pending = nil
        saving = true
    }

    /// The save failed (the editor stays open): edits go live again, and a
    /// close that came meanwhile reverts now.
    func saveFailed() {
        saving = false
        if revertIfSaveFails { revertIfSaveFails = false; revert(); return }
        // Still open: what the table shows goes in force, after the same
        // settle a keystroke gets (a half-typed host isn't frozen in).
        if let latest { edited(latest) }
    }

    /// Saved: the edits stay. A Save writes the editor as it was at the
    /// click — for every field, the rules too; the window then closes.
    func keep() {
        pending?.cancel()
        saving = false
        finished = true
    }

    /// Closed without saving: the opening rules (plus changes made
    /// elsewhere) back in force — nothing to do when no edit was applied.
    func revert(now: Date = Date()) {
        guard !finished else { return }
        // Closed while its save is on its way: the save decides.
        if saving { revertIfSaveFails = true; return }
        pending?.cancel()
        finished = true
        guard let applied else { return }
        let back = EgressPolicy.sweeping(restore, now: now, workspaceStopped: false) ?? restore
        if back != applied { _ = commit(back) }
    }
}

/// The expiry sweep's timers (an extension can't hold stored properties).
@MainActor private enum FirewallSweep {
    static var timer: Timer?
    /// One-shot at the soonest timed rule's expiry, so the rule is switched
    /// off — and the connections it allowed are cut — at that instant, not
    /// up to a sweep interval later.
    static var expiryTimer: Timer?
    static var didLaunchSweep = false
}

extension ACAppDelegate {

    /// Push a workspace's outbound rules to its running VM: the switch port
    /// (L4, every frame — see `VMNetSwitch.setEgressPolicy`) and the MiTM
    /// (SNI / CONNECT / HTTP-verb layers read it per connection). No restart.
    func applyLiveFirewall(for profile: Profile, sandbox: UbuntuSandboxVM?) {
        mitmEngine?.setGuardrailsConfig(Self.makeGuardrailsConfig(for: profile), for: profile.id)
        sandbox?.applyEgressPolicy(profile.resolvedEgressPolicy)
    }

    /// Apply a quick edit to a workspace's rules: save, push live to the
    /// running VM, tell an open editor. False when nothing changed.
    @MainActor @discardableResult
    func applyFirewallEdit(_ edit: FirewallRuleActions.Edit, profileID: UUID) -> Bool {
        guard let p = profiles.first(where: { $0.id == profileID }),
              let text = FirewallRuleActions.apply(edit, to: p.egressRules) else { return false }
        return commitFirewallRules(text, profileID: profileID)
    }

    /// Persist `text` as a workspace's rules and apply it live.
    @MainActor @discardableResult
    func commitFirewallRules(_ text: String, profileID: UUID) -> Bool {
        guard var p = profiles.first(where: { $0.id == profileID }), p.egressRules != text else { return false }
        let previous = p.egressRules
        p.egressRules = text
        do { try store.update(p) } catch {
            NSLog("[bromure-ac] firewall: couldn't save rules for \(p.name): \(error)")
            return false
        }
        if let i = profiles.firstIndex(where: { $0.id == profileID }) { profiles[i] = p }
        // Running: switch port + MiTM now. Only the rules are patched into the
        // session's and pane's copies (those are launch-time, model-overlaid
        // profiles), so a later editor save diffs against what's in force —
        // nothing else is re-applied (no terminal re-theme, no env refresh).
        let session = runningSessions[profileID]
        let pane = pane(for: profileID)
        session?.profile.egressRules = text
        pane?.profile.egressRules = text
        if session != nil || pane != nil {
            applyLiveFirewall(for: p, sandbox: session?.sandbox ?? pane?.sandbox)
        }
        // `previous` lets an open editor with unsaved edits merge the change
        // into them rule by rule instead of dropping them.
        NotificationCenter.default.post(name: .bromureFirewallRulesChanged, object: profileID,
                                        userInfo: ["rules": text, "previous": previous])
        scheduleNextFirewallExpiry()
        return true
    }

    /// (Re)arm the one-shot timer for the soonest timed-rule expiry across
    /// workspaces. The evaluators already ignore an expired rule on their own;
    /// this makes the host switch it off at that instant, which re-checks the
    /// open connections it allowed (`MitmEngine.setGuardrailsConfig`).
    @MainActor func scheduleNextFirewallExpiry(now: Date = Date()) {
        FirewallSweep.expiryTimer?.invalidate()
        FirewallSweep.expiryTimer = nil
        let next = profiles.lazy.filter { $0.egressRules.contains("#@until=") }
            .compactMap { (try? EgressPolicy.parse($0.egressRules))?.nextExpiry }
            .min()
        guard let next else { return }
        let t = Timer(fire: max(next, now).addingTimeInterval(0.2), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepFirewallRules() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        FirewallSweep.expiryTimer = t
    }

    /// Start the periodic sweep that switches off expired temporary rules and
    /// saves them. Enforcement doesn't wait for it — the evaluator ignores an
    /// expired rule the moment it expires — so this only keeps the saved text,
    /// the editor and the timeline honest. The first pass also ends every
    /// "until the workspace stops" rule left over from the previous run (no
    /// workspace survives an app quit as "running").
    @MainActor func startFirewallExpirySweep() {
        guard FirewallSweep.timer == nil else { return }
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepFirewallRules() }
        }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        FirewallSweep.timer = t
    }

    @MainActor func sweepFirewallRules(now: Date = Date()) {
        let launch = !FirewallSweep.didLaunchSweep
        FirewallSweep.didLaunchSweep = true
        for p in profiles where p.egressRules.contains("#@") {
            let stopped = launch && runningSessions[p.id] == nil
            if let text = EgressPolicy.sweeping(p.egressRules, now: now, workspaceStopped: stopped) {
                commitFirewallRules(text, profileID: p.id)
            }
        }
        // A timed rule saved from the editor arms its expiry timer here.
        scheduleNextFirewallExpiry(now: now)
    }

    /// `profiles` was reassigned: for each workspace whose rules differ from
    /// `old`, re-arm the expiry timer (a timed rule saved by the CLI or the
    /// editor gets its instant switch-off too) and tell observers.
    @MainActor func firewallProfilesChanged(from old: [Profile]) {
        let before = Dictionary(old.map { ($0.id, $0.egressRules) }, uniquingKeysWith: { a, _ in a })
        let changed = profiles.filter { before[$0.id] != $0.egressRules }.map(\.id)
        guard !changed.isEmpty else { return }
        scheduleNextFirewallExpiry()
        for id in changed {
            NotificationCenter.default.post(name: .bromureFirewallPolicyChanged, object: id)
        }
    }

    /// Wire the firewall's proxy-route cut to the guest: reset agentd's bridge
    /// socket for that connection (see `HTTPMitmConnection.cutForFirewall`).
    @MainActor func installFirewallGuestAbort() {
        EgressConnectionRegistry.shared.guestAbort = { [weak self] pid, port, done in
            Task { @MainActor in
                defer { done() }
                _ = try? await self?.guestJSONRequest(
                    profileID: pid, request: ["bridge_abort": ["port": Int(port)], "timeout": 5])
            }
        }
    }

    /// The workspace stopped: its "until the workspace stops" rules end.
    @MainActor func endUntilStopFirewallRules(for profileID: UUID) {
        guard let p = profiles.first(where: { $0.id == profileID }),
              let text = EgressPolicy.sweeping(p.egressRules, now: Date(), workspaceStopped: true)
        else { return }
        commitFirewallRules(text, profileID: profileID)
    }
}

/// One open workspace settings window and its live firewall edit. However
/// the window closes — Save, Cancel, the close button, its host going away —
/// the session ends: unsaved edits go back (a save's `keep` came first) and
/// `onGone` drops the owner's reference, so the next open builds a new
/// editor from the rules now in force with a new live edit. A window kept
/// after the close button showed the reverted edits as in force, its live
/// edit finished and deaf to further edits (CWE-670).
@MainActor final class SettingsWindowSession {
    let window: NSWindow
    let live: FirewallLiveEdit?
    private var observer: NSObjectProtocol?
    private var onGone: ((SettingsWindowSession) -> Void)?

    init(window: NSWindow, live: FirewallLiveEdit?, onGone: @escaping (SettingsWindowSession) -> Void) {
        self.window = window
        self.live = live
        self.onGone = onGone
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    /// Closes the window, ending the session.
    func close() {
        end()
        window.close()
    }

    var hasEnded: Bool { onGone == nil }

    private func end() {
        guard let gone = onGone else { return }
        onGone = nil
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        live?.revert()
        gone(self)
    }
}
