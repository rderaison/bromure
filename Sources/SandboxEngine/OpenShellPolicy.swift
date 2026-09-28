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
///  - fail closed under `enforcement: enforce` (allowed + logged under audit):
///    GraphQL / MCP / JSON-RPC request inspection, not yet implemented.
///  - accepted, not enforced: `binaries` (the guest's user has root, so no
///    in-guest process identity is trustworthy), `filesystem_policy` /
///    `landlock` / `process` (the VM boundary replaces them), WebSocket client
///    text frames, `network_middlewares`, credential rewrite / signing fields.
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
            globs.contains { Glob.match($0, value, separator: ".", caseInsensitive: false) }
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
        func matches(host h: String?, port: UInt16) -> Bool {
            guard ports.contains(port) else { return false }
            guard let host else { return !allowedIPs.isEmpty }       // hostless
            guard let h else { return false }
            let lh = h.lowercased()
            if host.contains("*") { return Glob.match(host, lh, separator: ".", caseInsensitive: true) }
            return host == lh
        }

        /// The endpoint `path` selector (schema: empty / `**` / `/**` match
        /// everything; `/v1/**` also matches `/v1`; elsewhere `*` spans `/`).
        func selects(path p: String) -> Bool {
            guard let path, !path.isEmpty, path != "**", path != "/**" else { return true }
            if path.hasSuffix("/**") {
                // `/v1/**` matches `/v1` itself and everything below it.
                let base = String(path.dropLast(3))
                return Glob.match(base, p, separator: nil, caseInsensitive: false)
                    || Glob.match(base + "/*", p, separator: nil, caseInsensitive: false)
            }
            return Glob.match(path, p, separator: nil, caseInsensitive: false)
        }

        /// Effective allow matchers: explicit rules, or the access preset
        /// expanded over every path.
        public var allowMatchers: [RequestMatcher] {
            if let access {
                // WebSocket: read-only = the upgrade only; read-write / full also
                // let the client send text messages.
                let methods = l7 == .websocket
                    ? (access == .readOnly ? ["GET"] : ["GET", "WEBSOCKET_TEXT"])
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
                b.contains("*") || b.contains("?") || b.contains("[")
                    ? chain.contains { Glob.match(b, $0, separator: "/", caseInsensitive: false) }
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
    /// `filesystem_policy`, `process`, `landlock` — not applied by Bromure
    /// (the VM is the boundary) but kept for boundary checks and export.
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
        if let ip, Self.blockedRanges.contains(where: { $0.contains(ip) }) {
            return .deny(reason: "destination \(EgressPolicy.ipv4String(ip)) is always blocked")
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
        var matched: [(rule: String, ep: Endpoint)] = []
        for rule in networkPolicies {
            for ep in rule.endpoints where ep.matches(host: host, port: port) {
                if !ep.allowedIPs.isEmpty {
                    // allowed_ips must hold the actual destination; unknown ⇒ can't verify.
                    guard let ip, ep.allowedIPs.contains(where: { $0.contains(ip) }) else { continue }
                }
                if Self.controlPlanePorts.contains(port), !ep.managed,
                   !ep.isWildcard || !ep.allowedIPs.isEmpty {
                    continue
                }
                matched.append((rule.key, ep))
            }
        }
        let label = host ?? ip.map(EgressPolicy.ipv4String) ?? "?"
        guard !matched.isEmpty else {
            return .deny(reason: "no network policy allows \(label):\(port)")
        }
        if let ip, Self.privateRanges.contains(where: { $0.contains(ip) }) {
            let ok = matched.contains { m in
                (m.ep.host != nil && !m.ep.isWildcard)
                    || m.ep.allowedIPs.contains(where: { $0.contains(ip) })
            }
            if !ok {
                return .deny(reason: "\(label):\(port) resolves to private address "
                             + "\(EgressPolicy.ipv4String(ip)); list it in allowed_ips")
            }
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
        guard !matching.isEmpty else { return .allow }

        let allowSlash = matching.contains { $0.ep.allowEncodedSlash && ($0.ep.l7?.inspects ?? false) }
        let canonical: (path: String, query: [String: [String]])
        switch Self.canonicalize(target: target, allowEncodedSlash: allowSlash) {
        case .success(let c): canonical = c
        case .failure(let e):
            // Malformed / ambiguous targets are rejected even under audit.
            return .violation(reason: "\(method) rejected: \(e.message)", rule: nil, enforced: true)
        }

        let selected = matching.filter { $0.ep.selects(path: canonical.path) }
        let inspected = selected.filter { $0.ep.l7?.inspects ?? false }
        guard !inspected.isEmpty else { return .allow }

        // Endpoints that can match the same request must agree on enforcement
        // (validated); take the most specific selector's.
        let primary = inspected.max { specificity($0.ep.path) < specificity($1.ep.path) }!
        let enforced = primary.ep.enforcement == .enforce
        let request = L7Request(method: method.uppercased(), path: canonical.path, query: canonical.query,
                                headers: headers, body: body, bodyComplete: bodyComplete)

        var firstDeny: (String, String)?
        var granted = false
        var reasons: [String] = []
        for (rule, ep) in inspected {
            switch evaluate(request, on: ep) {
            case .allow: granted = true
            case .deny(let why): if firstDeny == nil { firstDeny = (why, rule) }
            case .notPermitted(let why): if let why { reasons.append(why) }
            }
        }
        if let (why, rule) = firstDeny { return .violation(reason: why, rule: rule, enforced: enforced) }
        if granted { return .allow }
        return .violation(reason: reasons.first ?? "\(request.method) \(request.path) not permitted by policy",
                          rule: primary.rule, enforced: enforced)
    }

    /// Whether the client may send text messages on a WebSocket upgraded at
    /// `target` (`WEBSOCKET_TEXT` rules match the upgrade path, never message
    /// content, so this is decided once per connection). nil when no
    /// `protocol: websocket` endpoint covers the connection — nothing to gate.
    public func websocketTextDecision(host: String, port: UInt16, target: String,
                                      identity: BinaryIdentity? = nil,
                                      enforceBinaries: Bool = false) -> RequestDecision? {
        let ws = networkPolicies.filter { rule in
            rule.applies(to: identity, enforce: enforceBinaries)
                && rule.endpoints.contains { $0.l7 == .websocket && $0.matches(host: host, port: port) }
        }.map { rule in
            NetworkRule(key: rule.key, name: rule.name,
                        endpoints: rule.endpoints.filter { $0.l7 == .websocket }, binaries: rule.binaries)
        }
        guard !ws.isEmpty else { return nil }
        var only = self
        only.networkPolicies = ws
        return only.evaluateRequest(host: host, port: port, method: "WEBSOCKET_TEXT", target: target)
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

    enum EndpointVerdict { case allow, deny(String), notPermitted(String?) }

    func evaluate(_ r: L7Request, on ep: Endpoint) -> EndpointVerdict {
        switch ep.l7 {
        case .rest?, .websocket?:
            let desc = "\(r.method) \(r.path)"
            if ep.denyRules.contains(where: { Self.denyMatches($0, method: r.method, path: r.path, query: r.query) }) {
                return .deny("\(desc) blocked by deny rule")
            }
            return ep.allowMatchers.contains(where: { Self.allowMatches($0, method: r.method, path: r.path, query: r.query) })
                ? .allow : .notPermitted(nil)
        case .mcp?:     return evaluateMCP(r, ep)
        case .jsonRPC?: return evaluateJSONRPC(r, ep)
        case .graphql?: return evaluateGraphQL(r, ep)
        case .tcp?, nil: return .notPermitted(nil)
        }
    }

    private func specificity(_ path: String?) -> Int {
        guard let path, path != "**", path != "/**" else { return 0 }
        return path.filter { $0 != "*" }.count
    }

    static func methodMatches(_ actual: String, _ expected: String) -> Bool {
        let e = expected.uppercased()
        if e == "*" { return true }
        if actual == e { return true }
        return actual == "HEAD" && e == "GET"
    }

    static func pathMatches(_ path: String, _ pattern: String) -> Bool {
        pattern == "**" || Glob.match(pattern, path, separator: "/", caseInsensitive: false)
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

    /// Whether an endpoint `path` selector matches a canonical path.
    public static func pathSelector(_ selector: String, matches path: String) -> Bool {
        Endpoint(host: nil, ports: [], path: selector, allowedIPs: [], l7: nil, tlsSkip: false,
                 enforcement: .audit, access: nil, rules: [], denyRules: [], allowEncodedSlash: false)
            .selects(path: path)
    }

    public struct CanonicalizeError: Error, Equatable { public let message: String }

    /// Canonicalize an origin-form request target the way OpenShell's L7 parser
    /// does before evaluation: percent-decode, resolve dot segments, collapse
    /// doubled slashes, strip `;params`, reject `%2F` (unless allowed), control
    /// bytes, raw non-ASCII, fragments and escapes above the root.
    static func canonicalize(target: String, allowEncodedSlash: Bool)
        -> Result<(path: String, query: [String: [String]]), CanonicalizeError> {
        func fail(_ m: String) -> Result<(path: String, query: [String: [String]]), CanonicalizeError> {
            .failure(CanonicalizeError(message: m))
        }
        var t = target
        // Absolute-form (forward proxy): keep the path part.
        if let r = t.range(of: "://") {
            let afterScheme = t[r.upperBound...]
            t = afterScheme.firstIndex(of: "/").map { String(afterScheme[$0...]) } ?? "/"
        }
        guard t.utf8.count <= 4096 else { return fail("request path too long") }
        guard t.hasPrefix("/") else { return fail("request-target is not an origin-form path") }
        if t.contains("#") { return fail("request-target contains a fragment") }
        for b in t.utf8 {
            if b < 0x20 || b == 0x7F { return fail("request-target contains a control byte") }
            if b >= 0x80 { return fail("request-target contains raw non-ASCII bytes") }
        }
        var rawPath = t
        var rawQuery = ""
        if let q = t.firstIndex(of: "?") {
            rawPath = String(t[..<q]); rawQuery = String(t[t.index(after: q)...])
        }

        var out: [String] = []
        for rawSeg in rawPath.split(separator: "/", omittingEmptySubsequences: true) {
            var seg = String(rawSeg)
            if let semi = seg.firstIndex(of: ";") { seg = String(seg[..<semi]) }
            // Decode, keeping %2F as a literal marker (never a separator).
            let upper = seg.replacingOccurrences(of: "%2f", with: "%2F")
            if upper.contains("%2F") && !allowEncodedSlash {
                return fail("request-target contains an encoded '/' (%2F)")
            }
            var decodedParts: [String] = []
            for part in upper.components(separatedBy: "%2F") {
                guard let d = percentDecode(part) else { return fail("invalid percent-encoding") }
                if d.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                    return fail("request-target contains a control byte")
                }
                decodedParts.append(d)
            }
            let decoded = decodedParts.joined(separator: "%2F")
            if decoded.isEmpty || decoded == "." { continue }
            if decoded == ".." {
                guard !out.isEmpty else { return fail("'..' escapes the path root") }
                out.removeLast(); continue
            }
            out.append(decoded)
        }
        var path = "/" + out.joined(separator: "/")
        if rawPath.count > 1, rawPath.hasSuffix("/"), path != "/" { path += "/" }

        var query: [String: [String]] = [:]
        for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let k = percentDecode(String(kv[0]).replacingOccurrences(of: "+", with: " ")) ?? String(kv[0])
            let v = kv.count > 1
                ? (percentDecode(String(kv[1]).replacingOccurrences(of: "+", with: " ")) ?? String(kv[1])) : ""
            query[k, default: []].append(v)
        }
        return .success((path, query))
    }

    private static func percentDecode(_ s: String) -> String? {
        guard s.contains("%") else { return s }
        return s.removingPercentEncoding
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
