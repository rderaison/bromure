import Foundation
import SandboxEngine

// A workspace's temporary firewall rules on a Linux server (macOS:
// FirewallRuleActions+App.swift): a rule switched off when its time is up,
// or when the workspace stops ("until the workspace stops"), saved, and
// applied at once to a running workspace's proxy and switch port.
extension Daemon {
    /// Save `text` as the workspace's rules and, while it runs, apply them
    /// now (proxy and switch). True when they changed.
    // @port ACAppDelegate.commitFirewallRules(_: String, profileID: UUID) h=e66f4af84d83bb53 @f127f8ab
    @discardableResult
    func commitFirewallRules(_ text: String, profileID: UUID) -> Bool {
        commitFirewallRulesResult(text, profileID: profileID) == .changed
    }

    /// The same, saying how it went: changed, already so, or why it failed.
    // partial: no open editor to tell (no windows on a server)
    // @port ACAppDelegate.commitFirewallRulesResult(_: String, profileID: UUID) h=f3258e46b059b44e @f127f8ab
    // partial: inline mitm.applyWorkspacePolicies + sw.egress.update when the VM is live
    // @port ACAppDelegate.applyLiveFirewall(for: Profile, sandbox: UbuntuSandboxVM?) h=74be56fc525a94b7 @f127f8ab
    @discardableResult
    func commitFirewallRulesResult(_ text: String, profileID: UUID) -> FirewallCommitResult {
        var changed = false, name = ""
        let p: Profile
        do {
            guard let saved = try ProfileWrites.edit(profileID, store: ProfileStore(), { p in
                name = p.name
                guard p.egressRules != text else { return false }
                p.egressRules = text
                changed = true
                return true
            }) else { return .failed("unknown workspace") }
            p = saved
        } catch {
            FileHandle.standardError.write(Data("bromure-ac daemon: firewall: couldn't save rules for \(name): \(error)\n".utf8))
            return .failed("couldn't save the workspace's firewall rules")
        }
        guard changed else { return .unchanged }
        if live.keys.contains(where: { UUID(uuidString: $0) == profileID }) {
            mitm?.applyWorkspacePolicies(p)
            sw.egress.update(.init(p))
        }
        scheduleNextFirewallExpiry()
        return .changed
    }

    /// A quick edit (a drawer's Allow, Disable, Enable, Remove) applied to
    /// the workspace's rules as they are now, and saved. A failure says why:
    /// a fat client's drawer must not show an Allow that installed nothing.
    // @port ACAppDelegate.applyFirewallEditResult(_: FirewallRuleActions.Edit, profileID: UUID) h=137b3f8d4496cc84 @f127f8ab
    // partial: the Bool wrapper isn't separate; callers read .succeeded
    // @port ACAppDelegate.applyFirewallEdit(_: FirewallRuleActions.Edit, profileID: UUID) h=148f35f2b54c1266 @f127f8ab
    func applyFirewallEditResult(_ edit: FirewallRuleActions.Edit, profileID: UUID) -> FirewallCommitResult {
        // The read the edit applies to and its save, as one write.
        ProfileWrites.locked {
            guard let p = ProfileStore().loadAll().first(where: { $0.id == profileID }) else { return .failed("unknown workspace") }
            switch FirewallRuleActions.outcome(edit, to: p.egressRules) {
            case .changed(let text): return commitFirewallRulesResult(text, profileID: profileID)
            case .unchanged:         return .unchanged
            case .failed(let why):   return .failed(why)
            }
        }
    }

    /// A commit's reply: 200 with whether it changed, else 409 with why.
    // @port ACAutomationServer.static firewallResponse(_: FirewallCommitResult) h=4d01159725fd4e78 @f127f8ab
    static func firewallResponse(_ result: FirewallCommitResult) -> ControlResponse {
        switch result {
        case .changed:          return ControlResponse(200, ["ok": true, "changed": true])
        case .unchanged:        return ControlResponse(200, ["ok": true, "changed": false])
        case .failed(let why):  return ControlResponse(409, ["ok": false, "error": .string(why)])
        }
    }

    /// `POST /profiles/<id>/firewall {rules}`: the whole ruleset, committed
    /// (400 when it doesn't parse or the workspace is unknown).
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onCommitFirewall h=686bf7cbe90e15bb @d3ebbda2
    func firewallRoute(_ key: String, _ body: JSONValue) -> ControlResponse {
        guard let rules = body["rules"]?.stringValue else { return .error(400, "rules required") }
        guard let p = Self.workspace(key), (try? EgressPolicy.parse(rules)) != nil else {
            return ControlResponse(400, ["ok": false, "error": "unknown workspace or invalid rules"])
        }
        return Self.firewallResponse(commitFirewallRulesResult(rules, profileID: p.id))
    }

    /// `POST /profiles/<id>/firewall-edit {op, rule | ruleText, duration}`:
    /// one quick edit, applied to the rules as they are now (concurrent edits
    /// each land, in the order they arrive: the daemon is one actor).
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onFirewallEdit h=7abba4c76d944e14 @d3ebbda2
    func firewallEditRoute(_ key: String, _ body: JSONValue) -> ControlResponse {
        guard let doc = body.foundationObject as? [String: Any], let edit = FirewallRuleActions.Edit(wire: doc) else {
            return .error(400, "a valid edit (op insert|disable|enable|remove) required")
        }
        guard let p = Self.workspace(key) else { return ControlResponse(404, ["ok": false, "error": "unknown workspace"]) }
        return Self.firewallResponse(applyFirewallEditResult(edit, profileID: p.id))
    }

    /// The workspace stopped: its "until the workspace stops" rules end.
    // @port ACAppDelegate.endUntilStopFirewallRules(for: UUID) h=313e7a206f2ca535 @d48dfc6f
    func endUntilStopFirewallRules(for profileID: UUID) {
        ProfileWrites.locked {
            guard let p = ProfileStore().loadAll().first(where: { $0.id == profileID }),
                  let text = EgressPolicy.sweeping(p.egressRules, now: Date(), workspaceStopped: true)
            else { return }
            commitFirewallRules(text, profileID: profileID)
        }
    }

    /// Every workspace's temporary rules swept: expired ones switched off,
    /// and at launch a stopped workspace's until-stop ones too (the previous
    /// run's "until the workspace stops" ended with it).
    // @port ACAppDelegate.sweepFirewallRules(now: Date) h=3cd736ebd61f06ec @d48dfc6f
    func sweepFirewallRules(now: Date = Date(), launch: Bool) {
        ProfileWrites.locked {
            for p in ProfileStore().loadAll() where p.egressRules.contains("#@") {
                let stopped = launch && !live.keys.contains(where: { UUID(uuidString: $0) == p.id })
                if let text = EgressPolicy.sweeping(p.egressRules, now: now, workspaceStopped: stopped) {
                    commitFirewallRules(text, profileID: p.id)
                }
            }
        }
        // A timed rule saved another way (the profile route) arms its expiry here.
        scheduleNextFirewallExpiry(now: now)
    }

    /// (Re)arm the one-shot wake at the soonest timed-rule expiry across
    /// workspaces. The evaluators already ignore an expired rule on their
    /// own; this switches it off and saves it at that instant (which
    /// re-checks the connections it allowed), not up to a sweep later.
    // @port ACAppDelegate.scheduleNextFirewallExpiry(now: Date) h=f53a9fea59399798 @d48dfc6f
    func scheduleNextFirewallExpiry(now: Date = Date()) {
        firewallExpiryTask?.cancel()
        firewallExpiryTask = nil
        let next = ProfileStore().loadAll().lazy.filter { $0.egressRules.contains("#@until=") }
            .compactMap { (try? EgressPolicy.parse($0.egressRules))?.nextExpiry }
            .min()
        guard let next else { return }
        let delay = max(next.timeIntervalSince(now), 0) + 0.2
        firewallExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            guard !Task.isCancelled else { return }
            await self?.sweepFirewallRules(launch: false)
        }
    }

    /// The sweep, at launch and every 15 s (macOS: startFirewallExpirySweep's
    /// timer), besides the one-shot wake at the soonest expiry
    /// (scheduleNextFirewallExpiry). The evaluators already ignore an
    /// expired rule, and the connection registry cuts its connections at
    /// the instant: this saves it switched off.
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
