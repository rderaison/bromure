import Foundation

// MARK: - Session launch plan derived from the global ModelSettings
//
// A resolved, per-session view of `ModelSettings`: for each capability tier
// (small / medium / large), which model fills it, where it's served, and how
// the wire authenticates. Pure function of `ModelSettings` — no I/O, fully
// testable — so staging (SessionDisk) and the token plan can read one coherent
// source instead of the old per-workspace model/auth fields.
//
// Every agent maps onto these tiers:
//   • Claude Code uses all three — small → ANTHROPIC_SMALL_FAST_MODEL /
//     ANTHROPIC_DEFAULT_HAIKU_MODEL, medium → ANTHROPIC_MODEL /
//     ANTHROPIC_DEFAULT_SONNET_MODEL, large → ANTHROPIC_DEFAULT_OPUS_MODEL,
//   • every single-model agent (Codex, Grok, Kimi, omp) uses `medium`.

public struct ModelLaunchPlan: Equatable, Sendable {
    /// One resolved tier: the model, where it runs, and how it's reached.
    public struct Resolved: Equatable, Sendable {
        public var modelID: String
        public var source: ModelRef.Source
        public var capabilities: ModelCapabilities
        /// The base URL the agent points at: a cloud provider host
        /// (`https://api.anthropic.com`), the user's local server URL, or the
        /// built-in engine sentinel (`https://bromure.llm`) for on-device.
        public var baseURL: String
        /// The host the MITM scopes its fake→real key swap to (a bare domain
        /// like `anthropic.com`). Empty for a local/on-device model (no swap).
        public var swapHost: String
        /// The wire dialect the endpoint speaks.
        public var wire: ModelProvider.Wire
        public var isLocal: Bool

        public init(modelID: String, source: ModelRef.Source,
                    capabilities: ModelCapabilities, baseURL: String,
                    swapHost: String, wire: ModelProvider.Wire, isLocal: Bool) {
            self.modelID = modelID
            self.source = source
            self.capabilities = capabilities
            self.baseURL = baseURL
            self.swapHost = swapHost
            self.wire = wire
            self.isLocal = isLocal
        }
    }

    public var small: Resolved?
    public var medium: Resolved?
    public var large: Resolved?

    public init(small: Resolved? = nil, medium: Resolved? = nil, large: Resolved? = nil) {
        self.small = small
        self.medium = medium
        self.large = large
    }

    /// The tier any single-model agent uses; fall back medium → large → small
    /// so a partially-configured setup still launches.
    public var primary: Resolved? { medium ?? large ?? small }

    public func resolved(_ tier: ModelTier) -> Resolved? {
        switch tier {
        case .small:  return small
        case .medium: return medium
        case .large:  return large
        }
    }

    /// Whether any tier runs on a local backend (server or on-device) — the
    /// proxy needs the engine wired up when so.
    public var usesLocal: Bool {
        [small, medium, large].contains { $0?.isLocal == true }
    }

    /// Distinct cloud swap hosts across the tiers (for token-plan scoping).
    public var swapHosts: Set<String> {
        Set([small, medium, large].compactMap { r in
            guard let r, !r.isLocal, !r.swapHost.isEmpty else { return nil }
            return r.swapHost
        })
    }
}

public extension ModelSettings {
    /// Resolve every configured tier against the registered providers / local
    /// server, using `builtInEngineBase` (the `bromure.llm` sentinel) for
    /// on-device models. A tier that can't resolve (unregistered provider, no
    /// local server) is dropped — the caller falls back via `primary`.
    func launchPlan(builtInEngineBase: String) -> ModelLaunchPlan {
        resolvePlan(builtInEngineBase: builtInEngineBase) { ref(for: $0) }
    }

    /// The launch plan for one agent, honoring its per-agent tier overrides.
    func launchPlan(for agent: ModelAgent, builtInEngineBase: String) -> ModelLaunchPlan {
        resolvePlan(builtInEngineBase: builtInEngineBase) { ref(for: agent, tier: $0) }
    }

    private func resolvePlan(builtInEngineBase: String,
                             refForTier: (ModelTier) -> ModelRef?) -> ModelLaunchPlan {
        func resolve(_ tier: ModelTier) -> ModelLaunchPlan.Resolved? {
            guard let ref = refForTier(tier),
                  let ep = endpoint(for: ref, builtInEngineBase: builtInEngineBase) else { return nil }
            return ModelLaunchPlan.Resolved(
                modelID: ref.modelID,
                source: ref.source,
                capabilities: ref.capabilities,
                baseURL: ep.base,
                swapHost: swapHost(for: ref.source),
                wire: wire(for: ref.source),
                isLocal: ref.isLocal)
        }
        return ModelLaunchPlan(small: resolve(.small),
                               medium: resolve(.medium),
                               large: resolve(.large))
    }

    /// The bare domain a cloud source's key swap is scoped to; empty for local.
    /// `.custom` derives its host from the registered base URL.
    private func swapHost(for source: ModelRef.Source) -> String {
        switch source {
        case .provider(.custom):
            let url = credential(.custom)?.baseURL ?? ""
            return URL(string: url)?.host.map(Self.baseDomain) ?? ""
        case .provider(let p):
            return Self.baseDomain(p.apiHost)
        case .localServer, .localRun:
            return ""
        }
    }

    private func wire(for source: ModelRef.Source) -> ModelProvider.Wire {
        switch source {
        case .provider(let p): return p.wire
        // The built-in engine is Anthropic-native (`/v1/messages`); a user's
        // local server is treated as OpenAI-compatible chat.
        case .localRun:    return .anthropic
        case .localServer: return .openaiChat
        }
    }

    /// `api.anthropic.com` → `anthropic.com`; leaves a two-label host as-is.
    static func baseDomain(_ host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return host }
        return parts.suffix(2).joined(separator: ".")
    }
}
