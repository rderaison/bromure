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
    /// projected on. Returns `self` unchanged when nothing is configured
    /// globally (pre-migration / empty), preserving legacy behavior.
    func overlaidWithGlobalModels(_ settings: ModelSettings) -> Profile {
        let hasProviders = settings.providers.contains { $0.isUsable }
        guard hasProviders || settings.primaryRef() != nil else { return self }

        var p = self

        // Local primary tier → run every agent on the local backend.
        if let primary = settings.primaryRef(), primary.isLocal {
            p.modelRouting = .local
            p.authMode = .local
            p.activeModelID = primary.modelID
            for i in p.additionalTools.indices {
                p.additionalTools[i].authMode = .local
                p.additionalTools[i].localModelID = primary.modelID
            }
            switch primary.source {
            case .localServer:
                p.localEngineURL = settings.localServer?.baseURL
                p.localEngineAPIKey = settings.localServer?.apiKey
            case .localRun:
                p.localEngineURL = nil
                p.localEngineAPIKey = nil
            case .provider:
                break
            }
            return p
        }

        // Cloud: a cloud primary tier means the cloud route; if only providers
        // are registered (no tier yet) leave routing as-is and just project keys.
        if let primary = settings.primaryRef(), !primary.isLocal {
            p.modelRouting = .cloud
        }

        // Primary agent.
        if let (mode, key) = Self.cloudAuth(tool: p.tool, ompProvider: p.ompProvider,
                                            ompBaseURL: p.ompBaseURL, settings: settings) {
            p.authMode = mode
            p.apiKey = key
        }
        // Additional agents.
        for i in p.additionalTools.indices {
            let spec = p.additionalTools[i]
            if let (mode, key) = Self.cloudAuth(tool: spec.tool, ompProvider: spec.ompProvider,
                                                ompBaseURL: spec.ompBaseURL, settings: settings) {
                p.additionalTools[i].authMode = mode
                p.additionalTools[i].apiKey = key
            }
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
