import Foundation

// MARK: - Endpoint ambiguity (port of openshell-policy/src/ambiguity.rs)
//
// OpenShell refuses a policy in which two endpoints that can match the same
// connection disagree on connection metadata (explicit tcp, tls, allowed_ips),
// or — when both feed the request pipeline and their path selectors overlap
// at equal specificity — on request metadata (protocol, enforcement, …).
// Host and path overlap is decided exactly: whether the two glob languages
// intersect, by a product-automaton search over their tokens.

extension OpenShellPolicy {
    /// Connection / request metadata that must agree across overlapping
    /// endpoints (the raw values, as OpenShell compares them).
    public struct AmbiguityKeys: Sendable, Equatable {
        public var allowedIPsRaw: [String] = []
        public var websocketCredentialRewrite = false
        public var requestBodyCredentialRewrite = false
        public var credentialSigning = ""
        public var signingService = ""
        public var signingRegion = ""
        public var credentialBindingProvider = ""
        public var hasCredentialBinding = false
        public init() {}
    }

    struct Ambiguity: Error { let message: String }

    static func findAmbiguity(_ rules: [NetworkRule]) -> String? {
        let all = rules.flatMap { r in r.endpoints.enumerated().map { (r.name, $0.offset, $0.element) } }
        for i in all.indices {
            for j in all.indices where j > i {
                let (lp, li, l) = all[i], (rp, ri, r) = all[j]
                let ports = Set(l.ports).intersection(r.ports).sorted()
                guard !ports.isEmpty, hostPatternsOverlap(l.host ?? "", r.host ?? "") else { continue }
                var conflicts = connectionConflicts(l, r)
                if contributesRequestMetadata(l), contributesRequestMetadata(r),
                   pathPatternsOverlap(l.path ?? "", r.path ?? ""),
                   pathSpecificity(l.path ?? "") == pathSpecificity(r.path ?? "") {
                    conflicts += requestConflicts(l, r)
                }
                if !conflicts.isEmpty {
                    return "network policies '\(lp)' endpoint[\(li)] and '\(rp)' endpoint[\(ri)] overlap on port(s) "
                        + ports.map(String.init).joined(separator: ",")
                        + " with conflicting metadata: " + conflicts.joined(separator: "; ")
                }
            }
        }
        return nil
    }

    private static func connectionConflicts(_ l: Endpoint, _ r: Endpoint) -> [String] {
        var out: [String] = []
        if (l.l7 == .tcp) != (r.l7 == .tcp) { out.append("transparent_tcp_eligible") }
        if l.tlsSkip != r.tlsSkip { out.append("tls") }
        if normalizedStrings(l.ambiguity.allowedIPsRaw) != normalizedStrings(r.ambiguity.allowedIPsRaw) {
            out.append("allowed_ips")
        }
        return out
    }

    /// Rego's `endpoint_has_extended_config`, plus a credential binding.
    private static func contributesRequestMetadata(_ e: Endpoint) -> Bool {
        (e.l7 != nil && e.l7 != .tcp) || !e.ambiguity.allowedIPsRaw.isEmpty || e.tlsSkip
            || e.ambiguity.hasCredentialBinding
    }

    private static func requestConflicts(_ l: Endpoint, _ r: Endpoint) -> [String] {
        var out: [String] = []
        func check<T: Equatable>(_ name: String, _ a: T, _ b: T) { if a != b { out.append(name) } }
        func proto(_ e: Endpoint) -> String { e.l7 == nil || e.l7 == .tcp ? "" : e.l7!.rawValue }
        check("protocol", proto(l), proto(r))
        check("enforcement", l.enforcement, r.enforcement)
        check("allow_encoded_slash", l.allowEncodedSlash, r.allowEncodedSlash)
        check("websocket_credential_rewrite", l.ambiguity.websocketCredentialRewrite, r.ambiguity.websocketCredentialRewrite)
        check("request_body_credential_rewrite", l.ambiguity.requestBodyCredentialRewrite, r.ambiguity.requestBodyCredentialRewrite)
        if l.l7 == .websocket, r.l7 == .websocket {
            check("websocket_graphql_policy", !l.gqlRules.isEmpty || !l.gqlDenyRules.isEmpty,
                  !r.gqlRules.isEmpty || !r.gqlDenyRules.isEmpty)
        }
        check("credential_signing", l.ambiguity.credentialSigning, r.ambiguity.credentialSigning)
        check("signing_service", l.ambiguity.signingService, r.ambiguity.signingService)
        check("signing_region", l.ambiguity.signingRegion, r.ambiguity.signingRegion)
        check("credential_binding.provider", l.ambiguity.credentialBindingProvider, r.ambiguity.credentialBindingProvider)
        if l.l7 == .graphql, r.l7 == .graphql { check("graphql_max_body_bytes", l.graphqlMaxBody, r.graphqlMaxBody) }
        if l.l7 == r.l7, l.l7 == .jsonRPC || l.l7 == .mcp {
            // MCP's limit is `mcp.max_body_bytes` (the same OpenShell field).
            func limit(_ e: Endpoint) -> Int { e.l7 == .mcp ? e.mcp.maxBody : e.jsonRPCMaxBody }
            check("json_rpc_max_body_bytes", limit(l), limit(r))
        }
        if l.l7 == .mcp, r.l7 == .mcp { check("mcp.strict_tool_names", l.mcp.strictToolNames, r.mcp.strictToolNames) }
        return out
    }

    private static func normalizedStrings(_ xs: [String]) -> [String] {
        Array(Set(xs.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })).sorted()
    }

    static func pathSpecificity(_ p: String) -> Int { p.filter { $0 != "*" }.count }

    // MARK: glob language intersection

    enum Token: Equatable {
        case literal(Unicode.Scalar)
        case anyChar
        case charClass([ClosedRange<UInt32>], negated: Bool)
        case star(crossesDelimiter: Bool)
        var isStar: Bool { if case .star = self { return true }; return false }
    }

    static func hostPatternsOverlap(_ l: String, _ r: String) -> Bool {
        if l.isEmpty || r.isEmpty { return true }
        return languagesOverlap(delimitedTokens(l.lowercased()), delimitedTokens(r.lowercased()), delimiter: ".")
    }

    static func pathPatternsOverlap(_ l: String, _ r: String) -> Bool {
        if l.isEmpty || r.isEmpty || l == "**" || l == "/**" || r == "**" || r == "/**" { return true }
        guard let lt = runtimePathTokens(l), let rt = runtimePathTokens(r) else { return true }
        return languagesOverlap(lt, rt, delimiter: "/")
    }

    /// Host globs: `*` stays within a label, `**` crosses it.
    static func delimitedTokens(_ p: String) -> [Token] {
        let c = Array(p.unicodeScalars)
        var out: [Token] = []
        var i = 0
        while i < c.count {
            guard c[i] == "*" else { out.append(.literal(c[i])); i += 1; continue }
            let start = i
            while i < c.count, c[i] == "*" { i += 1 }
            out.append(.star(crossesDelimiter: i - start >= 2))
        }
        return out
    }

    /// Endpoint path selectors, as the runtime glob matcher reads them.
    static func runtimePathTokens(_ p: String) -> [Token]? {
        let c = Array(p.unicodeScalars)
        var out: [Token] = []
        var i = 0
        while i < c.count {
            switch c[i] {
            case "?":
                out.append(.anyChar); i += 1
            case "*":
                let start = i
                while i < c.count, c[i] == "*" { i += 1 }
                let n = i - start
                if n > 2 { return nil }
                if n == 2 {
                    let startsComponent = start == 0 || c[start - 1] == "/"
                    let endsComponent = i == c.count || c[i] == "/"
                    guard startsComponent, endsComponent else { return nil }
                    if i < c.count, c[i] == "/" { i += 1 }
                }
                out.append(.star(crossesDelimiter: true))
            case "[":
                let negated = i + 1 < c.count && c[i + 1] == "!"
                let contentStart = i + (negated ? 2 : 1)
                guard contentStart <= c.count,
                      let close = c[contentStart...].firstIndex(of: "]"), close != contentStart else { return nil }
                out.append(.charClass(ranges(Array(c[contentStart..<close])), negated: negated))
                i = close + 1
            default:
                out.append(.literal(c[i])); i += 1
            }
        }
        return out
    }

    private static func ranges(_ c: [Unicode.Scalar]) -> [ClosedRange<UInt32>] {
        var out: [ClosedRange<UInt32>] = []
        var i = 0
        while i < c.count {
            if i + 2 < c.count, c[i + 1] == "-" {
                if c[i].value <= c[i + 2].value { out.append(c[i].value...c[i + 2].value) }
                i += 3
            } else {
                out.append(c[i].value...c[i].value); i += 1
            }
        }
        return out
    }

    /// Product-NFA search: can both token sequences match one string?
    static func languagesOverlap(_ l: [Token], _ r: [Token], delimiter: Unicode.Scalar) -> Bool {
        struct State: Hashable { let a: Int; let b: Int }
        var queue = [State(a: 0, b: 0)]
        var seen = Set<State>()
        while !queue.isEmpty {
            let s = queue.removeFirst()
            guard seen.insert(s).inserted else { continue }
            if s.a == l.count, s.b == r.count { return true }
            if s.a < l.count, l[s.a].isStar { queue.append(State(a: s.a + 1, b: s.b)) }
            if s.b < r.count, r[s.b].isStar { queue.append(State(a: s.a, b: s.b + 1)) }
            guard s.a < l.count, s.b < r.count else { continue }
            if share(l[s.a], r[s.b], delimiter) {
                queue.append(State(a: l[s.a].isStar ? s.a : s.a + 1, b: r[s.b].isStar ? s.b : s.b + 1))
            }
        }
        return false
    }

    private static let scalarSpace: [ClosedRange<UInt32>] = [0...0xD7FF, 0xE000...0x10FFFF]

    private static func share(_ a: Token, _ b: Token, _ d: Unicode.Scalar) -> Bool {
        let x = charRanges(a, d), y = charRanges(b, d)
        return x.contains { l in y.contains { r in l.lowerBound <= r.upperBound && r.lowerBound <= l.upperBound } }
    }

    private static func charRanges(_ t: Token, _ d: Unicode.Scalar) -> [ClosedRange<UInt32>] {
        switch t {
        case .literal(let c): return [c.value...c.value]
        case .anyChar, .star(crossesDelimiter: true): return scalarSpace
        case .star(crossesDelimiter: false): return complement([d.value...d.value])
        case .charClass(let rs, let negated): return negated ? complement(rs) : rs
        }
    }

    private static func complement(_ rs: [ClosedRange<UInt32>]) -> [ClosedRange<UInt32>] {
        let sorted = rs.sorted { $0.lowerBound < $1.lowerBound }
        var out: [ClosedRange<UInt32>] = []
        for space in scalarSpace {
            var cursor = space.lowerBound
            for r in sorted where !(r.upperBound < space.lowerBound || r.lowerBound > space.upperBound) {
                let lo = max(r.lowerBound, space.lowerBound), hi = min(r.upperBound, space.upperBound)
                if cursor < lo { out.append(cursor...(lo - 1)) }
                if hi >= cursor { cursor = hi == UInt32.max ? hi : hi + 1 }
            }
            if cursor <= space.upperBound { out.append(cursor...space.upperBound) }
        }
        return out
    }
}
