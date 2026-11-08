import Foundation

extension Daemon {
    /// A Bedrock engine without a pasted key signs with the workspace's AWS
    /// credentials, consent-gated like every AWS call the host signs
    /// (macOS: the engine's wiring sets the same signer).
    // @port-skip linux-only: the daemon's share of ACAppDelegate's ExternalEngine.awsSigner wiring
    static func installBedrockSigner(_ awsCreds: AWSCredentialServer) {
        ExternalEngine.awsSigner = { pid in
            let hint = NSLocalizedString("for Amazon Bedrock model calls (signed on the host)", comment: "")
            if case .material(let c) = await awsCreds.signingMaterial(for: pid, scopeHint: hint) { return c }
            return nil
        }
    }

    /// A host-side login landing (a registration, a sign-in) restages the
    /// running workspaces it affects (macOS: installLiveModelRefresh's
    /// subscription-store observer). The global Models settings' change is
    /// the settings route's to report (no settings publisher here).
    // @port ACAppDelegate.installLiveModelRefresh() h=c399cf92b2bb4a6c @bd69274f
    func installLiveModelRefresh() {
        modelRefreshObserver = NotificationCenter.default.addObserver(
            forName: .bromureSubscriptionStoresChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.refreshModelsForRunningWorkspaces() }
        }
    }

    /// Restage every running workspace whose agents' staging changed (the
    /// global Models settings, a login), then restart those agents in place.
    /// A workspace moving onto Bedrock gets its AWS credentials on the host
    /// with the restage (pushLiveCredentials pushes them every time).
    // partial: no fusion re-judge (no fusion on Linux)
    // @port ACAppDelegate.refreshModelsForRunningWorkspaces() h=c64dcbdbe066ff8d @bd69274f
    func refreshModelsForRunningWorkspaces() async {
        for rec in registry.records where live[rec.id] != nil && rec.kube == nil && !rec.managed && rec.registration != true {
            guard let stored = existingProfile(for: rec), let pid = UUID(uuidString: rec.id) else { continue }
            let fresh = await stagedProfile(stored)
            guard let prior = lastStagedProfiles[rec.id] else {
                lastStagedProfiles[rec.id] = fresh
                continue
            }
            let tools = LiveModelRefresh.agentsNeedingRestart(from: prior, to: fresh)
            if tools.isEmpty {
                // No agent to restart, but the engine may still have moved.
                if LiveModelRefresh.engineRegistrationChanged(from: prior, to: fresh) {
                    applyRouting(staged: fresh)
                    startLocalEngineIfNeeded(for: fresh)
                    lastStagedProfiles[rec.id] = fresh
                }
                continue
            }
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(stored.name)': restaging for \(tools.map(\.rawValue).sorted().joined(separator: ", "))\n".utf8))
            // Swap map, env, config files, home seed, the AWS credentials,
            // and lastStagedProfiles.
            await scheduleLiveRestage(rec.id).value
            applyRouting(staged: fresh)
            startLocalEngineIfNeeded(for: fresh)
            guard let now = lastStagedProfiles[rec.id], prior != now else { continue }
            let restart = LiveModelRefresh.agentsNeedingRestart(from: prior, to: now)
            guard !restart.isEmpty else { continue }
            await MainActor.run { SessionStores.shared?.engine?.restartAgentsInPlace(profileID: pid, tools: restart) }
        }
    }
}
