import Foundation
import Yams

/// An NVIDIA OpenShell sandbox policy (schema `version: 1`), parsed, validated
/// and evaluated natively. A workspace can carry one instead of pf-style
/// `EgressPolicy` rules; `EgressPolicy.openShell` routes every enforcement point
/// (switch L4, MiTM SNI, cooperative proxy, per-request L7) through it.
///
/// Semantics follow OpenShell's `sandbox-policy.rego` and its schema reference:
/// rules are NOT an ordered firewall list. A connection is allowed when any
/// rule's endpoint matches it (default deny); a request on an inspected
/// endpoint is allowed when some matching endpoint's allow rules (or access
/// preset) permit it and no matching endpoint's deny rule matches it.
///
/// What Bromure enforces vs. accepts-and-reports (`warnings`):
///  - enforced: `network_policies` endpoints (host / port(s) / allowed_ips /
///    path selector / tls: skip), the loopback / link-local / private-address /
///    control-plane-port blocks, REST inspection (presets, allow + deny rules,
///    query matchers, audit vs enforce, path canonicalization), and the
///    WebSocket upgrade request.
///  - `binaries`: enforced under strict sandbox (root attestor), advisory
///    otherwise.
///  - `filesystem_policy` / `landlock` / `process`: enforced inside the VM by
///    the guest's root launcher (Landlock, privilege drop, OpenShell's seccomp
///    filters) from the staged `OpenShellSandboxSpec`; each only when present.
///  - accepted, not enforced: credential rewrite / signing fields (Bromure
///    injects credentials itself); external (non-built-in) middlewares run
///    their `on_error` policy.
public struct OpenShellPolicy: Sendable, Equatable {

    // MARK: Model

    public enum L7Protocol: String, Sendable, Equatable {
        case rest, websocket, graphql, mcp, jsonRPC = "json-rpc", tcp
        /// Request inspection applies (every protocol except native `tcp`).
        public var inspects: Bool { self != .tcp }
    }

    public enum Enforcement: String, Sendable, Equatable { case enforce, audit }

    public enum AccessPreset: String, Sendable, Equatable {
        case readOnly = "read-only", readWrite = "read-write", full

        /// Methods a preset grants on REST (and, for the upgrade, WebSocket).
        var restMethods: [String] {
            switch self {
            case .readOnly:  return ["GET", "HEAD", "OPTIONS"]
            case .readWrite: return ["GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH"]
            case .full:      return ["*"]
            }
        }
    }

    /// A query-parameter matcher: one glob, or `{ any: [globs] }`.
    public struct QueryMatcher: Sendable, Equatable {
        public var globs: [String]
        func matches(_ value: String) -> Bool {
            globs.contains { RegoGlob.match($0, delimiters: [], value) }
        }
    }

    /// One REST/WebSocket matcher (the body of an `allow:` or a deny rule).
    public struct RequestMatcher: Sendable, Equatable {
        public var method: String
        public var path: String
        public var query: [String: QueryMatcher]
    }

    public struct IPv4Range: Sendable, Equatable {
        public var net: UInt32
        public var mask: UInt32
        public func contains(_ ip: UInt32) -> Bool { (ip & mask) == (net & mask) }
        public func overlaps(_ o: IPv4Range) -> Bool {
            let m = mask & o.mask
            return (net & m) == (o.net & m)
        }
    }

    public struct Endpoint: Sendable, Equatable {
        public var host: String?                 // lowercased; nil = hostless (allowed_ips)
        public var ports: [UInt16]
        public var path: String?                 // endpoint path selector
        public var allowedIPs: [IPv4Range]
        public var l7: L7Protocol?
        public var tlsSkip: Bool
        public var enforcement: Enforcement
        public var access: AccessPreset?
        public var rules: [RequestMatcher]
        public var denyRules: [RequestMatcher]
        public var allowEncodedSlash: Bool
        /// Bromure-generated (provider layer / infrastructure): exempt from the
        /// control-plane-port block, never user-authored.
        public var managed: Bool = false

        // MCP / JSON-RPC (`protocol: mcp` / `json-rpc`).
        public var rpcRules: [RPCMatcher] = []
        public var rpcDenyRules: [RPCMatcher] = []
        public var mcp: MCPOptions = MCPOptions()
        public var jsonRPCMaxBody: Int = 65_536
        // GraphQL (`protocol: graphql`).
        public var gqlRules: [GraphQLMatcher] = []
        public var gqlDenyRules: [GraphQLMatcher] = []
        public var graphqlMaxBody: Int = 65_536
        public var persistedQueriesAllowRegistered: Bool = false
        public var graphqlRegistry: [String: GraphQLOperation] = [:]
        /// Raw metadata OpenShell's ambiguity check compares.
        public var ambiguity = AmbiguityKeys()

        public init(host: String?, ports: [UInt16], path: String?, allowedIPs: [IPv4Range],
                    l7: L7Protocol?, tlsSkip: Bool, enforcement: Enforcement, access: AccessPreset?,
                    rules: [RequestMatcher], denyRules: [RequestMatcher], allowEncodedSlash: Bool,
                    managed: Bool = false) {
            self.host = host; self.ports = ports; self.path = path; self.allowedIPs = allowedIPs
            self.l7 = l7; self.tlsSkip = tlsSkip; self.enforcement = enforcement; self.access = access
            self.rules = rules; self.denyRules = denyRules; self.allowEncodedSlash = allowEncodedSlash
            self.managed = managed
        }

        var isWildcard: Bool { host?.contains("*") ?? false }

        /// Host + port match (rego `endpoint_matches_request`).
        public func matches(host h: String?, port: UInt16) -> Bool {
            guard ports.contains(port) else { return false }
            guard let host else { return !allowedIPs.isEmpty || !ambiguity.allowedIPsRaw.isEmpty }   // hostless
            guard let h else { return false }
            let lh = h.lowercased()
            if host.contains("*") { return RegoGlob.match(host.lowercased(), delimiters: ["."], lh) }
            return host == lh
        }

        /// The endpoint `path` selector (schema: empty / `**` / `/**` match
        /// everything; `/v1/**` also matches `/v1`; elsewhere `*` spans `/`).
        func selects(path p: String) -> Bool {
            guard let path, !path.isEmpty, path != "**", path != "/**" else { return true }
            if path == p { return true }
            if path.hasSuffix("/**") {
                // `/v1/**` matches `/v1` itself and everything below it; the
                // prefix is literal (openshell-core endpoint_path.rs).
                let base = String(path.dropLast(3))
                return p == base || (p.hasPrefix(base) && p.dropFirst(base.count).hasPrefix("/"))
            }
            return Glob.match(path, p, separator: nil, caseInsensitive: false)
        }

        /// Effective allow matchers: explicit rules, or the access preset
        /// expanded over every path.
        public var allowMatchers: [RequestMatcher] {
            if let access {
                // l7/mod.rs `access_preset_rules`: WebSocket read-only = the
                // upgrade only, read-write adds client text; `full` is `*`.
                let methods = access == .full ? ["*"]
                    : l7 == .websocket ? (access == .readOnly ? ["GET"] : ["GET", "WEBSOCKET_TEXT"])
                    : access.restMethods
                return methods.map { RequestMatcher(method: $0, path: "**", query: [:]) }
            }
            return rules
        }
    }

    /// An MCP / JSON-RPC matcher: a method (exact, `*` for JSON-RPC, or a
    /// `tools/` glob for MCP) and, for MCP `tools/call`, a tool-name matcher.
    public struct RPCMatcher: Sendable, Equatable {
        public var method: String?
        public var tool: [String]?
    }

    public struct MCPOptions: Sendable, Equatable {
        public var versions: [String] = ["2025-11-25"]
        public var maxBody: Int = 65_536
        public var strictToolNames: Bool = true
        public var allowAllKnown: Bool = false
        public init() {}
    }

    /// A GraphQL allow / deny matcher.
    public struct GraphQLMatcher: Sendable, Equatable {
        public var operationType: String          // query / mutation / subscription
        public var operationName: String?         // glob
        public var fields: [String]?              // top-level field globs
    }

    /// One GraphQL operation: from a parsed document or a persisted-query registry.
    public struct GraphQLOperation: Sendable, Equatable {
        public var type: String
        public var name: String?
        public var fields: [String]
    }

    /// Which executable opened a connection, as the guest's root attestor
    /// reports it from kernel state: the executable's real path and sha256,
    /// and its parent chain (nearest first).
    public struct BinaryIdentity: Sendable, Equatable {
        public struct Link: Sendable, Equatable {
            public var exe: String
            public var sha256: String
            public init(exe: String, sha256: String) { self.exe = exe; self.sha256 = sha256 }
        }
        public var exe: String
        public var sha256: String
        public var ancestors: [Link]
        public init(exe: String, sha256: String, ancestors: [Link]) {
            self.exe = exe; self.sha256 = sha256; self.ancestors = ancestors
        }
        /// Every executable that counts for a rule: the opener, then its parents.
        public var chain: [String] { [exe] + ancestors.map(\.exe) }
    }

    public struct NetworkRule: Sendable, Equatable {
        public var key: String
        public var name: String
        public var endpoints: [Endpoint]
        public var binaries: [String]

        public init(key: String, name: String, endpoints: [Endpoint], binaries: [String]) {
            self.key = key; self.name = name; self.endpoints = endpoints; self.binaries = binaries
        }

        /// A Bromure-composed rule (provider layer): applies to every binary.
        public var isManaged: Bool { !endpoints.isEmpty && endpoints.allSatisfy(\.managed) }

        /// OpenShell `binary_allowed`: with binary identity enforced, a rule
        /// applies only to connections opened by one of its `binaries` (exact
        /// path or `/`-separated glob) or by a process one of them started.
        /// An empty list matches no binary. Without enforcement every rule
        /// applies (identity is advisory).
        public func applies(to identity: BinaryIdentity?, enforce: Bool) -> Bool {
            guard enforce, !isManaged else { return true }
            guard let identity, !binaries.isEmpty else { return false }
            let chain = identity.chain
            return binaries.contains { b in
                b.contains("*")
                    ? chain.contains { RegoGlob.match(b, delimiters: ["/"], $0) }
                    : chain.contains(b)
            }
        }
    }

    public var networkPolicies: [NetworkRule]
    /// The YAML this policy was parsed from — the canonical, round-trippable
    /// form (exported verbatim; OpenShell's own tools read it unchanged).
    public var source: String
    /// Sections / fields that parsed and validated but aren't enforced by
    /// Bromure, one human-readable line each (shown in the editor).
    public var warnings: [String]
    /// `network_middlewares`, in run order.
    public var middlewares: [Middleware] = []
    /// `filesystem_policy`, `process`, `landlock` — enforced in the guest from
    /// the verbatim sections (`OpenShellSandboxSpec`); parsed here for
    /// validation, warnings and boundary checks.
    public var filesystem: Filesystem?
    public var runAsUser: String?
    public var runAsGroup: String?
    public var landlockHardRequirement: Bool?

    public struct Filesystem: Sendable, Equatable {
        public var includeWorkdir: Bool
        public var readOnly: [String]
        public var readWrite: [String]
    }

    /// A `network_middlewares` entry. `openshell/regex` is built in; any other
    /// name is an external middleware service, which Bromure can't reach —
    /// traffic it selects follows `on_error` (blocked unless `fail_open`).
    public struct Middleware: Sendable, Equatable {
        public var key: String
        public var name: String
        public var kind: String
        public var include: [String]
        public var exclude: [String]
        public var order: Int
        public var failOpen: Bool

        public var isBuiltinRegex: Bool { kind == "openshell/regex" }

        public func selects(host: String) -> Bool {
            let h = host.lowercased()
            func hit(_ p: String) -> Bool {
                p.contains("*") ? Glob.match(p, h, separator: ".", caseInsensitive: true) : p == h
            }
            return include.contains(where: hit) && !exclude.contains(where: hit)
        }
    }

    /// The middleware chain for traffic to `host`, in order.
    public func middlewares(for host: String) -> [Middleware] {
        middlewares.filter { $0.selects(host: host) }
    }

    /// `openshell/regex`: OpenShell's built-in demonstration redactor — the
    /// fixed `sk-…` pattern replaced with `[REDACTED]` in UTF-8 bodies up to
    /// 256 KiB. Returns the rewritten text and the match count, or nil when
    /// nothing matched (or the body isn't eligible).
    public enum MiddlewareOutcome: Equatable, Sendable {
        case unchanged
        case rewritten(Data, count: Int)
        /// The middleware couldn't run; the entry's `on_error` decides.
        case failed(String)
    }

    /// The built-in `openshell/regex` middleware as OpenShell's chain runs
    /// it: a body over the 256 KiB binding capacity or not UTF-8 is a
    /// middleware failure (`on_error` applies), otherwise every `sk-…`
    /// token not kept by `keep` becomes `[REDACTED]`.
    public static let regexMiddlewareCapacity = 256 * 1024
    public static func regexMiddleware(_ body: Data, keep: (String) -> Bool = { _ in false }) -> MiddlewareOutcome {
        guard body.count <= regexMiddlewareCapacity else { return .failed("request_body_over_capacity") }
        guard String(data: body, encoding: .utf8) != nil else { return .failed("openshell/regex requires UTF-8 request bodies") }
        guard let (out, n) = regexRedact(body, keep: keep) else { return .unchanged }
        return .rewritten(out, count: n)
    }

    public static func regexRedact(_ body: Data, keep: (String) -> Bool = { _ in false }) -> (Data, Int)? {
        guard body.count <= 256 * 1024, let text = String(data: body, encoding: .utf8) else { return nil }
        let re = try! NSRegularExpression(pattern: "sk-[A-Za-z0-9_-]{16,}")
        var out = text
        var count = 0
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let r = Range(m.range, in: out), !keep(String(out[r])) else { continue }
            out.replaceSubrange(r, with: "[REDACTED]")
            count += 1
        }
        return count > 0 ? (Data(out.utf8), count) : nil
    }

    public init(networkPolicies: [NetworkRule], source: String, warnings: [String]) {
        self.networkPolicies = networkPolicies
        self.source = source
        self.warnings = warnings
    }

    // MARK: - Connection-layer evaluation

    public enum ConnectDecision: Sendable, Equatable {
        case deny(reason: String)
        /// `inspect`: some matching endpoint inspects requests (force MiTM).
        /// `tlsSkip`: a matching endpoint relays without terminating TLS.
        case allow(rule: String, inspect: Bool, tlsSkip: Bool)
    }

    /// Always-blocked destinations: loopback, link-local (incl. the cloud
    /// metadata address) and unspecified.
    public static let blockedRanges: [IPv4Range] = [
        cidr(127, 0, 0, 0, 8), cidr(169, 254, 0, 0, 16), cidr(0, 0, 0, 0, 8),
    ]
    /// Private ranges — reachable only from an exact-hostname endpoint or
    /// through `allowed_ips` (SSRF guard).
    public static let privateRanges: [IPv4Range] = [
        cidr(10, 0, 0, 0, 8), cidr(172, 16, 0, 0, 12), cidr(192, 168, 0, 0, 16),
        cidr(100, 64, 0, 0, 10),
    ]
    /// Kubernetes / etcd control-plane ports, blocked on exact-host, IP and
    /// allowed_ips endpoints.
    static let controlPlanePorts: Set<UInt16> = [2379, 2380, 6443, 10250, 10255]

    /// Decide a new outbound TCP connection. `hostnames` are every name known
    /// for the destination (SNI, Host header, or DNS-snooped); `ip` is the
    /// destination address when known. Any hostname that yields an allow wins.
    public func evaluateConnect(hostnames: [String], ip: UInt32?, port: UInt16,
                                identity: BinaryIdentity? = nil, enforceBinaries: Bool = false) -> ConnectDecision {
        if enforceBinaries {
            var scoped = self
            scoped.networkPolicies = networkPolicies.filter { $0.applies(to: identity, enforce: true) }
            let d = scoped.evaluateConnect(hostnames: hostnames, ip: ip, port: port)
            if case .deny(let r) = d, identity == nil {
                return .deny(reason: r + " (no attested binary identity)")
            } else if case .deny(let r) = d, let identity {
                return .deny(reason: r + " for \(identity.exe)")
            }
            return d
        }
        var lastReason = "no matching network policy for port \(port)"
        // Names first, then the bare address (IP-literal and hostless
        // `allowed_ips` endpoints match on it).
        var candidates: [String?] = hostnames.map { Optional($0) }
        candidates.append(ip.map(EgressPolicy.ipv4String))
        for host in candidates {
            switch evaluateConnect(host: host, ip: ip, port: port) {
            case .allow(let r, let i, let t): return .allow(rule: r, inspect: i, tlsSkip: t)
            case .deny(let reason): lastReason = reason
            }
        }
        return .deny(reason: lastReason)
    }

    private func evaluateConnect(host: String?, ip: UInt32?, port: UInt16) -> ConnectDecision {
        // Policy match (rego `allow_network`): host + port (binaries were
        // scoped by the caller). Addresses play no part here…
        var matched: [(rule: String, ep: Endpoint)] = []
        for rule in networkPolicies {
            for ep in rule.endpoints where ep.matches(host: host, port: port) {
                matched.append((rule.key, ep))
            }
        }
        let label = host ?? ip.map(EgressPolicy.ipv4String) ?? "?"
        guard !matched.isEmpty else {
            return .deny(reason: "no network policy allows \(label):\(port)")
        }
        // …they're validated afterwards against the route's address
        // authorization (OpenShell's destination plan). Unknown address (the
        // cooperative proxy, before it resolves): the proxy validates what it
        // resolves before dialing. Bromure-managed provider endpoints are
        // Bromure's own destinations and skip this.
        if let ip, !matched.contains(where: { $0.ep.managed }) {
            let target = host ?? EgressPolicy.ipv4String(ip)
            let verdict = destinationPlan(host: target, port: port)
                .flatMap { Self.validateDestination($0, host: target, port: port, resolved: [.v4(ip)]) }
            if case .failure(let denial) = verdict { return .deny(reason: denial.reason) }
        }
        let rule = matched.map(\.rule).min() ?? matched[0].rule
        return .allow(rule: rule,
                      inspect: matched.contains { $0.ep.l7?.inspects ?? false },
                      tlsSkip: matched.contains { $0.ep.tlsSkip })
    }

    // MARK: - Request-layer (L7) evaluation

    public enum RequestDecision: Sendable, Equatable {
        case allow
        /// The request breaks the policy. `enforced` false = audit mode: log
        /// the violation and let the request through.
        case violation(reason: String, rule: String?, enforced: Bool)
    }

    /// Decide one HTTP request on a connection to `host:port`. Endpoints
    /// without a request protocol add no request access; when no matching
    /// endpoint inspects, every request passes. Each inspected endpoint judges
    /// the request by its own protocol (REST / WebSocket upgrade: method, path,
    /// query; MCP / JSON-RPC: the JSON-RPC messages in the body; GraphQL: the
    /// operations); a matching deny wins over any allow, and any allow grants.
    /// `headers` are lowercased names; `body` is what was buffered.
    public func evaluateRequest(host: String, port: UInt16, method: String, target: String,
                                headers: [String: String] = [:], body: Data? = nil,
                                bodyComplete: Bool = true,
                                identity: BinaryIdentity? = nil, enforceBinaries: Bool = false) -> RequestDecision {
        if enforceBinaries {
            var scoped = self
            scoped.networkPolicies = networkPolicies.filter { $0.applies(to: identity, enforce: true) }
            return scoped.evaluateRequest(host: host, port: port, method: method, target: target,
                                          headers: headers, body: body, bodyComplete: bodyComplete)
        }
        var matching: [(rule: String, ep: Endpoint)] = []
        for rule in networkPolicies {
            for ep in rule.endpoints where ep.matches(host: host, port: port) {
                matching.append((rule.key, ep))
            }
        }
        // As OpenShell's relay routes it: once any endpoint on this host:port
        // inspects requests, every request is canonicalized and routed to the
        // most specific inspecting endpoint whose path selector matches — none
        // is a denial. Without one, requests pass uninspected.
        let routes = matching.filter { $0.ep.l7?.inspects ?? false }
        guard !routes.isEmpty else { return .allow }

        let allowSlash = matching.contains { $0.ep.allowEncodedSlash && ($0.ep.l7?.inspects ?? false) }
        let canonical: (path: String, query: [String: [String]])
        switch Self.canonicalize(target: target, allowEncodedSlash: allowSlash) {
        case .success(let c): canonical = c
        case .failure(let e):
            // Malformed / ambiguous targets are rejected even under audit.
            return .violation(reason: "\(method) rejected: \(e.message)", rule: nil, enforced: true)
        }

        // Ties: OpenShell iterates policies in Rego's key order (sorted by
        // name, endpoints in authored order) and `max_by_key` keeps the last.
        let ordered = routes.enumerated().sorted {
            ($0.element.rule.utf8.lexicographicallyPrecedes($1.element.rule.utf8))
                || ($0.element.rule == $1.element.rule && $0.offset < $1.offset)
        }.map(\.element)
        guard let primary = ordered.filter({ $0.ep.selects(path: canonical.path) })
            .reduce(nil as (rule: String, ep: Endpoint)?, { best, e in
                guard let b = best else { return e }
                return specificity(e.ep.path) >= specificity(b.ep.path) ? e : b
            }) else {
            return .violation(reason: "\(method.uppercased()) \(canonical.path): no L7 endpoint path matched request",
                              rule: routes[0].rule, enforced: true)
        }
        if !primary.ep.allowEncodedSlash, allowSlash, canonical.path.contains("%2F") {
            return .violation(reason: "\(method.uppercased()) rejected: encoded '/' is not allowed on this endpoint",
                              rule: primary.rule, enforced: true)
        }
        // Rego re-matches endpoints by `path` with glob.match (rego
        // `endpoint_path_matches_request`), which — unlike the route selector
        // above — does not let `/v1/**` match `/v1` itself.
        let inspected = matching.filter { m in
            guard m.ep.l7?.inspects ?? false else { return false }
            guard let p = m.ep.path, !p.isEmpty else { return true }
            return Self.pathMatches(canonical.path, p)
        }
        let enforced = primary.ep.enforcement == .enforce
        let request = L7Request(method: method.uppercased(), path: canonical.path, query: canonical.query,
                                headers: headers, body: body, bodyComplete: bodyComplete)

        if primary.ep.l7 == .mcp {
            return evaluateMCPRequest(request, primary: primary, inspected: inspected, enforced: enforced)
        }

        var firstDeny: (String, String)?
        var granted = false
        var reasons: [String] = []
        for (rule, ep) in inspected where Self.sharesParse(ep, primary.ep) {
            switch evaluate(request, on: ep) {
            case .allow: granted = true
            case .deny(let why): if firstDeny == nil { firstDeny = (why, rule) }
            case .hardDeny(let why): return .violation(reason: why, rule: rule, enforced: true)
            case .notPermitted(let why): if let why { reasons.append(why) }
            }
        }
        if let (why, rule) = firstDeny { return .violation(reason: why, rule: rule, enforced: enforced) }
        if granted { return .allow }
        return .violation(reason: reasons.first ?? "\(request.method) \(request.path) not permitted by policy",
                          rule: primary.rule, enforced: enforced)
    }

    /// An MCP-routed request: transport inspection under the primary endpoint's
    /// options, then every policy unit (a call, or the whole request) must be
    /// allowed by some endpoint and denied by none.
    private func evaluateMCPRequest(_ request: L7Request, primary: (rule: String, ep: Endpoint),
                                    inspected: [(rule: String, ep: Endpoint)], enforced: Bool) -> RequestDecision {
        let info: MCPInfo
        switch mcpTransportInspect(request, primary.ep) {
        case .failure(let rejection):
            return .violation(reason: rejection.reason, rule: primary.rule, enforced: true)
        case .success(let i): info = i
        }
        for unit in Self.mcpUnits(info) {
            let what = unit.call.map { "MCP \($0.method)\($0.tool.map { " \($0)" } ?? "")" }
                ?? "\(request.method) \(request.path)"
            var allowed = false
            for (rule, ep) in inspected {
                if ep.l7 == .mcp {
                    if mcpDenies(unit, httpMethod: request.method, on: ep) {
                        return .violation(reason: "\(what) blocked by deny rule", rule: rule, enforced: enforced)
                    }
                    if mcpAllows(unit, httpMethod: request.method, on: ep) { allowed = true }
                } else if Self.sharesParse(ep, primary.ep) {
                    switch evaluate(request, on: ep) {
                    case .allow: allowed = true
                    case .deny(let why): return .violation(reason: why, rule: rule, enforced: enforced)
                    case .hardDeny(let why): return .violation(reason: why, rule: rule, enforced: true)
                    case .notPermitted: break
                    }
                }
            }
            if !allowed {
                return .violation(reason: "\(what) not permitted by policy", rule: primary.rule, enforced: enforced)
            }
        }
        return .allow
    }

    /// OpenShell's route for a request on `host:port`: the most specific
    /// inspecting endpoint whose path selector matches (ties: last in policy
    /// name order), and every inspecting endpoint Rego then evaluates. nil
    /// when no endpoint inspects, the target doesn't canonicalize, or no
    /// selector matches.
    struct Route {
        let primary: Endpoint
        let inspected: [Endpoint]
        let path: String
        let query: [String: [String]]
    }

    /// Whether a request to `target` routes to a `protocol: websocket` endpoint.
    public func routesToWebSocket(host: String, port: UInt16, target: String) -> Bool {
        routedEndpoint(host: host, port: port, target: target)?.primary.l7 == .websocket
    }

    func routedEndpoint(host: String, port: UInt16, target: String) -> Route? {
        var matching: [(rule: String, ep: Endpoint)] = []
        for rule in networkPolicies {
            for ep in rule.endpoints where ep.matches(host: host, port: port) { matching.append((rule.key, ep)) }
        }
        let routes = matching.filter { $0.ep.l7?.inspects ?? false }
        guard !routes.isEmpty else { return nil }
        let allowSlash = routes.contains { $0.ep.allowEncodedSlash }
        guard case .success(let c) = Self.canonicalize(target: target, allowEncodedSlash: allowSlash) else { return nil }
        let ordered = routes.enumerated().sorted {
            ($0.element.rule.utf8.lexicographicallyPrecedes($1.element.rule.utf8))
                || ($0.element.rule == $1.element.rule && $0.offset < $1.offset)
        }.map(\.element)
        guard let primary = ordered.filter({ $0.ep.selects(path: c.path) })
            .reduce(nil as (rule: String, ep: Endpoint)?, { best, e in
                guard let b = best else { return e }
                return specificity(e.ep.path) >= specificity(b.ep.path) ? e : b
            }) else { return nil }
        let inspected = routes.filter { m in
            guard let p = m.ep.path, !p.isEmpty else { return true }
            return Self.pathMatches(c.path, p)
        }.map(\.ep)
        return Route(primary: primary.ep, inspected: inspected, path: c.path, query: c.query)
    }

    /// One request as the L7 inspectors see it (canonicalized).
    struct L7Request {
        let method: String
        let path: String
        let query: [String: [String]]
        let headers: [String: String]
        let body: Data?
        /// false: the body was too large to buffer (`body` is a prefix).
        var bodyComplete: Bool = true
    }

    /// `hardDeny`: the request isn't a valid message for the protocol at all
    /// (a JSON-RPC response frame sent as a request, unparseable JSON…) —
    /// refused even in audit mode, as OpenShell's relay does.
    enum EndpointVerdict { case allow, deny(String), hardDeny(String), notPermitted(String?) }

    func evaluate(_ r: L7Request, on ep: Endpoint) -> EndpointVerdict {
        switch ep.l7 {
        case .rest?, .websocket?:
            let desc = "\(r.method) \(r.path)"
            if ep.denyRules.contains(where: { Self.denyMatches($0, method: r.method, path: r.path, query: r.query) }) {
                return .deny("\(desc) blocked by deny rule")
            }
            return ep.allowMatchers.contains(where: { Self.allowMatches($0, method: r.method, path: r.path, query: r.query) })
                ? .allow : .notPermitted(nil)
        case .mcp?:
            switch mcpTransportInspect(r, ep) {
            case .failure(let rej): return .deny(rej.reason)
            case .success(let info):
                for u in Self.mcpUnits(info) {
                    if mcpDenies(u, httpMethod: r.method, on: ep) { return .deny("MCP request blocked by deny rule") }
                    if !mcpAllows(u, httpMethod: r.method, on: ep) { return .notPermitted(nil) }
                }
                return .allow
            }
        case .jsonRPC?: return evaluateJSONRPC(r, ep)
        case .graphql?: return evaluateGraphQL(r, ep)
        case .tcp?, nil: return .notPermitted(nil)
        }
    }

    /// OpenShell parses a body only for the routed endpoint's protocol; the
    /// policy engine sees no JSON-RPC / GraphQL view otherwise, so such rules
    /// on other endpoints neither allow nor deny. REST / WebSocket rules match
    /// on method + path alone and always apply.
    static func sharesParse(_ ep: Endpoint, _ primary: Endpoint) -> Bool {
        switch ep.l7 {
        case .graphql?, .jsonRPC?, .mcp?: return ep.l7 == primary.l7
        default: return true
        }
    }

    private func specificity(_ path: String?) -> Int {
        (path ?? "").filter { $0 != "*" }.count
    }

    static func methodMatches(_ actual: String, _ expected: String) -> Bool {
        let e = expected.uppercased()
        if e == "*" { return true }
        if actual == e { return true }
        return actual == "HEAD" && e == "GET"
    }

    static func pathMatches(_ path: String, _ pattern: String) -> Bool {
        pattern == "**" || RegoGlob.match(pattern, delimiters: ["/"], path)
    }

    /// Allow side: every configured key must be present and ALL its values match.
    static func allowMatches(_ r: RequestMatcher, method: String, path: String,
                             query: [String: [String]]) -> Bool {
        guard methodMatches(method, r.method), pathMatches(path, r.path) else { return false }
        for (key, matcher) in r.query {
            guard let values = query[key], !values.isEmpty,
                  values.allSatisfy(matcher.matches) else { return false }
        }
        return true
    }

    /// Deny side: every configured key must be present and ONE value match.
    static func denyMatches(_ r: RequestMatcher, method: String, path: String,
                            query: [String: [String]]) -> Bool {
        guard methodMatches(method, r.method), pathMatches(path, r.path) else { return false }
        for (key, matcher) in r.query {
            guard let values = query[key], values.contains(where: matcher.matches) else { return false }
        }
        return true
    }

    // MARK: - Path canonicalization

    /// The canonical path of a request target (nil when OpenShell's parser
    /// would reject it). For callers outside the evaluator, e.g. credential
    /// path binding.
    public static func canonicalPath(ofTarget target: String, allowEncodedSlash: Bool = true) -> String? {
        if case .success(let c) = canonicalize(target: target, allowEncodedSlash: allowEncodedSlash) { return c.path }
        return nil
    }

    /// The request-target OpenShell forwards for `target` on an inspected
    /// route: the canonical path plus the raw query, so the upstream serves
    /// exactly the path the policy evaluated. nil when no endpoint on
    /// `host:port` inspects requests (the target is forwarded untouched) or the
    /// target doesn't canonicalize (`evaluateRequest` refuses those).
    public func canonicalRequestTarget(host: String, port: UInt16, target: String) -> String? {
        let routes = networkPolicies.flatMap(\.endpoints)
            .filter { $0.matches(host: host, port: port) && ($0.l7?.inspects ?? false) }
        guard !routes.isEmpty else { return nil }
        let allowSlash = routes.contains(where: \.allowEncodedSlash)
        guard case .success(let c) = Self.canonicalize(target: target, allowEncodedSlash: allowSlash) else { return nil }
        let query = target.firstIndex(of: "?").map { String(target[$0...]) } ?? ""
        return c.path + query
    }

    /// Whether an endpoint `path` selector matches a canonical path.
    public static func pathSelector(_ selector: String, matches path: String) -> Bool {
        Endpoint(host: nil, ports: [], path: selector, allowedIPs: [], l7: nil, tlsSkip: false,
                 enforcement: .audit, access: nil, rules: [], denyRules: [], allowEncodedSlash: false)
            .selects(path: path)
    }

    public struct CanonicalizeError: Error, Equatable { public let message: String }

    /// Canonicalize a request target exactly as OpenShell's L7 boundary does
    /// (port of openshell-supervisor-network `l7/path.rs`
    /// `canonicalize_request_target`, default options, plus
    /// `rest::parse_query_params`): reject control / non-ASCII bytes and
    /// fragments; take the path of an absolute-form target; percent-decode
    /// (`%2F` kept as an in-segment sentinel only when allowed); strip
    /// `;params` before resolving dot segments; re-encode everything outside
    /// RFC 3986 pchar with upper-case hex.
    static func canonicalize(target: String, allowEncodedSlash: Bool)
        -> Result<(path: String, query: [String: [String]]), CanonicalizeError> {
        func fail(_ m: String) -> Result<(path: String, query: [String: [String]]), CanonicalizeError> {
            .failure(CanonicalizeError(message: m))
        }
        for b in target.utf8 {
            if b < 0x20 || b == 0x7F { return fail("request-target contains a null or control byte") }
            if b >= 0x80 { return fail("request-target contains raw non-ASCII bytes; non-ASCII must be percent-encoded") }
        }
        if target.contains("#") { return fail("request-target contains a fragment") }
        let pathPart: Substring, queryPart: Substring?
        if let q = target.firstIndex(of: "?") {
            pathPart = target[..<q]; queryPart = target[target.index(after: q)...]
        } else {
            pathPart = target[...]; queryPart = nil
        }

        // Absolute-form (`scheme://authority/path`): its path, or `/`.
        var rawPath = String(pathPart)
        if let m = pathPart.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) {
            let rest = pathPart[m.upperBound...]
            rawPath = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/"
        }
        if rawPath.isEmpty { rawPath = "/" }
        guard rawPath.hasPrefix("/") else { return fail("request-target is not a valid origin-form path") }
        guard rawPath.utf8.count <= 4096 else { return fail("request-target exceeds the configured maximum length") }

        // Percent-decode; an allowed %2F becomes the in-segment sentinel 0x01.
        let sentinel: UInt8 = 0x01
        let raw = Array(rawPath.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(raw.count)
        var i = 0
        while i < raw.count {
            let b = raw[i]
            if b == sentinel { return fail("request-target contains a null or control byte") }
            guard b == UInt8(ascii: "%") else { decoded.append(b); i += 1; continue }
            guard i + 2 < raw.count, let hi = hexNibble(raw[i + 1]), let lo = hexNibble(raw[i + 2]) else {
                return fail("request-target contains an invalid percent-encoded sequence")
            }
            let d = hi << 4 | lo
            if d == UInt8(ascii: "/") {
                guard allowEncodedSlash else {
                    return fail("request-target contains an encoded '/' (%2F) which is not allowed on this endpoint")
                }
                decoded.append(sentinel)
            } else if d < 0x20 || d == 0x7F {
                return fail("request-target contains a null or control byte")
            } else {
                decoded.append(d)
            }
            i += 3
        }

        // Segments, `;params` stripped, dot segments resolved.
        let segments = decoded.dropFirst().split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
            .map { seg -> [UInt8] in Array(seg.firstIndex(of: UInt8(ascii: ";")).map { seg[..<$0] } ?? seg) }
        var stack: [[UInt8]] = []
        let last = segments.count - 1
        for (idx, seg) in segments.enumerated() {
            if seg == Array("..".utf8) {
                guard stack.popLast() != nil else { return fail("request-target's `..` segment would escape the path root") }
                if idx == last { stack.append([]) }
                continue
            }
            if seg == Array(".".utf8) {
                if idx == last { stack.append([]) }
                continue
            }
            if seg.isEmpty && idx != last { continue }
            stack.append(seg)
        }
        for seg in stack {
            for part in seg.split(separator: sentinel, omittingEmptySubsequences: false)
            where Array(part) == Array("..".utf8) || Array(part) == Array(".".utf8) {
                return fail("request-target still contains a `.`/`..` segment after canonicalization")
            }
        }

        // Re-encode.
        var path = "/"
        let hex = Array("0123456789ABCDEF".utf8)
        for (idx, seg) in stack.enumerated() {
            if idx > 0 { path.append("/") }
            for b in seg {
                if b == sentinel { path.append("%2F") }
                else if isPchar(b) { path.unicodeScalars.append(Unicode.Scalar(b)) }
                else { path.append("%"); path.unicodeScalars.append(Unicode.Scalar(hex[Int(b >> 4)]))
                       path.unicodeScalars.append(Unicode.Scalar(hex[Int(b & 0x0F)])) }
            }
        }

        // Query (rest.rs `parse_query_params`): `+` is a space; bad escapes
        // or non-UTF-8 fail the request.
        var query: [String: [String]] = [:]
        for pair in (queryPart ?? "").split(separator: "&", omittingEmptySubsequences: true) {
            let (rk, rv) = pair.firstIndex(of: "=").map { (pair[..<$0], pair[pair.index(after: $0)...]) } ?? (pair, "")
            guard let k = decodeQueryComponent(rk), let v = decodeQueryComponent(rv) else {
                return fail("Invalid percent-encoding in query component")
            }
            query[k, default: []].append(v)
        }
        return .success((path, query))
    }

    private static func hexNibble(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private static func isPchar(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            || Array("-._~!$&'()*+,;=:@".utf8).contains(b)
    }

    private static func decodeQueryComponent(_ s: Substring) -> String? {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "+") { out.append(0x20); i += 1; continue }
            guard b == UInt8(ascii: "%") else { out.append(b); i += 1; continue }
            guard i + 2 < bytes.count, let hi = hexNibble(bytes[i + 1]), let lo = hexNibble(bytes[i + 2]) else { return nil }
            out.append(hi << 4 | lo); i += 3
        }
        return String(bytes: out, encoding: .utf8)
    }

    static func cidr(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32, _ bits: UInt32) -> IPv4Range {
        let mask: UInt32 = bits == 0 ? 0 : (0xFFFF_FFFF << (32 - bits))
        return IPv4Range(net: (a << 24) | (b << 16) | (c << 8) | d, mask: mask)
    }
}

// MARK: - Provider layer

extension OpenShellPolicy {
    /// A Bromure-contributed rule, mirroring OpenShell's `_provider_*` layers:
    /// destinations the workspace needs because Bromure itself injects
    /// credentials there (the agent's model API, git forge, registries, …).
    public struct ProviderEndpoint: Sendable, Equatable {
        public var host: String
        public var ports: [UInt16]
        public init(host: String, ports: [UInt16] = [443]) {
            self.host = host.lowercased(); self.ports = ports
        }
    }

    /// Append Bromure-managed rules (attached provider profiles).
    public func withRules(_ rules: [NetworkRule]) -> OpenShellPolicy {
        var copy = self
        copy.networkPolicies.append(contentsOf: rules)
        return copy
    }

    /// The effective policy: the authored rules plus a `_provider_<name>` rule
    /// per non-empty group. Provider endpoints are uninspected, managed, and
    /// never persisted back into `source`.
    public func withProviderLayer(_ groups: [(name: String, endpoints: [ProviderEndpoint])]) -> OpenShellPolicy {
        var copy = self
        for g in groups where !g.endpoints.isEmpty {
            let key = "_provider_" + g.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
                .reduce(into: "") { $0.append($1) }
            let eps = g.endpoints.map {
                Endpoint(host: $0.host, ports: $0.ports, path: nil,
                         allowedIPs: EgressPolicy.parseIPv4($0.host).map { [IPv4Range(net: $0, mask: 0xFFFF_FFFF)] } ?? [],
                         l7: nil,
                         tlsSkip: false, enforcement: .audit, access: nil, rules: [], denyRules: [],
                         allowEncodedSlash: false, managed: true)
            }
            copy.networkPolicies.append(NetworkRule(key: key, name: key, endpoints: eps, binaries: []))
        }
        return copy
    }
}

// MARK: - Codable (as its YAML source)

extension OpenShellPolicy: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = try OpenShellPolicy.parse(try c.decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(source)
    }
}

// MARK: - Glob matching

/// OpenShell's glob dialect (schema "Matcher Semantics"): values split at a
/// separator; `*` matches within a segment; a whole-segment `**` matches one or
/// more segments (elsewhere it behaves like `*`); `?` one character; `[...]` a
/// class. `separator: nil` treats the value as one segment (so `*` spans all).
enum Glob {
    static func match(_ pattern: String, _ value: String, separator: Character?,
                      caseInsensitive: Bool) -> Bool {
        let p = caseInsensitive ? pattern.lowercased() : pattern
        let v = caseInsensitive ? value.lowercased() : value
        guard let sep = separator else {
            return segmentMatch(Array(p.replacingOccurrences(of: "**", with: "*")), Array(v))
        }
        let ps = p.split(separator: sep, omittingEmptySubsequences: false).map(String.init)
        let vs = v.split(separator: sep, omittingEmptySubsequences: false).map(String.init)
        return segmentsMatch(ps[...], vs[...])
    }

    private static func segmentsMatch(_ ps: ArraySlice<String>, _ vs: ArraySlice<String>) -> Bool {
        guard let first = ps.first else { return vs.isEmpty }
        if first == "**" {
            // One or more whole segments.
            guard !vs.isEmpty else { return false }
            var i = vs.startIndex + 1
            while i <= vs.endIndex {
                if segmentsMatch(ps.dropFirst(), vs[i...]) { return true }
                i += 1
            }
            return false
        }
        guard let v = vs.first else { return false }
        let seg = first.replacingOccurrences(of: "**", with: "*")
        return segmentMatch(Array(seg), Array(v))
            && segmentsMatch(ps.dropFirst(), vs.dropFirst())
    }

    /// Single-segment wildcard match with `*`, `?` and `[...]` classes.
    private static func segmentMatch(_ p: [Character], _ v: [Character]) -> Bool {
        var pi = 0, vi = 0
        var starP = -1, starV = 0
        while vi < v.count {
            if pi < p.count, p[pi] == "*" {
                starP = pi; starV = vi; pi += 1; continue
            }
            if pi < p.count {
                let (ok, next) = matchOne(p, pi, v[vi])
                if ok { pi = next; vi += 1; continue }
            }
            if starP >= 0 {
                pi = starP + 1; starV += 1; vi = starV; continue
            }
            return false
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Match the (non-`*`) pattern atom at `i` against `c`: (matched, index of
    /// the next atom).
    private static func matchOne(_ p: [Character], _ i: Int, _ c: Character) -> (Bool, Int) {
        switch p[i] {
        case "?": return (true, i + 1)
        case "[":
            guard let close = p[(i + 1)...].firstIndex(of: "]"), close > i + 1 else {
                return (c == "[", i + 1)
            }
            var j = i + 1
            var negate = false
            if p[j] == "!" || p[j] == "^" { negate = true; j += 1 }
            var hit = false
            while j < close {
                if j + 2 < close, p[j + 1] == "-" {
                    if p[j] <= c && c <= p[j + 2] { hit = true }
                    j += 3
                } else {
                    if p[j] == c { hit = true }
                    j += 1
                }
            }
            return (hit != negate, close + 1)
        default:
            return (p[i] == c, i + 1)
        }
    }
}
