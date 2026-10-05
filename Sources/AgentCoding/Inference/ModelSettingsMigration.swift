import Foundation

// MARK: - Migration: existing per-workspace profiles → global ModelSettings
//
// Model config used to live on each `Profile` (per-tool API keys / auth modes,
// `activeModelID`, `localEngine*`, omp provider/model). The redesign moves it to
// one global `ModelSettings`. On first launch after the upgrade the global store
// is empty; this seeds it from what the user already configured so nothing is
// lost and the new "Models" pane opens pre-populated.

public extension ModelProvider {
    /// The provider a coding agent speaks to natively.
    static func native(for tool: Profile.Tool) -> ModelProvider {
        switch tool {
        case .claude: return .anthropic
        case .codex:  return .openai
        case .grok:   return .xai
        case .kimi:   return .moonshot
        case .omp:    return .anthropic   // omp's own provider is resolved separately
        }
    }

    /// Map omp's provider enum onto the global provider enum.
    static func from(omp: Profile.OmpProvider) -> ModelProvider {
        switch omp {
        case .anthropic: return .anthropic
        case .openai:    return .openai
        case .xai:       return .xai
        case .zai:       return .zai
        case .custom:    return .custom
        }
    }
}

public extension ModelSettings {
    /// Build the global settings implied by a set of existing profiles. Provider
    /// credentials are unioned (first-writer-wins per provider, so an earlier
    /// profile's key isn't clobbered by a later empty one); the local server and
    /// the medium tier are seeded from the first profile that has them.
    static func migrated(from profiles: [Profile]) -> ModelSettings {
        var settings = ModelSettings()

        func registerProvider(_ provider: ModelProvider, apiKey: String?,
                              useSubscription: Bool = false, baseURL: String? = nil) {
            // First usable registration wins — don't overwrite a real key with a
            // later blank, or a subscription with nothing.
            if let existing = settings.credential(provider), existing.isUsable { return }
            let cred = ProviderCredential(provider: provider, apiKey: apiKey,
                                          useSubscription: useSubscription, baseURL: baseURL)
            guard cred.isUsable else { return }
            settings.providers.removeAll { $0.provider == provider }
            settings.providers.append(cred)
        }

        for profile in profiles {
            for spec in profile.allToolSpecs {
                switch spec.authMode {
                case .token:
                    let key = spec.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let key, !key.isEmpty else { continue }
                    if spec.tool == .omp {
                        let prov = ModelProvider.from(omp: spec.effectiveOmpProvider)
                        registerProvider(prov, apiKey: key,
                                         baseURL: prov == .custom ? spec.ompBaseURL : nil)
                    } else {
                        registerProvider(.native(for: spec.tool), apiKey: key)
                    }
                case .subscription:
                    let prov = ModelProvider.native(for: spec.tool)
                    if prov.supportsSubscription {
                        registerProvider(prov, apiKey: nil, useSubscription: true)
                    }
                case .bedrock, .local:
                    // Bedrock stays with its workspace (see
                    // `Profile.bedrockModelOverride`); local handled below.
                    break
                }
            }

            // Local server (recommended route): remember the first custom engine
            // URL a profile used, as a convenience. This is just a remembered
            // endpoint — it does NOT select a tier, so migrating never silently
            // flips a cloud workspace onto a local model. The user picks the
            // small/medium/large tier models themselves in the new pane (a global
            // choice, deliberately theirs to make).
            if settings.localServer == nil,
               let url = profile.localEngineURL?.trimmingCharacters(in: .whitespaces),
               !url.isEmpty {
                settings.localServer = LocalServer(baseURL: url, apiKey: profile.localEngineAPIKey)
            }
        }

        return settings
    }
}

public extension Profile {
    /// Whether Claude Code in this workspace was set to authenticate through
    /// Amazon Bedrock under the old per-tool auth picker.
    var usesBedrockAuth: Bool {
        allToolSpecs.contains { $0.tool == .claude && $0.authMode == .bedrock }
    }

    /// The per-workspace override that keeps a Bedrock workspace on Bedrock
    /// after the redesign: a LAYER over the global settings that registers
    /// Bedrock (unless the global settings already do) and points Claude
    /// Code's model at it (its old default model id, or the placeholder the
    /// picker showed). Everything else keeps inheriting. nil when the
    /// workspace isn't Bedrock or already has an override of its own.
    func bedrockModelOverride(global: ModelSettings) -> ModelOverride? {
        guard modelOverride == nil, usesBedrockAuth else { return nil }
        var layer = ModelSettings()
        if !(global.credential(.bedrock)?.isUsable ?? false) {
            layer.providers.append(ProviderCredential(provider: .bedrock))
        }
        let id = bedrockModelID.trimmingCharacters(in: .whitespaces)
        layer.agentTiers[.claude] = [.medium: ModelRef(
            source: .provider(.bedrock),
            modelID: id.isEmpty ? ProviderModels.bedrockPlaceholder : id)]
        return ModelOverride(inheritsGlobal: true, settings: layer)
    }
}

public extension Profile {
    /// A workspace that names its OWN local engine the pre-Models way —
    /// routed local, its agent on `.local`, an engine URL and the model it
    /// serves on the record (`localEngineURL` + `activeModelID`) — as the
    /// per-workspace layer that makes that choice win over the global
    /// Models settings. Without it the launch overlay staged the GLOBAL
    /// default (another server, another model): QA-omp's GLM on :8888 ran
    /// as deepseek on :8001, and every turn failed upstream.
    ///
    /// nil when the workspace has an override of its own (that is the
    /// choice), names no engine, or asks for exactly what the global
    /// settings already give its local agents.
    func legacyLocalEngineOverride(global: ModelSettings) -> ModelOverride? {
        guard case .own(let o)? = legacyLocalEngine(global: global) else { return nil }
        return o
    }

    /// What the record's old local-engine fields amount to: nothing, the
    /// global settings again (`.sameAsGlobal` — stale copies to clear, or a
    /// later change of the global server would pin the workspace to the old
    /// one), or a choice of its own.
    enum LegacyLocalEngine: Equatable { case sameAsGlobal, own(ModelOverride) }

    func legacyLocalEngine(global: ModelSettings) -> LegacyLocalEngine? {
        guard modelOverride == nil, modelRouting == .local,
              let url = localEngineURL?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty,
              let model = activeModelID?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty
        else { return nil }
        let agents = allToolSpecs.filter { $0.authMode == .local }.map { ModelAgent.from($0.tool) }
        guard !agents.isEmpty else { return nil }
        func norm(_ s: String?) -> String {
            var u = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while u.hasSuffix("/") { u.removeLast() }
            if u.hasSuffix("/v1") { u.removeLast(3) }
            return u
        }
        let same = agents.allSatisfy { agent in
            guard let r = global.ref(for: agent, tier: .medium), r.modelID == model else { return false }
            switch r.source {
            case .localServer: return norm(global.localServer?.baseURL) == norm(url)
            case .provider(.custom): return norm(global.credential(.custom)?.baseURL) == norm(url)
            default: return false
            }
        }
        guard !same else { return .sameAsGlobal }
        var layer = ModelSettings()
        let key = localEngineAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        layer.localServer = LocalServer(baseURL: url, apiKey: (key ?? "").isEmpty ? nil : key)
        for agent in agents {
            let tiers: [ModelTier] = agent.usesAllTiers ? ModelTier.allCases : [.medium]
            var t: [ModelTier: ModelRef] = [:]
            for tier in tiers { t[tier] = ModelRef(source: .localServer, modelID: model) }
            layer.agentTiers[agent] = t
        }
        return .own(ModelOverride(inheritsGlobal: true, settings: layer))
    }

    /// The old fields moved: a choice of its own written onto the record
    /// as its override; either way the old fields are cleared (so removing
    /// the override later really means "use the global settings"). nil:
    /// nothing to move.
    func migratedLegacyLocalEngine(global: ModelSettings) -> Profile? {
        guard let legacy = legacyLocalEngine(global: global) else { return nil }
        var p = self
        if case .own(let override) = legacy { p.modelOverride = override }
        p.localEngineURL = nil
        p.localEngineAPIKey = nil
        return p
    }

    /// A workspace whose omp still carries the pre-5.0 custom server
    /// (`ompProvider == .custom` + base URL + model on the agent itself):
    /// nothing in the UI showed it any more, yet every launch staged it
    /// (issue #36). Moved into the workspace's model override — the custom
    /// provider, and omp's model when nothing else gives omp one — where
    /// it can be seen, edited and removed, then cleared from the agent.
    /// nil: nothing to move, or the override already names another custom
    /// server (left alone).
    func migratedLegacyOmpCustom(global: ModelSettings) -> Profile? {
        let isPrimary = tool == .omp
        guard let spec = allToolSpecs.first(where: { $0.tool == .omp }),
              spec.effectiveOmpProvider == .custom,
              let base = spec.ompBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty
        else { return nil }
        func norm(_ s: String?) -> String {
            var u = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while u.hasSuffix("/") { u.removeLast() }
            if u.hasSuffix("/v1") { u.removeLast(3) }
            return u
        }
        let inherits = modelOverride?.inheritsGlobal ?? true
        var layer = modelOverride?.settings ?? ModelSettings()
        let key = spec.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let own = layer.credential(.custom) {
            guard norm(own.baseURL) == norm(base) else { return nil }
        } else if !(inherits && norm(global.credential(.custom)?.baseURL) == norm(base)) {
            // Not already the server everyone uses: this workspace's own.
            layer.providers.append(ProviderCredential(provider: .custom,
                                                      apiKey: (key ?? "").isEmpty ? nil : key,
                                                      baseURL: base))
        }
        let model = spec.ompModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ompHasModel = layer.ref(for: .omp, tier: .medium) != nil
            || (inherits && global.ref(for: .omp, tier: .medium) != nil)
        if !model.isEmpty, !ompHasModel {
            layer.agentTiers[.omp] = [.medium: ModelRef(source: .provider(.custom), modelID: model)]
        }
        var p = self
        p.modelOverride = ModelOverride(inheritsGlobal: inherits, settings: layer,
                                        excludedProviders: modelOverride?.excludedProviders ?? [])
        // The agent no longer carries it — nor the key, which now sits on the
        // provider (left on the agent, it would pass for an Anthropic key).
        if isPrimary {
            p.ompProvider = nil; p.ompBaseURL = nil; p.ompModel = nil; p.apiKey = nil
        } else if let i = p.additionalTools.firstIndex(where: { $0.tool == .omp }) {
            p.additionalTools[i].ompProvider = nil
            p.additionalTools[i].ompBaseURL = nil
            p.additionalTools[i].ompModel = nil
            p.additionalTools[i].apiKey = nil
        }
        return p
    }
}

public extension ModelSettingsStore {
    /// True when nothing has been configured yet — the signal to migrate.
    var isEmpty: Bool {
        settings.providers.isEmpty && settings.localServer == nil
            && settings.tiers.isEmpty && settings.localRunModels.isEmpty
    }

    /// One-shot seed from existing profiles, only when the store is still empty.
    /// Idempotent: a second call (or a launch after the user edited settings)
    /// does nothing. Returns whether it wrote anything.
    @discardableResult
    func seedIfEmpty(from profiles: [Profile]) -> Bool {
        guard isEmpty else { return false }
        let migrated = ModelSettings.migrated(from: profiles)
        guard migrated != ModelSettings() else { return false }  // nothing to carry
        update { $0 = migrated }
        InferenceLog.shared.record(
            "[models] migrated global settings from \(profiles.count) profile(s): "
            + "\(migrated.providers.count) provider(s), "
            + "localServer=\(migrated.localServer != nil), "
            + "medium=\(migrated.tiers[.medium]?.modelID ?? "—")")
        return true
    }
}
