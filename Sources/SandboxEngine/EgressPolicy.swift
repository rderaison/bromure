import Foundation

/// Per-profile outbound-connection policy: a pf-style ruleset that governs which
/// TCP/UDP flows a VM may open, and — for HTTP(S) hosts that get MiTM'd — which
/// request methods are allowed. Evaluated at two layers that share this one
/// model: the L2 switch (by destination IP + DNS-snooped hostname, all protocols)
/// and the MiTM (by TLS SNI, and by HTTP method). Lives in SandboxEngine so both
/// layers can use it — AgentCoding (the MiTM) depends on SandboxEngine, not the
/// reverse.
///
/// Canonical serialization is pf-style text (one rule per line); the editor binds
/// to the structured form and mirrors it as text. See `parse` / `serialize`.
///
///     allow tcp api.github.com:443
///     allow web api.example.com GET,POST          # only these verbs reach the site
///     deny  web api.internal PUT,DELETE           # block these verbs, allow the rest
///     deny  udp any:53
///     deny  any 10.0.0.0/8
///     default deny
public struct EgressPolicy: Sendable, Equatable, Codable {
    public enum Action: String, Sendable, Equatable, Codable { case allow, deny }
    /// `web` is HTTP(S)-over-TCP — a proto whose rules can additionally restrict
    /// request methods. At the switch (L4) a `web` rule governs the TCP flow.
    public enum Proto: String, Sendable, Equatable, Codable { case tcp, udp, web, any }
    public enum DefaultAction: String, Sendable, Equatable, Codable { case allow, deny }

    /// What a matched flow is permitted to do at the connection layer.
    public enum Verdict: Sendable, Equatable { case allow, deny, mitm }

    /// A rule target: any, a hostname (suffix-matched), or an IPv4 host/CIDR.
    public enum Target: Sendable, Equatable, Codable {
        case any
        /// `domain`, lowercased. `includeApex` distinguishes `example.com`
        /// (apex + subdomains) from `*.example.com` (subdomains only).
        case host(domain: String, includeApex: Bool)
        /// IPv4 network + mask, host byte order (a bare IP is /32).
        case cidr(net: UInt32, mask: UInt32)

        func matches(ip: UInt32?, hostnames: [String]) -> Bool {
            switch self {
            case .any:
                return true
            case .cidr(let net, let mask):
                guard let ip else { return false }
                return (ip & mask) == (net & mask)
            case .host(let domain, let apex):
                for h in hostnames {
                    let l = h.lowercased()
                    if apex && l == domain { return true }
                    if l.hasSuffix("." + domain) { return true }
                }
                return false
            }
        }
    }

    /// A set of port ranges; empty means "any port".
    public struct PortSet: Sendable, Equatable, Codable {
        public var ranges: [ClosedRange<UInt16>]
        public init(_ ranges: [ClosedRange<UInt16>] = []) { self.ranges = ranges }
        public var isAny: Bool { ranges.isEmpty }
        public func contains(_ p: UInt16) -> Bool { ranges.isEmpty || ranges.contains { $0.contains(p) } }
    }

    /// The method list carried by a `web`-proto rule. The rule's `action`
    /// decides how it reads: with `allow` it's an allowlist (only these verbs
    /// pass), with `deny` a denylist (these verbs are blocked). `readOnly` is
    /// sugar for GET/HEAD/OPTIONS. A `web` rule with no list means all methods
    /// (allow) or none (deny).
    public enum MethodSpec: Sendable, Equatable, Codable {
        case readOnly              // GET / HEAD / OPTIONS
        case list([String])        // uppercased method names

        static let readMethods: Set<String> = ["GET", "HEAD", "OPTIONS"]
        /// Membership only — the allow/deny sense is applied by the rule.
        public func contains(_ method: String) -> Bool {
            let m = method.uppercased()
            switch self {
            case .readOnly:     return MethodSpec.readMethods.contains(m)
            case .list(let ms): return ms.contains(m)
            }
        }
    }

    public struct Rule: Sendable, Equatable, Codable {
        public var action: Action
        public var proto: Proto
        public var target: Target
        public var ports: PortSet
        public var methods: MethodSpec?   // only meaningful for a `.web` proto

        public init(action: Action, proto: Proto, target: Target,
                    ports: PortSet = PortSet(), methods: MethodSpec? = nil) {
            self.action = action; self.proto = proto; self.target = target
            self.ports = ports; self.methods = methods
        }

        func matches(ip: UInt32?, hostnames: [String], proto: Proto, port: UInt16) -> Bool {
            protoMatches(proto) && ports.contains(port) && target.matches(ip: ip, hostnames: hostnames)
        }
        private func protoMatches(_ p: Proto) -> Bool {
            if self.proto == .any || p == .any { return true }
            if self.proto == p { return true }
            // `web` is HTTP(S)-over-TCP, so a web rule governs TCP flows (and a
            // TCP query resolves a web rule) — the switch's L4 (TCP) check and
            // the verb layer land on the same rule.
            return (self.proto == .web && p == .tcp) || (self.proto == .tcp && p == .web)
        }

        /// Whether `method` is permitted by this rule. Only a `.web` rule can
        /// forbid a method; `action` sets the sense of `methods` (allow =
        /// allowlist, deny = denylist). No list ⇒ all (allow) or none (deny).
        func methodAllowed(_ method: String) -> Bool {
            guard proto == .web else { return true }
            guard let methods else { return action == .allow }
            let inList = methods.contains(method)
            return action == .allow ? inList : !inList
        }
    }

    public var defaultAction: DefaultAction
    public var rules: [Rule]

    public init(defaultAction: DefaultAction = .allow, rules: [Rule] = []) {
        self.defaultAction = defaultAction
        self.rules = rules
    }

    /// The all-allow policy — the non-breaking default for a profile with no
    /// rules configured.
    public static let allowAll = EgressPolicy(defaultAction: .allow, rules: [])

    public var isActive: Bool { defaultAction == .deny || !rules.isEmpty }

    // MARK: - Evaluation

    /// The first rule that matches this flow (proto/target/port), or nil to fall
    /// back to `defaultAction`. Method is not considered here — the L4 and SNI
    /// layers match by flow; the verb layer applies `methods` to the same rule.
    public func firstMatch(ip: UInt32?, hostnames: [String], proto: Proto, port: UInt16) -> Rule? {
        rules.first { $0.matches(ip: ip, hostnames: hostnames, proto: proto, port: port) }
    }

    /// Connection-layer verdict: `.deny` = drop/close; `.mitm` = a `web` rule
    /// forces MiTM (overriding passthrough); `.allow` = permit (normal MiTM-vs-
    /// passthrough logic still applies at the SNI layer). Used by both the switch
    /// (IP/snoop) and the MiTM (SNI).
    public func verdict(ip: UInt32?, hostnames: [String], proto: Proto, port: UInt16) -> Verdict {
        guard let rule = firstMatch(ip: ip, hostnames: hostnames, proto: proto, port: port) else {
            return defaultAction == .deny ? .deny : .allow
        }
        switch rule.action {
        case .allow:
            // A `web` allow forces MiTM so the verb layer can see the request.
            return rule.proto == .web ? .mitm : .allow
        case .deny:
            // `deny web host M,N` blocks only those verbs, so the connection is
            // allowed + MiTM'd to inspect the method. A blanket web deny (no
            // list) or any non-web deny drops the flow.
            if rule.proto == .web, rule.methods != nil { return .mitm }
            return .deny
        }
    }

    /// Whether an HTTP `method` to this host is allowed. Resolves the same
    /// first-matching rule as the connection layer; only a `.web` rule can
    /// forbid a method (allow-list or deny-list per its action). Everything
    /// else permits — connection deny is handled at the connection layer.
    public func permitsMethod(hostnames: [String], port: UInt16, method: String) -> Bool {
        guard let rule = firstMatch(ip: nil, hostnames: hostnames, proto: .tcp, port: port) else { return true }
        return rule.methodAllowed(method)
    }
}

// MARK: - pf-style parsing / serialization

extension EgressPolicy {
    public struct ParseError: Error, Equatable { public let line: Int; public let message: String }

    /// Parse the pf-style text into a structured policy. Unknown/blank lines and
    /// `#` comments are skipped; the first `ParseError` aborts (callers surface
    /// `line`/`message` in the editor). Absent `default` ⇒ `.allow`.
    public static func parse(_ text: String) throws -> EgressPolicy {
        var rules: [Rule] = []
        var def: DefaultAction = .allow
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw.prefix(while: { $0 != "#" }))
            let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if toks.isEmpty { continue }
            let ln = i + 1

            if toks[0].lowercased() == "default" {
                guard toks.count == 2, let d = DefaultAction(rawValue: toks[1].lowercased()) else {
                    throw ParseError(line: ln, message: "expected 'default allow' or 'default deny'")
                }
                def = d
                continue
            }

            guard let action = Action(rawValue: toks[0].lowercased()) else {
                throw ParseError(line: ln, message: "unknown action '\(toks[0])' (allow / deny)")
            }
            // Optional proto: token[1] is a proto keyword, else it's the target.
            var idx = 1
            var proto: Proto = .any
            if idx < toks.count, let p = Proto(rawValue: toks[idx].lowercased()) {
                proto = p; idx += 1
            }
            guard idx < toks.count else {
                throw ParseError(line: ln, message: "missing target host / IP / CIDR")
            }
            let (target, ports) = try parseTarget(toks[idx], line: ln)
            idx += 1

            var methods: MethodSpec?
            if idx < toks.count {
                guard proto == .web else {
                    throw ParseError(line: ln, message: "HTTP methods apply only to 'web' rules")
                }
                methods = try parseMethods(Array(toks[idx...]), line: ln)
            }
            rules.append(Rule(action: action, proto: proto, target: target, ports: ports, methods: methods))
        }
        return EgressPolicy(defaultAction: def, rules: rules)
    }

    /// Canonical pf text for the ruleset (round-trips through `parse`).
    public func serialize() -> String {
        var out = rules.map { rule -> String in
            var parts: [String] = [rule.action.rawValue, rule.proto.rawValue,
                                    Self.targetString(rule.target, ports: rule.ports)]
            if rule.proto == .web, let m = rule.methods { parts.append(Self.methodsString(m)) }
            return parts.joined(separator: " ")
        }
        out.append("default \(defaultAction.rawValue)")
        return out.joined(separator: "\n")
    }

    // MARK: parse helpers

    private static func parseTarget(_ token: String, line: Int) throws -> (Target, PortSet) {
        // Split host-part from an optional :ports suffix (IPv4/CIDR carry no ':').
        var hostPart = token
        var ports = PortSet()
        if let colon = token.lastIndex(of: ":"), !token.contains("/") {
            hostPart = String(token[..<colon])
            ports = try parsePorts(String(token[token.index(after: colon)...]), line: line)
        }
        let target: Target
        let lp = hostPart.lowercased()
        if lp == "any" || lp == "*" {
            target = .any
        } else if hostPart.contains("/") {
            target = try parseCIDR(hostPart, line: line)
        } else if let ip = parseIPv4(hostPart) {
            target = .cidr(net: ip, mask: 0xFFFF_FFFF)          // bare IP = /32
        } else if lp.hasPrefix("*.") {
            target = .host(domain: String(lp.dropFirst(2)), includeApex: false)
        } else {
            target = .host(domain: lp, includeApex: true)
        }
        return (target, ports)
    }

    private static func parsePorts(_ s: String, line: Int) throws -> PortSet {
        let t = s.lowercased()
        if t.isEmpty || t == "*" || t == "any" { return PortSet() }   // any port
        var ranges: [ClosedRange<UInt16>] = []
        for part in s.split(separator: ",") {
            let bits = part.split(separator: "-", maxSplits: 1)
            if bits.count == 2, let lo = UInt16(bits[0]), let hi = UInt16(bits[1]), lo <= hi {
                ranges.append(lo...hi)
            } else if bits.count == 1, let p = UInt16(bits[0]) {
                ranges.append(p...p)
            } else {
                throw ParseError(line: line, message: "bad port '\(part)'")
            }
        }
        return PortSet(ranges)
    }

    private static func parseMethods(_ toks: [String], line: Int) throws -> MethodSpec {
        // Accept a bare comma list (GET,POST), the `read-only` shorthand, or a
        // legacy `methods GET,POST` form.
        var parts = toks
        if parts.first?.lowercased() == "methods" { parts = Array(parts.dropFirst()) }
        if parts.count == 1, parts[0].lowercased() == "read-only" { return .readOnly }
        let list = parts.joined()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
        guard !list.isEmpty else {
            throw ParseError(line: line, message: "expected HTTP methods (e.g. GET,POST) or 'read-only'")
        }
        for m in list where !m.allSatisfy({ $0.isLetter }) {
            throw ParseError(line: line, message: "bad HTTP method '\(m)'")
        }
        return .list(list)
    }

    private static func parseCIDR(_ s: String, line: Int) throws -> Target {
        let parts = s.split(separator: "/")
        guard parts.count == 2, let ip = parseIPv4(String(parts[0])),
              let bits = UInt8(parts[1]), bits <= 32 else {
            throw ParseError(line: line, message: "bad CIDR '\(s)'")
        }
        let mask: UInt32 = bits == 0 ? 0 : (0xFFFF_FFFF << (32 - UInt32(bits)))
        return .cidr(net: ip, mask: mask)
    }

    static func parseIPv4(_ s: String) -> UInt32? {
        let octets = s.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var v: UInt32 = 0
        for o in octets {
            guard let n = UInt16(o), n <= 255 else { return nil }
            v = (v << 8) | UInt32(n)
        }
        return v
    }

    // MARK: serialize helpers

    public static func ipv4String(_ v: UInt32) -> String {
        "\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }

    private static func targetString(_ t: Target, ports: PortSet) -> String {
        let host: String
        switch t {
        case .any: host = "any"
        case .host(let d, let apex): host = apex ? d : "*.\(d)"
        case .cidr(let net, let mask):
            let bits = mask == 0 ? 0 : 32 - mask.trailingZeroBitCount
            host = bits == 32 ? ipv4String(net) : "\(ipv4String(net))/\(bits)"
        }
        guard !ports.isAny else { return host }
        let p = ports.ranges.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }
            .joined(separator: ",")
        return "\(host):\(p)"
    }

    private static func methodsString(_ m: MethodSpec) -> String {
        switch m {
        case .readOnly:     return "read-only"
        case .list(let ms): return ms.joined(separator: ",")
        }
    }
}

// MARK: - Editor bridge (structured rows ⇄ pf text, for the table UI)

extension EgressPolicy {
    /// One rule as free-text fields the table binds to. `methods` is `read-only`,
    /// a bare comma list (`GET,POST`), or empty.
    public struct EditRow: Identifiable, Equatable, Sendable {
        public var id = UUID()
        public var action: String
        public var proto: String
        public var host: String
        public var ports: String
        public var methods: String
        public init(action: String = "allow", proto: String = "tcp", host: String = "any",
                    ports: String = "", methods: String = "") {
            self.action = action; self.proto = proto; self.host = host
            self.ports = ports; self.methods = methods
        }
    }

    public func editRows() -> [EditRow] {
        rules.map { r in
            let host: String
            switch r.target {
            case .any: host = "any"
            case .host(let d, let apex): host = apex ? d : "*.\(d)"
            case .cidr(let net, let mask):
                let bits = mask == 0 ? 0 : 32 - mask.trailingZeroBitCount
                host = bits == 32 ? Self.ipv4String(net) : "\(Self.ipv4String(net))/\(bits)"
            }
            let ports = r.ports.isAny ? "" : r.ports.ranges
                .map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }
                .joined(separator: ",")
            let methods: String
            switch r.methods {
            case .readOnly?:       methods = "read-only"
            case .list(let ms)?:   methods = ms.joined(separator: ",")
            case nil:              methods = ""
            }
            return EditRow(action: r.action.rawValue, proto: r.proto.rawValue,
                           host: host, ports: ports, methods: methods)
        }
    }

    /// Assemble a pf ruleset from editor rows + default posture. The result is
    /// what gets stored and re-parsed — a round-trip through `parse`.
    public static func pfText(rows: [EditRow], defaultAllow: Bool) -> String {
        var lines = rows.compactMap { row -> String? in
            let host = row.host.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { return nil }
            let proto = row.proto.trimmingCharacters(in: .whitespaces).isEmpty ? "any" : row.proto
            var parts = [row.action, proto]
            let ports = row.ports.trimmingCharacters(in: .whitespaces)
            let anyPort = ports.isEmpty || ports.lowercased() == "any" || ports == "*"
            parts.append(anyPort ? host : "\(host):\(ports)")
            let m = row.methods.trimmingCharacters(in: .whitespaces)
            if proto == "web", !m.isEmpty {
                parts.append(m)   // bare list or read-only — parseMethods handles both
            }
            return parts.joined(separator: " ")
        }
        lines.append("default \(defaultAllow ? "allow" : "deny")")
        return lines.joined(separator: "\n")
    }

    /// The default posture parsed from pf text (for the editor's toggle).
    public static func defaultAllow(from text: String) -> Bool {
        ((try? parse(text))?.defaultAction ?? .allow) == .allow
    }
}
