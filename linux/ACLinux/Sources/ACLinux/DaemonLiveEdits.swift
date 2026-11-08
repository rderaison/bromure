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
    func scheduleLiveRefresh(_ id: String, force: Bool = false) -> Task<Void, Never> {
        let prior = liveRefreshTail[id]
        let t = Task { await prior?.value; await self.liveRefresh(id, force: force) }
        liveRefreshTail[id] = t
        return t
    }

    /// Queue the whole restage for VM `id`, whatever the workspace's last
    /// edit was: a credential came to exist with no profile change (a
    /// sign-in), as macOS's direct pushLiveCredentials calls.
    // @port-skip linux-only: the daemon's queue for a direct pushLiveCredentials
    @discardableResult
    func scheduleLiveRestage(_ id: String) -> Task<Void, Never> {
        scheduleLiveRefresh(id, force: true)
    }

    /// The VM id of workspace `pid`'s running VM.
    // @port-skip linux-only: Linux workspaces are VM records
    func runningVMID(of pid: UUID) -> String? {
        registry.records.first { UUID(uuidString: $0.id) == pid && live[$0.id] != nil }?.id
    }

    /// One live refresh, for a VM that runs.
    // @port-skip linux-only: the daemon's entry of applyLiveSessionRefresh
    func liveRefresh(_ id: String, force: Bool = false) async {
        guard live[id] != nil, let rec = registry.find(id) else { return }
        await applyLiveRefresh(rec, force: force)
    }

    /// What the stored workspace changed since `rec`'s staging last applied
    /// it (everything, when that's unknown: the daemon restarted since the
    /// launch, or `force`), applied.
    // @port ACAppDelegate.applyLiveSessionRefresh(from: Profile, to: Profile, terminalDefaults: TerminalAppDefaults, window: SessionPane?, sandbox: UbuntuSandboxVM?) h=58c9420641bf9238 @0e28fd20
    func applyLiveRefresh(_ rec: VMRecord, force: Bool = false) async {
        guard !rec.managed, let mitm, let new = existingProfile(for: rec) else { return }
        let steps = Self.liveSteps(from: force ? nil : liveApplied[rec.id], to: new)
        // The local model's route: a host-side remap (the guest calls
        // bromure.llm either way), no restage.
        if steps.routing { startLocalEngineIfNeeded(for: await stagedProfile(new)) }
        // The SSH key's "ask before use" gate is the host agent's.
        if steps.sshGate { mitm.sshAgent.setKeys(Self.loadAgentKeys(for: new, store: profileStore), for: new.id) }
        // Applied only once all of it is: a restage that failed is done
        // again on the next refresh.
        if steps.restage, !(await pushLiveCredentials(rec, new)) { return }
        liveApplied[rec.id] = new
    }

    /// Which of a live refresh's steps an edit from `old` (nil: unknown)
    /// to `new` needs.
    struct LiveSteps: Equatable {
        var routing = true, sshGate = true, restage = true
    }

    // @port-skip linux-only: applyLiveSessionRefresh's conditions, as a function
    static func liveSteps(from old: Profile?, to new: Profile) -> LiveSteps {
        guard let old else { return LiveSteps() }
        return LiveSteps(routing: routingChanged(from: old, to: new),
                         sshGate: old.sshKeyRequiresApproval != new.sshKeyRequiresApproval,
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
    @discardableResult
    func pushLiveCredentials(_ rec: VMRecord, _ raw: Profile) async -> Bool {
        guard let mitm else { return false }
        let profile = await stagedProfile(raw)
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
                                      store: profileStore) { profile, files in
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
    /// adds the subscription CLIs' stand-in files to the seed's files/.
    // @port-skip linux-only: writeCredentialFiles' body
    static func writeCredentialFiles(_ profile: Profile, plan: SessionTokenPlan?, registration: Bool,
                                     meta: URL, kubeYAML: String?, store: ProfileStore,
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
