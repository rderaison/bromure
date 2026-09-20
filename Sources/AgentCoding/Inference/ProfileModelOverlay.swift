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
    /// `subscribed`: providers with a real host-side interactive login for this
    /// profile (or the shared one it inherits). Consulted so a signed-in
    /// subscription authenticates at launch even if the pane's `useSubscription`
    /// mirror flag never synced — otherwise Claude would boot and ask you to
    /// register despite being signed in.
    func overlaidWithGlobalModels(_ settings: ModelSettings,
                                  subscribed: Set<ModelProvider> = []) -> Profile {
        let hasProviders = settings.providers.contains { $0.isUsable }
        let hasTiers = !settings.tiers.isEmpty
            || settings.agentTiers.values.contains { !$0.isEmpty }
        guard hasProviders || hasTiers || !subscribed.isEmpty else { return self }

        var p = self
        var anyLocal = false
        var localServerBackend: (url: String?, key: String?)?

        // Every agent must be ENABLED, not just configured. The staging scripts
        // (api_key.env, the per-tool config files, the subscription bogus key)
        // only emit for tools present in `allToolSpecs` — so an agent missing
        // from the profile gets no credentials at all, and running e.g.
        // `claude` in a Codex workspace makes it ask you to register. Add every
        // agent to the launch copy (never persisted) so its variables propagate.
        for tool in Tool.allCases
        where tool != p.tool && !p.additionalTools.contains(where: { $0.tool == tool }) {
            p.additionalTools.append(ToolSpec(tool: tool, authMode: .token))
        }

        // Claude Code via Amazon Bedrock: the workspace's own AWS credentials
        // sign the requests (host-side), so the agent's auth is `.bedrock` and
        // the staged ~/.claude/settings.json carries the Bedrock env. Decided
        // here, applied to `p` after the per-agent pass (the pass borrows
        // `p`'s fields inout, so it can't touch `p` itself).
        var bedrock: (enabled: Bool, modelID: String)?
        // Claude Code through an Anthropic-compatible gateway (OpenRouter):
        // ANTHROPIC_BASE_URL + the gateway's model ids per tier, applied to
        // `p` after the pass for the same reason.
        var gateway: (base: String, models: [String: String])?

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
            if let ref, case .provider(.bedrock) = ref.source,
               let cred = settings.credential(.bedrock), cred.isUsable {
                let key = cred.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
                if tool == .claude {
                    // Claude Code's own Bedrock mode (CLAUDE_CODE_USE_BEDROCK):
                    // the key, if any, rides on the spec and is swapped on the
                    // wire; without one the AWS resigner signs.
                    authMode = .bedrock
                    apiKey = (key ?? "").isEmpty ? nil : key
                    bedrock = (true, ref.modelID)
                    return nil
                }
                // Every other agent: Bedrock's OpenAI-compatible surface is an
                // external engine — the guest talks to the host's repair proxy,
                // which forwards (translating the wire) and authenticates
                // host-side: the key as bearer, else SigV4 with the
                // workspace's AWS credentials.
                authMode = .local
                anyLocal = true
                let region = Bedrock.region(credential: cred, workspaceRegion: awsCredentials.region)
                localServerBackend = (Bedrock.openAIBase(region: region),
                                      (key ?? "").isEmpty ? nil : key)
                return ref.modelID
            }
            // A provider that isn't the agent's own: Claude Code goes DIRECT
            // to a gateway serving the Anthropic Messages API (OpenRouter),
            // its stand-in key swapped on that host; every other agent goes
            // through the external-engine route — the host's repair proxy
            // translates the wire and holds the key (Codex on OpenRouter,
            // Kimi on xAI…).
            if let ref, case .provider(let prov) = ref.source,
               prov != Self.nativeProvider(tool: tool, ompProvider: ompProvider),
               let cred = settings.credential(prov), cred.isUsable {
                let key = (cred.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if tool == .claude, let base = prov.anthropicGatewayBase, !key.isEmpty {
                    authMode = .token
                    apiKey = key
                    var models: [String: String] = [:]
                    for tier in ModelTier.allCases {
                        if let r = settings.ref(for: .claude, tier: tier),
                           case .provider(prov) = r.source { models[tier.rawValue] = r.modelID }
                    }
                    gateway = (base, models)
                    bedrock = (false, "")
                    return nil
                }
                if tool != .claude, let base = prov.openAICompatibleBase {
                    authMode = .local
                    anyLocal = true
                    localServerBackend = (base, key.isEmpty ? nil : key)
                    return ref.modelID
                }
            }
            if let (mode, key) = Self.cloudAuth(tool: tool, ompProvider: ompProvider,
                                                ompBaseURL: ompBaseURL, settings: settings,
                                                subscribed: subscribed) {
                authMode = mode
                apiKey = key
                // Settings moved Claude off Bedrock / a gateway: drop their env.
                if tool == .claude { bedrock = (false, ""); gateway = nil }
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
        p.claudeGatewayBaseURL = gateway?.base
        p.claudeGatewayModels = gateway?.models ?? [:]
        if let bedrock {
            p.bedrockEnabled = bedrock.enabled
            if bedrock.enabled {
                p.bedrockModelID = bedrock.modelID
                // The provider's region wins over an empty workspace region
                // (Claude Code reads AWS_REGION from the staged env).
                if p.awsCredentials.region.trimmingCharacters(in: .whitespaces).isEmpty {
                    p.awsCredentials.region = Bedrock.region(credential: settings.credential(.bedrock),
                                                             workspaceRegion: "")
                }
            }
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

    /// The agents that would start with credentials in hand — what the
    /// new-session screen labels "Ready". Same resolution as the launch
    /// overlay (a local tier for the agent, or a registered/signed-in cloud
    /// provider), plus any agent the workspace itself configured. Reading only
    /// the saved tool list is wrong now that models are global: a workspace
    /// that names Claude Code alone still runs omp on the global z.ai key.
    func agentsReadyToStart(_ settings: ModelSettings,
                            subscribed: Set<ModelProvider> = []) -> Set<Tool> {
        var ready = Set(allToolSpecs.map(\.tool))
        for tool in Tool.allCases where !ready.contains(tool) {
            let agent = ModelAgent.from(tool)
            let ref = settings.ref(for: agent, tier: .medium)
                ?? settings.ref(for: agent, tier: .large)
                ?? settings.ref(for: agent, tier: .small)
            if let ref, ref.isLocal {
                ready.insert(tool)
            } else if let ref, case .provider(.bedrock) = ref.source {
                // Bedrock: a pasted API key, else the workspace's AWS
                // credentials must exist to sign with.
                if let cred = settings.credential(.bedrock), cred.isUsable,
                   cred.bedrockUsesAPIKey || awsCredentials.isUsable {
                    ready.insert(tool)
                }
            } else if let ref, case .provider(let prov) = ref.source,
                      prov != Self.nativeProvider(tool: tool, ompProvider: ompProvider),
                      (tool == .claude ? prov.anthropicGatewayBase : prov.openAICompatibleBase) != nil {
                // A gateway / non-native provider: its key is all it takes.
                if let cred = settings.credential(prov), cred.isUsable,
                   !(cred.apiKey ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    ready.insert(tool)
                }
            } else if Self.cloudAuth(tool: tool, ompProvider: ompProvider, ompBaseURL: ompBaseURL,
                                     settings: settings, subscribed: subscribed) != nil {
                ready.insert(tool)
            }
        }
        return ready
    }

    /// The provider an agent reaches natively (omp: the one it's switched to).
    static func nativeProvider(tool: Tool, ompProvider: OmpProvider?) -> ModelProvider {
        tool == .omp ? ModelProvider.from(omp: ompProvider ?? .default) : ModelProvider.native(for: tool)
    }

    /// Whether this (launch-time) profile reaches Amazon Bedrock with AWS
    /// credentials: Claude Code's native mode, or the external-engine route
    /// pointed at a bedrock-runtime host — both need the workspace's AWS
    /// credentials resolved on the host before boot (SSO in particular).
    var usesBedrockRoute: Bool {
        if allToolSpecs.contains(where: { $0.authMode == .bedrock }) { return true }
        if let host = localEngineBaseURL?.host, Bedrock.isRuntimeHost(host) { return true }
        return false
    }

    /// The auth to apply to one cloud agent from the global credential of the
    /// provider it speaks to (omp → its configured provider; everyone else →
    /// their native provider). nil = that provider isn't registered → leave the
    /// agent's existing auth alone.
    private static func cloudAuth(tool: Tool, ompProvider: OmpProvider?,
                                  ompBaseURL: String?,
                                  settings: ModelSettings,
                                  subscribed: Set<ModelProvider>) -> (AuthMode, String?)? {
        let provider: ModelProvider = (tool == .omp)
            ? ModelProvider.from(omp: ompProvider ?? .default)
            : ModelProvider.native(for: tool)
        let cred = settings.credential(provider)
        let key = cred?.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasKey = !(key ?? "").isEmpty

        // 1. An explicitly pasted API key wins (the user chose pay-per-use).
        if hasKey, cred?.useSubscription != true { return (.token, key) }
        // 2. Otherwise a subscription — either the pane's flag or a real
        //    host-side login record for this profile — authenticates the
        //    provider's own agent.
        if provider.supportsSubscription,
           (cred?.useSubscription == true || subscribed.contains(provider)) {
            return (.subscription, nil)
        }
        // 3. A usable credential with no key is a custom endpoint keyed only by
        //    its base URL — token mode, the guest reads whatever env is set.
        if let cred, cred.isUsable { return (.token, hasKey ? key : nil) }
        return nil
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

public extension ModelProvider {
    /// The profile `Tool` whose credential + `/v1/models` endpoint can list this
    /// provider's live models (via `Fusion.listModels`). nil for providers with
    /// no matching tool (z.ai, custom) — those fall back to the static list.
    var fusionTool: Profile.Tool? {
        switch self {
        case .anthropic: return .claude
        case .openai:    return .codex
        case .xai:       return .grok
        case .moonshot:  return .kimi
        case .zai, .bedrock, .openrouter, .custom: return nil
        }
    }

    /// The agent this provider natively powers — so registering the provider can
    /// pre-fill that agent's models. nil for provider-agnostic ones (z.ai/custom,
    /// used via omp / the custom server). Bedrock is Claude Code's alternative
    /// route, so it pre-fills Claude too.
    var nativeAgent: ModelAgent? {
        switch self {
        case .anthropic, .bedrock: return .claude
        case .openai:    return .codex
        case .xai:       return .grok
        case .moonshot:  return .kimi
        case .zai, .openrouter, .custom: return nil
        }
    }
}
