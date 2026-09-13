import Foundation

// MARK: - Global model configuration
//
// A single, app-wide model configuration that every agent (Claude Code, Codex,
// Grok, Kimi, omp) inherits — replacing the old per-workspace ToolSpec model/
// auth fields and the cloud/local/hybrid `Routing`. The user registers each
// provider once, wires up a local server (the recommended local route) and/or
// on-device models (the "lazy" backup), and picks a model for three capability
// TIERS — small / medium / large — which map onto each agent's model slots
// (Claude Code's haiku/sonnet/opus; the single model of every other agent).
//
// This type is intentionally self-contained (Foundation only, Codable) so it can
// be persisted globally and threaded through staging + the proxy without pulling
// in the profile graph. Wiring lives in later stages.

/// A model provider Bromure can hold credentials for. `.custom` is any
/// OpenAI-compatible endpoint the user supplies a base URL for.
public enum ModelProvider: String, Codable, CaseIterable, Sendable {
    case anthropic, openai, xai, zai, moonshot, custom

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai:    return "OpenAI"
        case .xai:       return "xAI (Grok)"
        case .zai:       return "z.ai (GLM)"
        case .moonshot:  return "Moonshot (Kimi)"
        case .custom:    return "Custom (OpenAI-compatible)"
        }
    }

    /// The upstream API host the MITM scopes a fake→real key swap to (empty for
    /// `.custom`, whose host is derived from the user's base URL).
    public var apiHost: String {
        switch self {
        case .anthropic: return "api.anthropic.com"
        case .openai:    return "api.openai.com"
        case .xai:       return "api.x.ai"
        case .zai:       return "api.z.ai"
        case .moonshot:  return "api.moonshot.ai"
        case .custom:    return ""
        }
    }

    /// The wire dialect the provider speaks — decides how the agent is pointed at
    /// it and how the proxy translates.
    public enum Wire: String, Codable, Sendable { case anthropic, openaiChat, openaiResponses }
    public var wire: Wire {
        switch self {
        case .anthropic:             return .anthropic
        case .openai:                return .openaiResponses
        case .xai, .zai, .moonshot,
             .custom:                return .openaiChat
        }
    }

    /// Whether an interactive subscription (OAuth) login can be captured for
    /// this provider (a throwaway-VM `<tool> login`, stored host-side). Anthropic
    /// (Claude), OpenAI (ChatGPT), xAI (Grok) and Moonshot (Kimi) each have a
    /// capture flow. z.ai's coding plan is delivered as an API key — no OAuth to
    /// capture — so it stays key-only; `.custom` never has one.
    public var supportsSubscription: Bool {
        switch self {
        case .anthropic, .openai, .xai, .moonshot: return true
        case .zai, .custom:                        return false
        }
    }
}

/// A coding agent whose per-tier models can be configured independently of the
/// global default. `ModelSettings.tiers` is the default that applies to every
/// agent; `ModelSettings.agentTiers[agent]` overrides it for one agent.
public enum ModelAgent: String, Codable, CaseIterable, Sendable {
    case claude, codex, grok, kimi, omp

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        case .grok:   return "Grok"
        case .kimi:   return "Kimi"
        case .omp:    return "omp"
        }
    }

    /// Only Claude Code resolves three distinct tiers (haiku/sonnet/opus). Every
    /// other agent is single-model and uses `medium` alone.
    public var usesAllTiers: Bool { self == .claude }
}

/// A registered provider credential (global). Exactly one of an API key or a
/// subscription is the active auth; a `.custom` provider also carries a baseURL.
public struct ProviderCredential: Codable, Equatable, Sendable {
    public var provider: ModelProvider
    /// Cleartext API key (extracted to the encrypted secrets vault on persist,
    /// like the old per-tool keys). Empty/nil when using a subscription.
    public var apiKey: String?
    /// Use the provider's interactive subscription (OAuth) instead of an API key.
    public var useSubscription: Bool
    /// OpenAI-compatible base URL — `.custom` only.
    public var baseURL: String?

    public init(provider: ModelProvider, apiKey: String? = nil,
                useSubscription: Bool = false, baseURL: String? = nil) {
        self.provider = provider
        self.apiKey = apiKey
        self.useSubscription = useSubscription
        self.baseURL = baseURL
    }

    /// Configured enough to use: a subscription, an API key, or (custom) a URL.
    public var isUsable: Bool {
        if useSubscription { return true }
        if let k = apiKey, !k.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if provider == .custom, let u = baseURL, !u.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        return false
    }
}

/// The recommended local route: a user-run OpenAI-compatible server
/// (vLLM / Ollama / LM Studio / …). Preferred over the built-in on-device engine.
public struct LocalServer: Codable, Equatable, Sendable {
    public var baseURL: String
    public var apiKey: String?
    public init(baseURL: String, apiKey: String? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}

/// A model's capabilities. Every field is fetched from the serving endpoint
/// (`/v1/models`, Ollama `/api/show`) when available and is user-overridable;
/// `nil` means "unknown / not yet probed", never "no".
public struct ModelCapabilities: Codable, Equatable, Sendable {
    public enum Input: String, Codable, CaseIterable, Sendable { case text, image, audio, video }

    public var contextWindow: Int?
    public var reasoning: Bool?
    public var inputs: [Input]?

    public init(contextWindow: Int? = nil, reasoning: Bool? = nil, inputs: [Input]? = nil) {
        self.contextWindow = contextWindow
        self.reasoning = reasoning
        self.inputs = inputs
    }

    /// True when at least one field is known (so the UI can show "not probed").
    public var isKnown: Bool { contextWindow != nil || reasoning != nil || inputs != nil }
    public var acceptsImages: Bool { inputs?.contains(.image) ?? false }
}

/// Where a tier's model is served from, and which model it is.
public struct ModelRef: Codable, Equatable, Sendable {
    /// The backend serving this model.
    public enum Source: Codable, Equatable, Sendable {
        case provider(ModelProvider)     // a registered cloud provider
        case localServer                 // the user's custom OpenAI-compatible server
        case localRun(catalogID: String) // an on-device model from the catalog
    }

    public var source: Source
    /// The model id as the backend names it (e.g. "claude-sonnet-4",
    /// "glm-5.3-flash", "qwen3-coder-next").
    public var modelID: String
    /// Fetched-then-editable capabilities.
    public var capabilities: ModelCapabilities
    /// True once the user has hand-edited `capabilities`, so a re-probe won't
    /// clobber their overrides.
    public var capabilitiesOverridden: Bool

    public init(source: Source, modelID: String,
                capabilities: ModelCapabilities = .init(),
                capabilitiesOverridden: Bool = false) {
        self.source = source
        self.modelID = modelID
        self.capabilities = capabilities
        self.capabilitiesOverridden = capabilitiesOverridden
    }

    public var isLocal: Bool {
        switch source { case .provider: return false; case .localServer, .localRun: return true }
    }
}

/// The three capability tiers a user assigns models to. They map onto each
/// agent's model slots: Claude Code uses all three (small→haiku/small-fast,
/// medium→sonnet, large→opus); every single-model agent uses `medium`.
public enum ModelTier: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    public var displayName: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        }
    }
    /// The Claude Code tier this maps to, for the label users recognize.
    public var claudeTierHint: String {
        switch self {
        case .small:  return "haiku"
        case .medium: return "sonnet"
        case .large:  return "opus"
        }
    }
}

/// The global, app-wide model configuration. Persisted once (not per workspace);
/// a workspace only chooses WHICH agent to run — its models + auth come from here.
public struct ModelSettings: Codable, Equatable, Sendable {
    /// Registered provider credentials, keyed by provider (at most one each).
    public var providers: [ProviderCredential]
    /// The recommended local route.
    public var localServer: LocalServer?
    /// On-device models (catalog ids) kept ready as the fallback for the lazy.
    public var localRunModels: [String]
    /// The DEFAULT model chosen for each tier — applies to every agent unless
    /// overridden in `agentTiers`. A tier may be unset (nil) until configured.
    public var tiers: [ModelTier: ModelRef]
    /// Per-agent tier overrides. `agentTiers[.codex][.medium]` wins over
    /// `tiers[.medium]` for Codex only; an unset entry inherits the default.
    public var agentTiers: [ModelAgent: [ModelTier: ModelRef]]

    public init(providers: [ProviderCredential] = [],
                localServer: LocalServer? = nil,
                localRunModels: [String] = [],
                tiers: [ModelTier: ModelRef] = [:],
                agentTiers: [ModelAgent: [ModelTier: ModelRef]] = [:]) {
        self.providers = providers
        self.localServer = localServer
        self.localRunModels = localRunModels
        self.tiers = tiers
        self.agentTiers = agentTiers
    }

    // Tolerant decoding so a `models.enc` written by an earlier build (before a
    // field existed, e.g. `agentTiers`) still loads — a missing key defaults
    // rather than throwing and wiping the user's saved settings.
    enum CodingKeys: String, CodingKey {
        case providers, localServer, localRunModels, tiers, agentTiers
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = try c.decodeIfPresent([ProviderCredential].self, forKey: .providers) ?? []
        localServer = try c.decodeIfPresent(LocalServer.self, forKey: .localServer)
        localRunModels = try c.decodeIfPresent([String].self, forKey: .localRunModels) ?? []
        tiers = try c.decodeIfPresent([ModelTier: ModelRef].self, forKey: .tiers) ?? [:]
        agentTiers = try c.decodeIfPresent([ModelAgent: [ModelTier: ModelRef]].self,
                                           forKey: .agentTiers) ?? [:]
    }

    // MARK: Lookups

    public func credential(_ provider: ModelProvider) -> ProviderCredential? {
        providers.first { $0.provider == provider }
    }
    /// The DEFAULT ref for a tier (agent-agnostic).
    public func ref(for tier: ModelTier) -> ModelRef? { tiers[tier] }

    /// The ref an agent actually uses for a tier: its own override, else the
    /// default.
    public func ref(for agent: ModelAgent, tier: ModelTier) -> ModelRef? {
        agentTiers[agent]?[tier] ?? tiers[tier]
    }

    /// The tiers an agent effectively runs with (overrides merged onto default).
    public func effectiveTiers(for agent: ModelAgent) -> [ModelTier: ModelRef] {
        var merged = tiers
        for (t, r) in agentTiers[agent] ?? [:] { merged[t] = r }
        return merged
    }

    /// The single model an agent uses (medium → large → small), honoring its
    /// per-agent overrides.
    public func primaryRef(for agent: ModelAgent) -> ModelRef? {
        ref(for: agent, tier: .medium) ?? ref(for: agent, tier: .large) ?? ref(for: agent, tier: .small)
    }

    /// The medium tier is the default any single-model agent uses; fall back to
    /// large then small so a partially-configured setup still resolves.
    public func primaryRef() -> ModelRef? {
        tiers[.medium] ?? tiers[.large] ?? tiers[.small]
    }

    /// Distinct on-device catalog ids the local engine must be able to serve —
    /// any `.localRun` tier model plus the explicit `localRunModels` list.
    public var distinctLocalRunModelIDs: [String] {
        var out = localRunModels
        let allRefs = tiers.values + agentTiers.values.flatMap { $0.values }
        for ref in allRefs {
            if case .localRun(let id) = ref.source, !out.contains(id) { out.append(id) }
        }
        return out
    }

    public var usesLocalServer: Bool {
        if localServer != nil, tiers.values.contains(where: { if case .localServer = $0.source { return true } else { return false } }) {
            return true
        }
        return false
    }

    /// The base URL + optional key that actually serves a ref, resolving the
    /// provider host / local server / built-in engine sentinel.
    public func endpoint(for ref: ModelRef, builtInEngineBase: String) -> (base: String, apiKey: String?)? {
        switch ref.source {
        case .provider(let p):
            guard let cred = credential(p), cred.isUsable else { return nil }
            let base = (p == .custom ? cred.baseURL : "https://\(p.apiHost)") ?? ""
            return base.isEmpty ? nil : (base, cred.apiKey)
        case .localServer:
            guard let s = localServer else { return nil }
            return (s.baseURL, s.apiKey)
        case .localRun:
            return (builtInEngineBase, nil)
        }
    }
}
