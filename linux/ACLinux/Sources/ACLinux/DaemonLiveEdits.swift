import Foundation

/// A running workspace's edit, applied to its VM without a reboot (macOS:
/// applyLiveSessionRefresh → pushLiveCredentials): its local-model route,
/// its SSH key's approval gate, and, when the edit touches a credential,
/// the environment or a policy (Profile.sessionRefreshAffectingChange),
/// the credential restage: the token plan, the swap map merged (a running
/// agent's old stand-in keeps working), minted credentials, kube material,
/// AWS keys, and the guest's files, the home seed (seed.generation, which
/// agentd's seed watcher re-applies) and the meta share's api_key.env,
/// proxy.env and MCP configs (env.generation, which open shells re-source
/// at their next prompt). The trace level is the edit host's
/// (LinuxProfileEditHost); the guardrails and egress policies, which the
/// save applies too, are re-applied here with the rest.
extension Daemon {
    /// Queue a live refresh of VM `id`'s workspace. One workspace's run one
    /// after another, each from the workspace as it is stored when it runs,
    /// so the last one leaves the last save applied.
    // @port-skip linux-only: the daemon's queue for applyLiveSessionRefresh (macOS runs it on the main thread)
    @discardableResult
    func scheduleLiveRefresh(_ id: String, force: Bool = false, restartAgents: Bool = true) -> Task<Void, Never> {
        let prior = liveRefreshTail[id]
        let t = Task { await prior?.value; await self.liveRefresh(id, force: force, restartAgents: restartAgents) }
        liveRefreshTail[id] = t
        return t
    }

    /// Queue the whole restage for VM `id`, whatever the workspace's last
    /// edit was: a credential came to exist with no profile change (a
    /// sign-in), as macOS's direct pushLiveCredentials calls: no agent is
    /// restarted (`restartAgents`: the global Models refresh's, which does).
    // @port-skip linux-only: the daemon's queue for a direct pushLiveCredentials
    @discardableResult
    func scheduleLiveRestage(_ id: String, restartAgents: Bool = false) -> Task<Void, Never> {
        scheduleLiveRefresh(id, force: true, restartAgents: restartAgents)
    }

    /// The VM id of workspace `pid`'s running VM.
    // @port-skip linux-only: Linux workspaces are VM records
    func runningVMID(of pid: UUID) -> String? {
        registry.records.first { UUID(uuidString: $0.id) == pid && live[$0.id] != nil }?.id
    }

    /// One live refresh, for a VM that runs.
    // @port-skip linux-only: the daemon's entry of applyLiveSessionRefresh
    func liveRefresh(_ id: String, force: Bool = false, restartAgents: Bool = true) async {
        guard live[id] != nil, let rec = registry.find(id) else { return }
        await applyLiveRefresh(rec, force: force, restartAgents: restartAgents)
    }

    /// What the stored workspace changed since `rec`'s staging last applied
    /// it (everything, when that's unknown: the daemon restarted since the
    /// launch, or `force`), applied.
    // @port ACAppDelegate.applyLiveSessionRefresh(from: Profile, to: Profile, terminalDefaults: TerminalAppDefaults, window: SessionPane?, sandbox: UbuntuSandboxVM?) h=58c9420641bf9238 @0e28fd20
    func applyLiveRefresh(_ rec: VMRecord, force: Bool = false, restartAgents: Bool = true) async {
        guard !rec.managed, let mitm, let new = existingProfile(for: rec) else { return }
        // Fusion's config can change without any other step (its legs, its
        // judge): reconciled first and unconditionally, as macOS does.
        await reconcileFusion(new)
        let steps = Self.liveSteps(from: force ? nil : liveApplied[rec.id], to: new)
        // The local model's route: a host-side remap (the guest calls
        // bromure.llm either way), no restage.
        if steps.routing {
            let staged = await stagedProfile(new)
            applyRouting(staged: staged)
            startLocalEngineIfNeeded(for: staged)
        }
        // The SSH key's "ask before use" gate is the host agent's.
        if steps.sshGate { mitm.sshAgent.setKeys(Self.loadAgentKeys(for: new, store: profileStore), for: new.id) }
        // The imported and host-agent keys' gates too (a key taken off stays
        // loaded, and gated, until the restart).
        if steps.importedKeys {
            mitm.sshAgent.setImportedKeyApprovals(
                Self.liveImportedKeyApprovals(running: mitm.sshAgent.importedKeyApprovals(for: new.id), to: new), for: new.id)
            mitm.sshAgent.setHostAgentKeys(Self.hostAgentKeys(new), for: new.id)
        }
        // Applied only once all of it is: a restage that failed is done
        // again on the next refresh.
        let priorStaged = lastStagedProfiles[rec.id]
        // An edit not yet applied restarts its agents even on a forced
        // restage that otherwise wouldn't (a sign-in's, a cluster's): it
        // advances the staging the edit's own refresh would compare against.
        let restart = Self.restartsAgents(asked: restartAgents, applied: liveApplied[rec.id], stored: new)
        if steps.restage {
            let ok = await pushLiveCredentials(rec, new)
            // The agents whose staging moved restart in place, conversation
            // kept, whether or not every write landed (macOS: from its defer).
            if restart { await restartAgentsWhoseModelsChanged(profileID: new.id, id: rec.id, priorStaged: priorStaged) }
            if !ok { return }
        }
        liveApplied[rec.id] = new
    }

    /// After a restage: restart, in place, the agents whose staging moved
    /// between `priorStaged` and what pushLiveCredentials just recorded.
    // @port ACAppDelegate.restartAgentsWhoseModelsChanged(profileID: UUID, priorStaged: Profile?) h=b90fb658f27488de @bd69274f
    func restartAgentsWhoseModelsChanged(profileID: UUID, id: String, priorStaged: Profile?) async {
        guard let prior = priorStaged, let now = lastStagedProfiles[id], prior != now else { return }
        let tools = LiveModelRefresh.agentsNeedingRestart(from: prior, to: now)
        guard !tools.isEmpty else { return }
        await MainActor.run { SessionStores.shared?.engine?.restartAgentsInPlace(profileID: profileID, tools: tools) }
    }

    /// Which of a live refresh's steps an edit from `old` (nil: unknown)
    /// to `new` needs.
    struct LiveSteps: Equatable {
        var routing = true, sshGate = true, importedKeys = true, restage = true
    }

    /// Whether a refresh restarts the agents whose staging moved: asked
    /// to (a profile edit's, the global Models refresh's), or a stored edit
    /// that needs a restage isn't applied yet (a forced restage running
    /// first would otherwise leave the edit's own refresh nothing to see).
    // @port-skip linux-only: see applyLiveRefresh
    static func restartsAgents(asked: Bool, applied: Profile?, stored: Profile) -> Bool {
        asked || (applied.map { liveSteps(from: $0, to: stored).restage } ?? false)
    }

    // @port-skip linux-only: applyLiveSessionRefresh's conditions, as a function
    static func liveSteps(from old: Profile?, to new: Profile) -> LiveSteps {
        guard let old else { return LiveSteps() }
        return LiveSteps(routing: routingChanged(from: old, to: new),
                         sshGate: old.sshKeyRequiresApproval != new.sshKeyRequiresApproval,
                         importedKeys: old.importedSSHKeys != new.importedSSHKeys,
                         restage: Profile.sessionRefreshAffectingChange(from: old, to: new))
    }

    /// The edits that move a workspace's local-model route (macOS: the
    /// routing step of applyLiveSessionRefresh).
    // @port-skip linux-only: applyLiveSessionRefresh's routing condition, as a function
    static func routingChanged(from old: Profile, to new: Profile) -> Bool {
        old.activeModelID != new.activeModelID
            || old.modelRouting != new.modelRouting
            || old.localEngineBaseURL != new.localEngineBaseURL
            || old.localEngineAPIKey != new.localEngineAPIKey
            || old.modelOverride != new.modelOverride
    }

    /// The credential half: the policies, the plan and swap map, and the
    /// guest's files, as the launch stages them, with the map merged.
    // partial: no PII model download, fusion, or 1Password error prompt (not on Linux yet)
    // @port ACAppDelegate.pushLiveCredentials(for: Profile, terminalDefaults: TerminalAppDefaults, sandbox: UbuntuSandboxVM?) h=12a93ff58499be07 @0e28fd20
    // @port SessionDisk.refreshMetadataShare(profile: Profile, tokenPlan: SessionTokenPlan?) h=5b64b7f1093111b6 @e81ff085
    // @port UbuntuSandboxVM.applyEgressPolicy(_: EgressPolicy?) h=871ee8ef54b551a8 @132bb730
    @discardableResult
    func pushLiveCredentials(_ rec: VMRecord, _ raw: Profile) async -> Bool {
        guard let mitm else { return false }
        let profile = await stagedProfile(raw, mcpTokens: true)
        lastStagedProfiles[rec.id] = profile
        await MainActor.run {
            mitm.applyWorkspacePolicies(raw)
            sw.egress.update(.init(raw))
            Self.refreshWatchdogModes()
        }
        let plan = Self.makeSessionTokenPlan(for: profile, mitm: mitm)
        // The swap map: the plan's, minted credentials' and the kubeconfigs'
        // entries merged into the running one (installKube, live).
        let kubeYAML = await kubeconfig(for: profile, plan: plan, live: true)
        let meta = URL(fileURLWithPath: vmDir(rec.id) + "/meta")
        pushAWSCredentials(for: profile, meta: meta.path)
        var ok = true
        do {
            try writeCredentialFiles(profile, plan: plan, registration: false, meta: meta, kubeYAML: kubeYAML)
            HomeSeed.bumpGenerationCounter(named: "seed.generation", in: meta)
        } catch {
            ok = false
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': live home-seed refresh failed: \(error)\n".utf8))
        }
        do {
            try writeProxyMeta(meta, profile: profile, tokenPlan: plan,
                               extraNoProxy: await kubeNoProxy(for: raw.id), registries: await kubeRegistries(for: raw.id))
            HomeSeed.bumpGenerationCounter(named: "env.generation", in: meta)
        } catch {
            ok = false
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': live env refresh failed: \(error)\n".utf8))
        }
        return ok
    }

    /// The workspace's credential files in its meta share, as a launch and
    /// a live refresh write them: the home seed (the managed dotfiles with
    /// the plan's fakes, the kubeconfig, Codex's, Grok's and Kimi's
    /// stand-ins, the manifest and
    /// Claude's spec, its key pre-approved), the agents' MCP configs, and
    /// api_key.env (the plan's fakes under their variables).
    // @port-skip linux-only: the home-seed and meta-share steps of ACAppDelegate.launch / pushLiveCredentials on the Linux meta share
    func writeCredentialFiles(_ profile: Profile, plan: SessionTokenPlan?, registration: Bool,
                              meta: URL, kubeYAML: String?) throws {
        try Self.writeCredentialFiles(profile, plan: plan, registration: registration, meta: meta, kubeYAML: kubeYAML,
                                      store: profileStore,
                                      setupDir: setupDir, sentryModules: sentryModules) { profile, files in
            seedCodexAuthFile(for: profile, homeRoot: files)
            seedGrokAuthFile(for: profile, homeRoot: files)
            seedKimiAuthFile(for: profile, homeRoot: files)
        }
    }

    /// The meta-share files writeAgentConfigs may write.
    // @port-skip linux-only: the Linux meta share's restage (macOS writes a fresh share each time)
    static let agentConfigFiles = ["codex-local.toml", "grok-local.toml", "kimi.toml", "omp-model", "omp-models.yml",
                                   "omp-config.yml", SessionDisk.ompEnvUnsetMetaFile, SessionDisk.kimiApprovalsMetaFile]

    /// writeCredentialFiles over a given store (testable); `seedStandIns`
    /// adds the subscription CLIs' stand-in files to the seed's files/;
    /// `setupDir`, the guest scripts beside agentd, stages the guest
    /// sandbox (nil: none, a test's).
    // @port-skip linux-only: writeCredentialFiles' body
    static func writeCredentialFiles(_ profile: Profile, plan: SessionTokenPlan?, registration: Bool,
                                     meta: URL, kubeYAML: String?, store: ProfileStore, setupDir: URL? = nil,
                                     sentryModules: SentryModuleStore? = nil,
                                     seedStandIns: (Profile, URL) -> Void) throws {
        let seed = meta.appendingPathComponent("home-seed", isDirectory: true)
        try store.writeHomeSeedFiles(for: profile, into: seed, terminalDefaults: .fallback, tokenPlan: plan,
                                     kubeconfigYAML: kubeYAML)
        // The agents' MCP configs (the built-ins and the workspace's own
        // servers, their tokens as stand-ins), as macOS writes them.
        try SessionDisk.writeMCPConfigs(into: meta, profile: profile, tokenPlan: plan)
        // Each agent's own config files (Codex's and Grok's local providers,
        // Kimi's block, omp's model and settings), as macOS stages them. The
        // meta share outlives a restage here (macOS writes a fresh one), so
        // what a previous staging wrote and this one doesn't goes first.
        for name in Self.agentConfigFiles { try? FileManager.default.removeItem(at: meta.appendingPathComponent(name)) }
        try SessionDisk.writeAgentConfigs(into: meta, profile: profile, tokenPlan: plan)
        // The guest sandbox (the strict marker and root attestor, the
        // package shims, the OpenShell spec with its root launcher and
        // supervisor, the advisor's address), as macOS stages it; it removes
        // what this staging doesn't ask for. Its shared folders are its
        // workdirs (~/<basename>), as macOS's. Its kernel modules from the
        // verified catalog cache (none without a catalog: a sentry workspace
        // isn't started then, DaemonSandboxGuard).
        if let setupDir {
            let workdirs = SessionDisk.sharedFolders(profile.folderPaths).map { "/home/ubuntu/\($0.mountName)" }
            try SessionDisk.writeSandboxFiles(into: meta, profile: profile, setupDir: setupDir, workdirs: workdirs) { sentryDest in
                sentryModules?.stageKnown(for: profile.id, setupDir: setupDir, into: sentryDest)
            }
        }
        if !registration {
            seedStandIns(profile, seed.appendingPathComponent("files", isDirectory: true))
        }
        try store.finalizeHomeSeed(for: profile, seedDir: seed,
                                   anthropicEnvKey: plan?.fakeForAnthropic() ?? plan?.claudeSubscriptionBogusKey,
                                   bedrockBearerFake: plan?.fakeForBedrock())
        // The guest's credential environment, sourced by its .bashrc, as
        // macOS's session disk writes it.
        try SessionDisk.apiKeyEnvLines(profile: Self.envProfile(profile, plan: plan), tokenPlan: plan,
                                       registrationMode: registration)
            .joined(separator: "\n").appending("\n")
            .write(to: meta.appendingPathComponent("api_key.env"), atomically: true, encoding: .utf8)
    }
}
