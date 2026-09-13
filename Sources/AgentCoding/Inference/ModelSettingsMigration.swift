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
                    break   // bedrock isn't a global provider; local handled below
                }
            }

            // Local server (recommended route): the first profile with a custom
            // engine URL seeds it.
            if settings.localServer == nil,
               let url = profile.localEngineURL?.trimmingCharacters(in: .whitespaces),
               !url.isEmpty {
                settings.localServer = LocalServer(baseURL: url, apiKey: profile.localEngineAPIKey)
            }

            // Medium tier (the model every single-model agent uses): seed from the
            // first profile that had a local model selected. Cloud profiles used
            // each provider's own default model (no id stored), so there's nothing
            // to carry — the user picks one in the new pane.
            if settings.tiers[.medium] == nil,
               profile.effectiveModelRouting == .local,
               let model = profile.activeModelID?.trimmingCharacters(in: .whitespaces),
               !model.isEmpty {
                let source: ModelRef.Source = (profile.localEngineURL?.isEmpty == false)
                    ? .localServer
                    : .localRun(catalogID: model)
                settings.tiers[.medium] = ModelRef(source: source, modelID: model)
            }
        }

        return settings
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
