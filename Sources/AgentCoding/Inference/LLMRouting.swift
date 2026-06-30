import Foundation

/// Per-profile routing context handed to the MITM proxy: the top-level
/// routing mode plus (for hybrid) the policy engine that decides per
/// session. One instance per profile, owned by `MitmEngine`.
public final class LLMRoutingContext: @unchecked Sendable {
    public var routing: Profile.Routing
    /// Repo/id of the model the local engine serves — used in the
    /// `served-by` marker (§4.4).
    public var localModelLabel: String
    public let hybrid: HybridRouter
    /// Base domains (lowercased, e.g. `anthropic.com`) whose owning agent is
    /// itself in `.local` auth mode. A profile can mix agents — e.g. Claude on
    /// a subscription (cloud) alongside Codex on the local engine. Profile-wide
    /// `.local` routing must NOT hijack a cloud agent's real cloud traffic, so
    /// the proxy only short-circuits / reroutes a real cloud host when that
    /// host belongs to a genuinely-local agent. The local sentinel host is
    /// always engine-bound regardless (see `decide`).
    public var localCloudHosts: Set<String>

    public init(routing: Profile.Routing,
                localModelLabel: String,
                hybrid: HybridRouter,
                localCloudHosts: Set<String> = []) {
        self.routing = routing
        self.localModelLabel = localModelLabel
        self.hybrid = hybrid
        self.localCloudHosts = localCloudHosts
    }

    /// True iff `host` (or a subdomain) is a cloud provider whose agent is in
    /// `.local` auth mode in this profile.
    public func isLocalProviderHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return localCloudHosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }
}

/// The upstream a request should be sent to after routing.
public struct UpstreamTarget: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var backend: Backend
    /// Marker value for `x-bromure-served-by` / the trace (§4.4).
    public var servedBy: String

    public init(host: String, port: Int, backend: Backend, servedBy: String) {
        self.host = host
        self.port = port
        self.backend = backend
        self.servedBy = servedBy
    }
}

/// Pure routing decisions for the MITM path. No I/O — fully testable.
public enum LLMRouting {
    /// Hosts whose traffic is agent LLM traffic we can re-route. Because
    /// `vllm-mlx` is Anthropic-native (`/v1/messages`) the Anthropic path
    /// is near pass-through (Trap 3); OpenAI works via `/v1/*`.
    public static func isLLMHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "api.anthropic.com"
            || h == "api.openai.com"
            || h.hasSuffix(".api.anthropic.com")
            || h == InferenceService.localMitmHost   // the local-inference sentinel
    }

    /// Decide where to send a request to `host:port`. `sessionKey` pins a
    /// trajectory to one backend (coherence guard, Trap 2). `now` is the
    /// wall-clock seconds used by the budget window + health gate.
    public static func decide(host: String, port: Int,
                              context: LLMRoutingContext,
                              sessionKey: String,
                              localHost: String = InferenceService.engineHost,
                              // Route to the tool-call-repair proxy (which fronts the
                              // engine), not the bare engine, so local replies get
                              // leaked-tool-call rescue + SSE re-emission like before.
                              localPort: Int = InferenceService.repairProxyPort,
                              now: Double) -> UpstreamTarget {
        let cloud = UpstreamTarget(host: host, port: port,
                                   backend: .cloud, servedBy: "cloud")
        guard isLLMHost(host) else { return cloud }

        let local = UpstreamTarget(host: localHost, port: localPort, backend: .local,
                                   servedBy: "local-\(context.localModelLabel)")
        // The local sentinel host *is* "use the on-host engine" — unconditional,
        // independent of the cloud/local/hybrid mode (which steers real cloud
        // hosts). The guest only ever targets it when local was selected.
        if host.lowercased() == InferenceService.localMitmHost { return local }

        switch context.routing {
        case .cloud:
            return cloud
        case .local:
            // Reroute a real cloud host to the engine ONLY when its owning
            // agent is itself local. A subscription/token agent sharing the
            // profile with a local agent keeps its real cloud traffic — its env
            // points at the real provider, and profile-wide `.local` must not
            // hijack it into a dead local path. (Genuinely-local agents reach
            // the engine via the sentinel host, handled above.)
            return context.isLocalProviderHost(host) ? local : cloud
        case .hybrid:
            let decision = context.hybrid.route(sessionID: sessionKey, now: now)
            return decision.backend == .local ? local : cloud
        }
    }

    /// HTTP statuses that count as a hard fallback trigger under hybrid
    /// (§4.3 Trap 1): connection errors plus 429 / 529 / 5xx.
    public static func isHardErrorStatus(_ status: Int) -> Bool {
        status == 429 || status == 529 || (500...599).contains(status)
    }
}
