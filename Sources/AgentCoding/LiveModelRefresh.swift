import Combine
import Foundation

// MARK: - Live model / credential refresh — no VM restart
//
// Registering a provider, pasting a key, signing in or out, or moving an
// agent to another model used to leave the running machine on its
// launch-time staging (a running agent's process env is frozen at exec), so
// the honest answer was "restart the workspace". Now the change lands live:
//
//   1. the host restages what the guest reads — swap map, api_key.env /
//      proxy.env, the per-agent config files, the home seed — exactly the
//      way an editor save already does (`pushLiveCredentials`);
//   2. each agent whose credential or model actually changed is stopped in
//      its own tmux window, the shell re-runs the managed rc (fresh env +
//      config files), and the agent picks its conversation back up with its
//      resume flags. The chat view keeps its transcript; a terminal user
//      sees the agent quit and come straight back.
//
// Agents whose staging didn't change are left alone.

/// Which agents a staging change touches — pure, so it can be tested.
enum LiveModelRefresh {
    /// The tools whose launch-time staging differs between two overlaid
    /// profiles: their own spec (auth, key, local model, omp provider), or the
    /// session-wide local/Bedrock fields every `.local` / Bedrock agent reads.
    static func agentsNeedingRestart(from old: Profile, to new: Profile) -> Set<Profile.Tool> {
        var out = Set<Profile.Tool>()
        for tool in Profile.Tool.allCases {
            let a = old.allToolSpecs.first { $0.tool == tool }
            let b = new.allToolSpecs.first { $0.tool == tool }
            if (a == nil) != (b == nil) { if b != nil { out.insert(tool) }; continue }
            guard let a, let b else { continue }
            // The primary agent's spec mirrors the workspace-wide active model,
            // so its `localModelID` moves whenever ANY agent's local model does
            // — only meaningful for an agent that is itself local.
            let localModelMoved = (a.authMode == .local || b.authMode == .local)
                && a.localModelID != b.localModelID
            if a.authMode != b.authMode || a.apiKey != b.apiKey || localModelMoved
                || a.ompProvider != b.ompProvider || a.ompBaseURL != b.ompBaseURL
                || a.ompModel != b.ompModel {
                out.insert(tool)
            }
        }
        let localChanged = old.activeModelID != new.activeModelID
            || old.modelRouting != new.modelRouting
            || old.localEngineURL != new.localEngineURL
            || old.localEngineAPIKey != new.localEngineAPIKey
        if localChanged {
            for spec in new.allToolSpecs where spec.authMode == .local { out.insert(spec.tool) }
        }
        if old.bedrockEnabled != new.bedrockEnabled || old.bedrockModelID != new.bedrockModelID
            || (new.bedrockEnabled && old.awsCredentials.region != new.awsCredentials.region)
            || old.claudeGatewayBaseURL != new.claudeGatewayBaseURL
            || old.claudeGatewayModels != new.claudeGatewayModels {
            out.insert(.claude)
        }
        return out
    }
}

extension ACAppDelegate {

    /// Watch the global Models settings and the host-side logins; a change
    /// (debounced — the pane saves on every keystroke) restages every running
    /// workspace and restarts the agents it affects.
    @MainActor
    func installLiveModelRefresh() {
        modelSettingsObserver = ModelSettingsStore.shared.$settings
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshModelsForRunningWorkspaces() }
        NotificationCenter.default.addObserver(
            forName: .bromureSubscriptionStoresChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshModelsForRunningWorkspaces() }
        }
    }

    /// What a workspace's agents would be staged with right now.
    @MainActor
    private func stagedProfile(for stored: Profile) -> Profile {
        stored.overlaidWithGlobalModels(ModelSettingsStore.shared.effective(for: stored),
                                        subscribed: subscribedProviders(for: stored))
    }

    /// Restage every running workspace whose agents' staging changed, then
    /// restart those agents in place.
    @MainActor
    func refreshModelsForRunningWorkspaces() {
        for session in runningSessions.values where session.kubeClusterID == nil {
            let pid = session.profileID
            let stored = profiles.first(where: { $0.id == pid }) ?? session.profile
            let fresh = stagedProfile(for: stored)
            guard let prior = lastStagedProfiles[pid] else {
                lastStagedProfiles[pid] = fresh
                continue
            }
            let tools = LiveModelRefresh.agentsNeedingRestart(from: prior, to: fresh)
            guard !tools.isEmpty else { continue }
            BACDebug.log("models", "\(stored.name): restaging for \(tools.map(\.rawValue).sorted().joined(separator: ", "))")
            // Swap map, env, config files, home seed — and `lastStagedProfiles`.
            pushLiveCredentials(for: stored, terminalDefaults: terminalDefaults, sandbox: session.sandbox)
            if let engine = mitmEngine {
                applyRouting(engine, for: stored)
                // Moving onto Bedrock needs the workspace's AWS credentials on
                // the host (SSO resolved) — launch does this; a live move must too.
                if fresh.usesBedrockRoute, !prior.usesBedrockRoute {
                    pushAWSCredentials(for: fresh, engine: engine)
                }
            }
            startLocalEngineIfNeeded(for: stored)
            restartAgentsWhoseModelsChanged(profileID: pid, priorStaged: prior)
        }
    }

    /// After a restage: restart, in place, the agents whose staging moved
    /// between `priorStaged` and what `pushLiveCredentials` just recorded.
    @MainActor
    func restartAgentsWhoseModelsChanged(profileID: UUID, priorStaged: Profile?) {
        guard let prior = priorStaged, let now = lastStagedProfiles[profileID], prior != now else { return }
        let tools = LiveModelRefresh.agentsNeedingRestart(from: prior, to: now)
        guard !tools.isEmpty else { return }
        agentSessionEngine.restartAgentsInPlace(profileID: profileID, tools: tools)
    }
}

extension AgentSessionEngine {
    /// Restart every live session of `tools` on `profileID` in its own tab,
    /// resuming the conversation: interrupt the agent (twice — how these CLIs
    /// leave their prompt), wait for the shell, re-run the managed rc so the
    /// new env and config files are in force, then the agent's resume
    /// command. Sessions mid sign-in are the sign-in card's to relaunch.
    func restartAgentsInPlace(profileID: UUID, tools: Set<Profile.Tool>) {
        let targets = store.sessions.filter {
            $0.profileID == profileID && $0.windowIndex != nil && $0.endedAt == nil
                && !$0.isArchived && !$0.isDeleted && $0.needsSignIn == nil
                && tools.contains($0.tool)
        }
        for s in targets {
            BACDebug.log("models", "restart “\(s.title)” in place (\(s.tool.rawValue))")
            Task { [weak self] in await self?.restartInPlace(s) }
        }
    }

    private func restartInPlace(_ s: AgentSession) async {
        guard let delegate, let w = s.windowIndex else { return }
        let pid = s.profileID
        if await probeAlive(profileID: pid, window: w) ?? false {
            _ = try? await delegate.guestExec(
                profileID: pid,
                command: "tmux send-keys -t bromure:\(w) C-c; sleep 0.4; tmux send-keys -t bromure:\(w) C-c",
                timeout: 10)
            var gone = false
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 800_000_000)
                if await probeAlive(profileID: pid, window: w) == false { gone = true; break }
            }
            if !gone {
                // Still at its prompt: end the pane's foreground processes.
                _ = try? await delegate.guestExec(
                    profileID: pid,
                    command: "p=$(tmux display-message -p -t bromure:\(w) '#{pane_pid}' 2>/dev/null); "
                        + "[ -n \"$p\" ] && pkill -TERM -P \"$p\"; true",
                    timeout: 10)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        guard store.session(s.id) != nil else { return }
        let resume = ([s.tool.rawValue] + Self.resumeFlags(for: s).split(separator: " ").map(String.init))
            .joined(separator: " ")
        let cmd = "source ~/.bashrc >/dev/null 2>&1; clear; " + resume
        _ = try? await delegate.guestExec(
            profileID: pid, command: CodingTaskEngine.typeCommand(tabIndex: w, text: cmd), timeout: 15)
        if let tab = delegate.pane(for: pid)?.model.tabs.first(where: { $0.index == w }) {
            tab.agentStatus = .done
        }
        // Same bookkeeping as a resume: the "exited" verdict waits until the
        // agent has been seen running again, so the session never reads as
        // ended while it comes back.
        store.mutate(s.id) {
            $0.endedAt = nil; $0.lastSeenAt = Date()
            $0.resumedAt = Date(); $0.agentAlive = nil
            $0.changesSeenAt = nil
        }
    }
}
