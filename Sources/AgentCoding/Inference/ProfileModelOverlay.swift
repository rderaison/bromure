import Foundation

// MARK: - Launch-time overlay: global ModelSettings → the profile the pipeline stages
//
// Model config is global now (providers, local server, tiers), while a Profile
// only says WHICH agent(s) to run. Rather than rewrite every staging seam
// (SessionDisk env/config, the token plan, routing) to read ModelSettings
// directly, we project the global settings onto a launch-time COPY of the
// profile at the single choke point before staging. The proven pipeline then
// runs unchanged — this is a plain adapter.
//
// Projection rules:
//   • Local primary tier (custom server or on-device): every agent runs local,
//     pinned to the tier's model; the custom-server URL/key seed localEngine*.
//   • Cloud: each agent draws its provider's *global* credential (API key or
//     subscription), so registering a provider once configures that agent in
//     every workspace — no per-workspace key, no "Agents" tab.
//
// A provider an agent needs but the user hasn't registered leaves that agent's
// existing per-workspace auth untouched (graceful, not broken).

public extension Profile {
    /// A launch-time copy of this profile with the global model settings
    /// projected on — PER AGENT: each tool resolves its own medium tier (its
    /// override, else the default), so different agents can run different
    /// models. Returns `self` unchanged when nothing is configured globally.
    ///
    /// The staging pipeline serves ONE local model per session (the on-host
    /// engine is single-model), so when several agents are local they share the
    /// primary agent's local model via `activeModelID`; cloud agents each draw
    /// their own provider credential independently.
    func overlaidWithGlobalModels(_ settings: ModelSettings) -> Profile {
        let hasProviders = settings.providers.contains { $0.isUsable }
        let hasTiers = !settings.tiers.isEmpty
            || settings.agentTiers.values.contains { !$0.isEmpty }
        guard hasProviders || hasTiers else { return self }

        var p = self
        var anyLocal = false
        var localServerBackend: (url: String?, key: String?)?

        // Resolve one agent: set its auth (+ return its local model id, if local).
        func applyAgent(tool: Tool, ompProvider: OmpProvider?, ompBaseURL: String?,
                        authMode: inout AuthMode, apiKey: inout String?) -> String? {
            let agent = ModelAgent.from(tool)
            let ref = settings.ref(for: agent, tier: .medium)
                ?? settings.ref(for: agent, tier: .large)
                ?? settings.ref(for: agent, tier: .small)
            if let ref, ref.isLocal {
                authMode = .local
                anyLocal = true
                if case .localServer = ref.source, let ls = settings.localServer {
                    localServerBackend = (ls.baseURL, ls.apiKey)
                }
                return ref.modelID
            }
            if let (mode, key) = Self.cloudAuth(tool: tool, ompProvider: ompProvider,
                                                ompBaseURL: ompBaseURL, settings: settings) {
                authMode = mode
                apiKey = key
            }
            return nil
        }

        let primaryLocalModel = applyAgent(tool: p.tool, ompProvider: p.ompProvider,
                                           ompBaseURL: p.ompBaseURL,
                                           authMode: &p.authMode, apiKey: &p.apiKey)
        for i in p.additionalTools.indices {
            let tool = p.additionalTools[i].tool
            let ompProvider = p.additionalTools[i].ompProvider
            let ompBaseURL = p.additionalTools[i].ompBaseURL
            var mode = p.additionalTools[i].authMode
            var key = p.additionalTools[i].apiKey
            let lid = applyAgent(tool: tool, ompProvider: ompProvider, ompBaseURL: ompBaseURL,
                                 authMode: &mode, apiKey: &key)
            p.additionalTools[i].authMode = mode
            p.additionalTools[i].apiKey = key
            if let lid { p.additionalTools[i].localModelID = lid }
        }

        if anyLocal {
            p.modelRouting = .local
            // The one model the shared local engine serves: the primary agent's,
            // else the first local additional's.
            let localID = primaryLocalModel
                ?? p.additionalTools.first { $0.authMode == .local }?.localModelID
            if let localID { p.activeModelID = localID }
            if let lb = localServerBackend {
                p.localEngineURL = lb.url
                p.localEngineAPIKey = lb.key
            } else {
                p.localEngineURL = nil   // on-device built-in engine
                p.localEngineAPIKey = nil
            }
        } else if hasTiers {
            // A cloud tier is configured → the cloud route.
            p.modelRouting = .cloud
        }
        return p
    }

    /// The auth to apply to one cloud agent from the global credential of the
    /// provider it speaks to (omp → its configured provider; everyone else →
    /// their native provider). nil = that provider isn't registered → leave the
    /// agent's existing auth alone.
    private static func cloudAuth(tool: Tool, ompProvider: OmpProvider?,
                                  ompBaseURL: String?,
                                  settings: ModelSettings) -> (AuthMode, String?)? {
        let provider: ModelProvider = (tool == .omp)
            ? ModelProvider.from(omp: ompProvider ?? .default)
            : ModelProvider.native(for: tool)
        guard let cred = settings.credential(provider), cred.isUsable else { return nil }
        if cred.useSubscription, provider.supportsSubscription {
            return (.subscription, nil)
        }
        let key = cred.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A usable credential with no key is a custom endpoint keyed only by its
        // base URL — token mode, the guest reads whatever env the pipeline sets.
        return (.token, (key?.isEmpty == false) ? key : nil)
    }
}

public extension ModelAgent {
    /// The `ModelAgent` a profile tool maps to (1:1 today).
    static func from(_ tool: Profile.Tool) -> ModelAgent {
        switch tool {
        case .claude: return .claude
        case .codex:  return .codex
        case .grok:   return .grok
        case .kimi:   return .kimi
        case .omp:    return .omp
        }
    }
}
