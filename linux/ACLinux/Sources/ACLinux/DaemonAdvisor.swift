import Foundation
import SandboxEngine

// The OpenShell policy advisor on a Linux server (macOS: the app delegate's
// wireOpenShellAdvisor): its per-workspace mode and effective policy, the
// credential scopes for its risk check, how an approved rule is applied
// (into the workspace's policy, saved through the editor's path, applied
// live), and how approved system packages are installed in the guest.
extension Daemon {
    // @port ACAppDelegate.wireOpenShellAdvisor(_: MitmEngine) h=0c8bae1b66803f62 @2134fc7a
    func wireOpenShellAdvisor() {
        // A new organization boundary / managed policy (the enrollment's
        // heartbeat, a local boundary) re-resolves every running workspace's
        // firewall at once.
        // (The center keeps the observer: the daemon's lifetime.)
        _ = NotificationCenter.default.addObserver(forName: OpenShellGovernance.changedNotification,
                                                   object: nil, queue: nil) { [weak self] _ in
            Task { await self?.reapplyOpenShellGovernance() }
        }
        guard let mitm else { return }
        let advisor = OpenShellAdvisor.shared
        let modes = OpenShellAdvisorModeCache.shared
        advisor.modeProvider = { modes.mode(for: $0) }
        advisor.policyProvider = { [weak mitm] in mitm?.guardrailsConfig(for: $0)?.egressPolicy?.openShell }
        advisor.credentialScopesProvider = { [weak mitm] pid in
            mitm?.swapper.entries(for: pid).compactMap { $0.host } ?? []
        }
        advisor.applyApproved = { pid, proposal in
            await MainActor.run { () -> String? in
                guard let host = LinuxSessionHost.shared,
                      let existing = host.profiles.first(where: { $0.id == pid }) else { return "workspace not found" }
                var updated = existing
                do {
                    updated.networkPolicy = try OpenShellPolicy.insertingRules(proposal.yaml, into: existing.networkPolicy)
                    if let result = OpenShellGovernance.shared.check(policyYAML: updated.networkPolicy,
                                                                      providerRules: updated.openShellProviderRules),
                       !result.passed {
                        return "outside the organization boundary — \(result.summary)"
                    }
                    try host.persistEditedProfile(&updated, editing: existing, generateSSH: false, policySource: "advisor")
                } catch {
                    return "\(error)"
                }
                host.applyLiveEditToRunningSession(updated)
                return nil
            }
        }
        // System packages on request: an approved package is installed by
        // the guest's root supervisor (agentd → sandboxd), never by the agent.
        advisor.systemPackagesProvider = { modes.systemPackagesOn($0) }
        advisor.enforceBinariesProvider = { [weak mitm] in
            mitm?.guardrailsConfig(for: $0)?.egressPolicy?.enforceBinaries == true
        }
        let me = WeakDaemon(self)
        advisor.installPackages = { pid, _, packages in
            guard let shell = await me.daemon?.liveShell(of: pid) else { return (1, "the workspace isn't running") }
            do {
                // No reply deadline: the guest answers only once apt has
                // finished or been stopped, so a failure shown is never one
                // still running.
                let reply = try await shell.request(["apt_install": ["packages": packages], "timeout": 2000])
                return (reply["exit_code"] as? Int ?? 1, reply["output"] as? String ?? "")
            } catch {
                return (1, "\(error)")
            }
        }
        Self.refreshWatchdogModes()
    }

    /// The governance changed: each running workspace's guardrails and egress
    /// policy resolved again, its watchdog mode and the list's shield too.
    // @port ACAppDelegate.reapplyOpenShellGovernance() h=e638e4da0c5cfc55 @d3ebbda2
    func reapplyOpenShellGovernance() async {
        let profiles = ProfileStore().loadAll()
        let running = records.filter { live[$0.id] != nil && !$0.managed }.compactMap { existingProfile(for: $0) }
        let (mitm, sw) = (mitm, sw)
        await MainActor.run {
            OpenShellAdvisorModeCache.shared.refresh(profiles)
            Self.refreshWatchdogModes()
            LinuxSessionHost.shared?.refreshShieldState(profiles)
            for p in running {
                mitm?.setGuardrailsConfig(GuardrailsConfig.make(for: p), for: p.id)
                sw.egress.update(.init(p))
            }
        }
    }

    /// Add a path to a workspace's OpenShell `filesystem_policy` (the
    /// Sandbox drawer's Files tab) and save it through the editor's path.
    /// Landlock is set when the sandboxed session starts and only narrows,
    /// so it applies at the next start. Returns an error message, or nil.
    // @port ACAppDelegate.addSandboxPath(profileID: UUID, path: String, readWrite: Bool) h=0806678fe617e603 @2765424f
    @MainActor static func addSandboxPath(profileID: UUID, path: String, readWrite: Bool) -> String? {
        guard let host = LinuxSessionHost.shared,
              let existing = host.profiles.first(where: { $0.id == profileID }) else { return "workspace not found" }
        var updated = existing
        do {
            updated.networkPolicy = try OpenShellPolicy.addingFilesystemPath(path, readWrite: readWrite,
                                                                              to: existing.networkPolicy)
            guard updated.networkPolicy != existing.networkPolicy else { return nil }
            try host.persistEditedProfile(&updated, editing: existing, generateSSH: false, policySource: "drawer")
        } catch {
            return "\(error)"
        }
        host.applyLiveEditToRunningSession(updated)
        return nil
    }

    /// `/profiles/<id>/proposals…` and the Sandbox drawer's decisions
    /// (`openshell-allow`, `sandbox-path`), answered by the shared handlers
    /// on a dispatch thread as macOS's server thread runs them (they wait on
    /// the advisor, up to 30 s), never on the daemon's own executor.
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onProfileProposals h=c7d57d903eaa8c5b @d3ebbda2
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onProfileSandboxDecision h=fe1139b2848177f1 @d3ebbda2
    // partial: forwarder to the shared ProfileSubRoutes
    // @port ACAppDelegate.static sandboxDecisionRoute(profileID: UUID, _: String, body: [String:Any], allow: @escaping@Sendable(UUID,String,Int,String?)async->String?, addPath: (UUID,String,Bool)->String?) h=99b32e8e958ba43f @d3ebbda2
    // partial: forwarder to the shared ProfileSubRoutes
    // @port ACAppDelegate.static advisorProposalsRoute(profileID: UUID, method: String, sub: [String], body: [String:Any], advisor: OpenShellAdvisor) h=0b91e545e9ce1b3f @d3ebbda2
    nonisolated static func advisorSubRoute(_ pid: UUID, method: String, sub: [String],
                                            body: [String: Any]) async -> (status: Int, body: [String: Any]) {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                let r: (status: Int, body: [String: Any])
                if sub[0] == "proposals" {
                    r = ProfileSubRoutes.advisorProposalsRoute(profileID: pid, method: method, sub: sub, body: body)
                } else if method == "POST", sub.count == 1 {
                    r = ProfileSubRoutes.sandboxDecisionRoute(profileID: pid, sub[0], body: body,
                        allow: { pid, host, port, exe in
                            await OpenShellAdvisor.shared.allow(profileID: pid, host: host, port: port, exe: exe)
                        },
                        addPath: { pid, path, rw in
                            // On the main actor (the editor's save path), waited
                            // for here: this is a dispatch thread, not the main one.
                            let box = SendableBox<String?>("unavailable")
                            let done = DispatchSemaphore(value: 0)
                            Task { @MainActor in
                                box.value = Self.addSandboxPath(profileID: pid, path: path, readWrite: rw)
                                done.signal()
                            }
                            done.wait()
                            return box.value
                        })
                } else {
                    r = (405, ["error": "POST only"])
                }
                c.resume(returning: r)
            }
        }
    }

    /// A running workspace's guest shell, or nil.
    // partial: resolves the running VM's shell (live[])
    // @port ACAppDelegate.sandbox(for: Profile.ID) h=1062ca4f5f94dab2 @d3ebbda2
    func liveShell(of pid: UUID) -> GuestShell? { live[pid.uuidString.lowercased()]?.shell }
}
