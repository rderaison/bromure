import Foundation
import SandboxEngine

// A workspace's temporary firewall rules on a Linux server (macOS:
// FirewallRuleActions+App.swift): a rule switched off when its time is up,
// or when the workspace stops ("until the workspace stops"), saved, and
// applied at once to a running workspace's proxy and switch port.
extension Daemon {
    /// Save `text` as the workspace's rules and, while it runs, apply them
    /// now (proxy and switch). False when nothing changed or the save failed.
    // partial: no open editor to tell (no windows on a server)
    // @port ACAppDelegate.commitFirewallRules(_: String, profileID: UUID) h=a096d849c2cb0b25 @d48dfc6f
    @discardableResult
    func commitFirewallRules(_ text: String, profileID: UUID) -> Bool {
        let store = ProfileStore()
        guard var p = store.loadAll().first(where: { $0.id == profileID }), p.egressRules != text else { return false }
        p.egressRules = text
        do { try store.update(p) } catch {
            FileHandle.standardError.write(Data("bromure-ac daemon: firewall: couldn't save rules for \(p.name): \(error)\n".utf8))
            return false
        }
        if live.keys.contains(where: { UUID(uuidString: $0) == profileID }) {
            mitm?.applyWorkspacePolicies(p)
            sw.egress.update(.init(p))
        }
        return true
    }

    /// The workspace stopped: its "until the workspace stops" rules end.
    // @port ACAppDelegate.endUntilStopFirewallRules(for: UUID) h=313e7a206f2ca535 @d48dfc6f
    func endUntilStopFirewallRules(for profileID: UUID) {
        guard let p = ProfileStore().loadAll().first(where: { $0.id == profileID }),
              let text = EgressPolicy.sweeping(p.egressRules, now: Date(), workspaceStopped: true)
        else { return }
        commitFirewallRules(text, profileID: profileID)
    }

    /// Every workspace's temporary rules swept: expired ones switched off,
    /// and at launch a stopped workspace's until-stop ones too (the previous
    /// run's "until the workspace stops" ended with it).
    // @port ACAppDelegate.sweepFirewallRules(now: Date) h=3cd736ebd61f06ec @d48dfc6f
    func sweepFirewallRules(now: Date = Date(), launch: Bool) {
        for p in ProfileStore().loadAll() where p.egressRules.contains("#@") {
            let stopped = launch && !live.keys.contains(where: { UUID(uuidString: $0) == p.id })
            if let text = EgressPolicy.sweeping(p.egressRules, now: now, workspaceStopped: stopped) {
                commitFirewallRules(text, profileID: p.id)
            }
        }
    }

    /// The sweep, at launch and every 15 s (macOS: startFirewallExpirySweep's
    /// timer). The evaluators already ignore an expired rule, and the
    /// connection registry cuts its connections at the instant: this saves
    /// it switched off.
    // partial: a 15 s sweep only (macOS also arms a one-shot timer at the soonest expiry to save it at that instant)
    // @port ACAppDelegate.startFirewallExpirySweep() h=55632e1734dfb938 @d48dfc6f
    func startFirewallExpirySweep() {
        Task { [weak self] in
            await self?.sweepFirewallRules(launch: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self else { return }
                await self.sweepFirewallRules(launch: false)
            }
        }
    }
}
