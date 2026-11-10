import Foundation

/// Fusion's per-workspace config and toggle, as the macOS app delegate keeps
/// them (BromureAC.swift's Fusion helpers), for the Linux proxy
/// (MitmFusion.swift): a workspace's config is pushed at its launch and on a
/// model-settings change, and starts disengaged; `POST /vms/<id>/fusion`
/// engages it. Each leg uses this daemon's (this user's) own credentials:
/// the workspace's swap map and this process's subscription stores.
extension Daemon {
    /// The profile as Fusion judges it: the global Models settings overlaid.
    // @port ACAppDelegate.fusionEffectiveProfile(_: Profile) h=ea6d043b4f70aa06 @4237c02e
    func fusionEffectiveProfile(_ profile: Profile) async -> Profile {
        let subscribed = subscribedProviders(for: profile)
        return await MainActor.run {
            profile.overlaidWithGlobalModels(ModelSettingsStore.shared.effective(for: profile), subscribed: subscribed)
        }
    }

    /// Whether Fusion can be engaged for this workspace (≥ 2 usable legs).
    // @port ACAppDelegate.fusionConfigurable(_: Profile) h=734885782a91c97f @4237c02e
    func fusionConfigurable(_ profile: Profile) async -> Bool {
        await fusionEffectiveProfile(profile).fusionConfigurable
    }

    // @port ACAppDelegate.makeFusionConfig(for: Profile) h=44829c995024e2c0 @4237c02e
    func makeFusionConfig(for rawProfile: Profile) async -> Fusion.Config? {
        let profile = await fusionEffectiveProfile(rawProfile)
        return await MainActor.run { () -> Fusion.Config? in
            guard profile.fusionConfigurable else { return nil }
            let usable = profile.fusionUsableProviders   // cloud providers with creds
            var legs = Profile.Tool.allCases.filter {
                profile.fusionLegs.contains($0) && usable.contains($0)
            }
            // The local Fusion leg (a model served by the on-host engine).
            let localLegModel: String? = {
                guard let id = profile.fusionLocalLeg, !id.isEmpty else { return nil }
                return CatalogStore.shared.resolve(id)?.repo ?? id
            }()
            // Need ≥2 drafts to fuse (cloud legs + the local leg). If the user
            // under-specified, default to fusing every usable cloud provider.
            if legs.count + (localLegModel != nil ? 1 : 0) < 2 { legs = usable }

            var authModes: [Profile.Tool: Profile.AuthMode] = [:]
            for spec in profile.allToolSpecs { authModes[spec.tool] = spec.authMode }

            // Oh My Pi: fused on the provider it's switched to, with the model the
            // Models settings pick for it there (else that provider's default).
            let ompProvider = profile.allToolSpecs.first { $0.tool == .omp }?.effectiveOmpProvider ?? .default
            var legModels: [Profile.Tool: String] = [:]
            if let ref = ModelSettingsStore.shared.effective(for: rawProfile).ref(for: .omp, tier: .medium),
               case .provider(let prov) = ref.source,
               prov == ModelProvider.from(omp: ompProvider), !ref.modelID.isEmpty {
                legModels[.omp] = ref.modelID
            }

            // Judge: the local engine, or a chosen cloud provider.
            let judgeLocal = profile.fusionJudgeLocal
            let judgeProvider = (profile.fusionJudgeProvider.flatMap { usable.contains($0) ? $0 : nil })
                ?? usable.first ?? .claude
            let judgeModel: String
            if judgeLocal {
                let id = profile.fusionJudgeModel ?? profile.fusionLocalLeg ?? ""
                judgeModel = CatalogStore.shared.resolve(id)?.repo ?? id
            } else if judgeProvider == .omp {
                // An omp judge speaks omp's provider — default to its leg model,
                // not the Claude-only engine default.
                judgeModel = profile.fusionJudgeModel ?? legModels[.omp]
                    ?? Fusion.defaultLegModel(.omp, .token, ompProvider: ompProvider)
            } else {
                judgeModel = profile.fusionJudgeModel ?? Fusion.defaultJudgeModel
            }

            return Fusion.Config(legs: legs, judgeProvider: judgeProvider,
                                 judgeModel: judgeModel, authModes: authModes,
                                 legModels: legModels, localLegModel: localLegModel, judgeLocal: judgeLocal,
                                 localEngineBase: profile.localEngineBaseURL?.absoluteString,
                                 localEngineKey: profile.localEngineAPIKey,
                                 ompProvider: ompProvider)
        }
    }

    /// Fusion on or off for a running workspace (macOS: the title-bar
    /// toggle's setFusionEngaged; the proxy holds the flag, as there).
    // partial: no pane or session model to mirror the flag into (/vms reads it off the proxy)
    // @port ACAppDelegate.setFusionEngaged(_: Bool, for: Profile) h=8e19c2b3407484d4 @4237c02e
    func setFusionEngaged(_ engaged: Bool, for profileID: UUID) {
        mitm?.setFusionEngaged(engaged, for: profileID)
    }

    /// A launch's Fusion: the config pushed, disengaged until the user turns
    /// it on (macOS: launch's Fusion block).
    // @port-skip linux-only: launch's Fusion block, on the daemon's launch
    func applyFusionAtLaunch(_ profile: Profile) async {
        setFusionEngaged(false, for: profile.id)
        mitm?.setFusionConfig(await makeFusionConfig(for: profile), for: profile.id)
    }

    /// A model-settings change re-judges Fusion: the fresh config pushed, and
    /// disengaged if it's no longer configurable (macOS: LiveModelRefresh's
    /// and profilesDidChange's Fusion reconcile).
    // @port-skip linux-only: the Fusion reconcile of refreshModelsForRunningWorkspaces / profilesDidChange
    func reconcileFusion(_ profile: Profile) async {
        mitm?.setFusionConfig(await makeFusionConfig(for: profile), for: profile.id)
        if !(await fusionConfigurable(profile)) { setFusionEngaged(false, for: profile.id) }
    }

    /// `POST /vms/<id>/fusion {"engaged": bool}` (the CLI's `vm fusion`, a
    /// fat client's ⚡, the remote menu).
    // @port ACAppDelegate.automationSetFusion(idOrName: String, engaged: Bool) h=cc530c9ea02bed43 @4237c02e
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onSetFusion h=623b91993210d190 @d3ebbda2
    func fusionRoute(_ rec: VMRecord, _ body: JSONValue) async -> ControlResponse {
        // Any running VM with a workspace profile, as macOS (no managed
        // exclusion; /vms's fusionConfigurable says the same).
        guard live[rec.id] != nil, let profile = existingProfile(for: rec) else {
            return .error(409, "VM not found: \(rec.name)", ["ok": false])
        }
        guard await fusionConfigurable(profile) else {
            return ControlResponse(409, ["ok": false, "error": "Fusion needs at least two usable model credentials on this workspace."])
        }
        let engaged = body["engaged"] == .bool(true)
        setFusionEngaged(engaged, for: profile.id)
        return ControlResponse(200, ["ok": true, "engaged": .bool(engaged)])
    }
}
