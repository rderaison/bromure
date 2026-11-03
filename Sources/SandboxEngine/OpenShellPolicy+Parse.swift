import Foundation
import Yams

// MARK: - Parsing + validation

extension OpenShellPolicy {
    /// A rejected policy. `path` is the YAML key path (e.g.
    /// `network_policies.github.endpoints[0].port`), `line` the 1-based source
    /// line when known — both surfaced by the editor.
    public struct ParseError: Error, Equatable, CustomStringConvertible, Sendable {
        public let line: Int?
        public let path: String
        public let message: String
        public var description: String {
            let loc = line.map { "line \($0): " } ?? ""
            return path.isEmpty ? "\(loc)\(message)" : "\(loc)\(path): \(message)"
        }
    }

    /// Parse and validate OpenShell policy YAML. Mirrors OpenShell's loader:
    /// unknown fields, duplicate keys and schema violations are errors (the
    /// policy is rejected as a whole, never partially applied).
    public static func parse(_ yaml: String) throws -> OpenShellPolicy {
        guard yaml.utf8.count <= 4 * 1024 * 1024 else {
            throw ParseError(line: nil, path: "", message: "policy exceeds 4 MiB")
        }
        let root: Node?
        do {
            root = try Yams.compose(yaml: yaml)
        } catch let e as YamlError {
            if case .duplicatedKeysInMapping(let dups, _) = e {
                let keys = dups.keys.compactMap { $0.scalar?.string }.sorted().joined(separator: ", ")
                throw ParseError(line: dups.keys.first?.mark?.line, path: keys, message: "duplicate key")
            }
            throw ParseError(line: nil, path: "", message: "invalid YAML: \(e)")
        } catch {
            throw ParseError(line: nil, path: "", message: "invalid YAML: \(error)")
        }
        guard let root else { throw ParseError(line: nil, path: "", message: "empty policy") }
        var r = Reader()
        let top = try r.mapping(root, "", allowed: ["version", "filesystem_policy", "landlock", "process",
                                                     "network_policies", "network_middlewares"])
        guard let v = top["version"] else {
            throw ParseError(line: root.mark?.line, path: "version", message: "required field is missing")
        }
        guard try r.int(v, "version") == 1 else {
            throw ParseError(line: v.mark?.line, path: "version", message: "must be 1")
        }

        var filesystem: Filesystem?
        if let fs = top["filesystem_policy"] { filesystem = try r.filesystem(fs) }
        var landlockHard: Bool?
        var runAs: (String?, String?) = (nil, nil)
        if let ll = top["landlock"] {
            let m = try r.mapping(ll, "landlock", allowed: ["compatibility"])
            if let c = m["compatibility"] {
                let s = try r.string(c, "landlock.compatibility")
                guard ["best_effort", "hard_requirement"].contains(s) else {
                    throw r.err(c, "landlock.compatibility", "must be best_effort or hard_requirement")
                }
                landlockHard = s == "hard_requirement"
            }
        }
        if let p = top["process"] { runAs = try r.process(p) }

        var rules: [NetworkRule] = []
        if let np = top["network_policies"], !r.isNull(np) {
            for (key, node) in try r.orderedMapping(np, "network_policies") {
                guard !key.hasPrefix("_provider_") else {
                    throw r.err(node, "network_policies.\(key)",
                                "rule keys starting with _provider_ are reserved")
                }
                rules.append(try r.networkRule(key: key, node))
            }
        }
        var middlewares: [Middleware] = []
        if let mw = top["network_middlewares"], !r.isNull(mw) { middlewares = try r.middlewares(mw) }

        if let message = findAmbiguity(rules) {
            throw ParseError(line: nil, path: "network_policies", message: "ambiguity validation failed: " + message)
        }
        // A fail_closed middleware can't select a `tls: skip` endpoint: that
        // traffic is never decrypted, so it could never be checked.
        for mw in middlewares where !mw.failOpen {
            for rule in rules {
                for ep in rule.endpoints where ep.tlsSkip {
                    if let h = ep.host, mw.selects(host: h) {
                        throw ParseError(line: nil, path: "network_middlewares.\(mw.key)",
                                         message: "fail_closed middleware selects \(h), a tls: skip endpoint it can't inspect")
                    }
                }
            }
        }
        var policy = OpenShellPolicy(networkPolicies: rules, source: yaml, warnings: r.warnings)
        policy.middlewares = middlewares
        policy.filesystem = filesystem
        policy.runAsUser = runAs.0
        policy.runAsGroup = runAs.1
        policy.landlockHardRequirement = landlockHard
        return policy
    }

}

// MARK: - Provider profiles

/// An OpenShell provider profile (`openshell profile export` YAML/JSON): the
/// credentials a provider type needs and the endpoints they're bound to.
/// Bromure imports one as workspace credentials (fake-swapped, bound to the
/// profile's hosts and paths) plus a `_provider_<name>` network rule.
public struct OpenShellProviderProfile: Sendable, Equatable {
    public struct Credential: Sendable, Equatable {
        public var name: String
        public var description: String
        public var envVars: [String]
        public var required: Bool
        public var authStyle: String?
    }
    public var id: String
    public var displayName: String
    public var description: String
    public var credentials: [Credential]
    public var endpoints: [OpenShellPolicy.Endpoint]
    public var binaries: [String]
    public var warnings: [String]

    /// Hosts the credentials are bound to (exact names, `*.`/`**.` reduced to
    /// their domain — Bromure host scopes match exact-or-subdomain).
    public var credentialHostScopes: [String] {
        var out: [String] = []
        for e in endpoints {
            guard let h = e.host else { continue }
            let scope = h.hasPrefix("**.") ? String(h.dropFirst(3)) : h.hasPrefix("*.") ? String(h.dropFirst(2)) : h
            if !scope.contains("*"), !out.contains(scope) { out.append(scope) }
        }
        return out
    }

    /// Path selectors the credentials are bound to — only when every endpoint
    /// narrows by path (otherwise the credential is valid on any path).
    public var credentialPathScopes: [String] {
        let paths = endpoints.map(\.path)
        guard !paths.isEmpty, paths.allSatisfy({ $0 != nil && $0 != "**" && $0 != "/**" }) else { return [] }
        return Array(Set(paths.compactMap { $0 })).sorted()
    }

    /// The profile's endpoints as a managed network rule (`_provider_<instance>`).
    public func networkRule(instanceName: String) -> OpenShellPolicy.NetworkRule {
        let key = "_provider_" + instanceName.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
            .reduce(into: "") { $0.append($1) }
        var eps = endpoints
        for i in eps.indices { eps[i].managed = true }
        return .init(key: key, name: key, endpoints: eps, binaries: binaries)
    }

    public static func parse(_ text: String) throws -> OpenShellProviderProfile {
        let root: Node?
        do { root = try Yams.compose(yaml: text) } catch {
            throw OpenShellPolicy.ParseError(line: nil, path: "", message: "invalid YAML: \(error)")
        }
        guard let root else { throw OpenShellPolicy.ParseError(line: nil, path: "", message: "empty profile") }
        var r = Reader()
        let m = try r.mapping(root, "", allowed: ["id", "resource_version", "annotations", "display_name",
                                                  "description", "category", "inference_capable", "credentials",
                                                  "discovery", "endpoints", "binaries"])
        guard let idNode = m["id"] else {
            throw OpenShellPolicy.ParseError(line: root.mark?.line, path: "id", message: "required field is missing")
        }
        let id = try r.string(idNode, "id")
        let display = try m["display_name"].map { try r.string($0, "display_name") } ?? id
        let desc = try m["description"].map { try r.string($0, "description") } ?? ""

        var creds: [Credential] = []
        if let cn = m["credentials"] {
            for (i, node) in try r.sequence(cn, "credentials").enumerated() {
                let path = "credentials[\(i)]"
                let c = try r.mapping(node, path, allowed: ["name", "description", "env_vars", "required",
                                                            "auth_style", "header_name", "query_param",
                                                            "path_template", "refresh", "token_grant"])
                guard let nn = c["name"] else { throw r.err(node, "\(path).name", "required field is missing") }
                let style = try c["auth_style"].map { try r.string($0, "\(path).auth_style") }
                if let style, !["basic", "bearer", "header", "query", "path", ""].contains(style) {
                    throw r.err(c["auth_style"], "\(path).auth_style", "must be basic, bearer, header, query or path")
                }
                if c["refresh"] != nil || c["token_grant"] != nil {
                    r.warn("credentials[\(i)]: refresh / token_grant aren't supported — the value you enter is used as a static credential")
                }
                creds.append(Credential(
                    name: try r.string(nn, "\(path).name"),
                    description: try c["description"].map { try r.string($0, "\(path).description") } ?? "",
                    envVars: try c["env_vars"].map { try r.strings($0, "\(path).env_vars") } ?? [],
                    required: try c["required"].map { try r.bool($0, "\(path).required") } ?? false,
                    authStyle: style))
            }
        }
        var endpoints: [OpenShellPolicy.Endpoint] = []
        if let en = m["endpoints"] {
            for (i, node) in try r.sequence(en, "endpoints").enumerated() {
                endpoints.append(try r.endpoint(node, "endpoints[\(i)]"))
            }
        }
        let binaries = try m["binaries"].map { try r.strings($0, "binaries") } ?? []
        if !binaries.isEmpty {
            r.warn("binaries: not enforced — each rule applies to every process in the VM (agents hold root in the guest, so process identity can't be trusted)")
        }
        return .init(id: id, displayName: display, description: desc, credentials: creds,
                     endpoints: endpoints, binaries: binaries, warnings: r.warnings)
    }
}

/// Node walker that tracks key paths, rejects unknown fields, and collects
/// "accepted but not enforced" warnings (deduplicated, in order).
private struct Reader {
    var warnings: [String] = []

    mutating func warn(_ s: String) { if !warnings.contains(s) { warnings.append(s) } }

    func err(_ n: Node?, _ path: String, _ msg: String) -> OpenShellPolicy.ParseError {
        OpenShellPolicy.ParseError(line: n?.mark?.line, path: path, message: msg)
    }

    func isNull(_ n: Node) -> Bool {
        if case .scalar(let s) = n, s.style == .plain {
            return ["", "~", "null", "Null", "NULL"].contains(s.string)
        }
        return false
    }

    func orderedMapping(_ n: Node, _ path: String) throws -> [(String, Node)] {
        guard let m = n.mapping else { throw err(n, path, "expected a mapping") }
        return try m.map { k, v in
            guard let ks = k.scalar?.string else { throw err(k, path, "keys must be strings") }
            return (ks, v)
        }
    }

    func mapping(_ n: Node, _ path: String, allowed: Set<String>) throws -> [String: Node] {
        var out: [String: Node] = [:]
        for (k, v) in try orderedMapping(n, path) {
            guard allowed.contains(k) else {
                throw err(v, path.isEmpty ? k : "\(path).\(k)", "unknown field")
            }
            out[k] = v
        }
        return out
    }

    func string(_ n: Node, _ path: String) throws -> String {
        guard let s = n.scalar, !isNull(n) || s.style != .plain else { throw err(n, path, "expected a string") }
        return s.string
    }

    func int(_ n: Node, _ path: String) throws -> Int {
        guard let s = n.scalar, s.style == .plain, let i = Int(s.string) else {
            throw err(n, path, "expected an integer")
        }
        return i
    }

    func bool(_ n: Node, _ path: String) throws -> Bool {
        guard let s = n.scalar, s.style == .plain else { throw err(n, path, "expected true or false") }
        switch s.string.lowercased() {
        case "true": return true
        case "false": return false
        default: throw err(n, path, "expected true or false")
        }
    }

    func sequence(_ n: Node, _ path: String) throws -> [Node] {
        if isNull(n) { return [] }
        guard let s = n.sequence else { throw err(n, path, "expected a list") }
        return Array(s)
    }

    func strings(_ n: Node, _ path: String) throws -> [String] {
        try sequence(n, path).enumerated().map { try string($0.element, "\(path)[\($0.offset)]") }
    }

    func port(_ n: Node, _ path: String) throws -> UInt16 {
        let p = try int(n, path)
        guard (1...65535).contains(p) else { throw err(n, path, "port must be 1-65535") }
        return UInt16(p)
    }

    // MARK: sections

    mutating func filesystem(_ n: Node) throws -> OpenShellPolicy.Filesystem {
        let m = try mapping(n, "filesystem_policy", allowed: ["include_workdir", "read_only", "read_write"])
        var includeWorkdir = false
        if let w = m["include_workdir"] { includeWorkdir = try bool(w, "filesystem_policy.include_workdir") }
        var lists: [String: [String]] = ["read_only": [], "read_write": []]
        var count = 0
        for key in ["read_only", "read_write"] {
            guard let list = m[key] else { continue }
            for (i, p) in try strings(list, "filesystem_policy.\(key)").enumerated() {
                let path = "filesystem_policy.\(key)[\(i)]"
                // Windows (MXC driver) policies use drive-letter paths.
                let windows = p.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
                guard p.hasPrefix("/") || windows else { throw err(list, path, "path must be absolute") }
                guard !p.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..") else {
                    throw err(list, path, "path must not contain '..'")
                }
                guard p.utf8.count <= 4096 else { throw err(list, path, "path exceeds 4096 bytes") }
                if key == "read_write", p == "/" { throw err(list, path, "read_write cannot contain /") }
                lists[key]!.append(p)
                count += 1
            }
        }
        guard count <= 256 else { throw err(n, "filesystem_policy", "at most 256 paths") }
        // Landlock rules add up: a read_write parent grants write to its whole
        // subtree, so a read_only path beneath it protects nothing (OpenShell
        // accepts this silently).
        func trimmed(_ p: String) -> String { p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p }
        for ro in lists["read_only"]! {
            let r = trimmed(ro)
            if let parent = lists["read_write"]!.map(trimmed).first(where: { $0 != r && (r.hasPrefix($0 == "/" ? "/" : $0 + "/")) }) {
                warn("filesystem_policy: \(ro) is read_only but sits under the read_write path \(parent), which already allows writing it — it is NOT protected")
            }
        }
        // The session's terminal server opens /dev/null for writing; without
        // it no agent session starts.
        if !lists["read_write"]!.contains(where: { ["/dev/null", "/dev", "/"].contains(trimmed($0)) }) {
            warn("filesystem_policy: /dev/null must be in read_write, or agent sessions can't start in the VM")
        }
        return .init(includeWorkdir: includeWorkdir, readOnly: lists["read_only"]!, readWrite: lists["read_write"]!)
    }

    mutating func process(_ n: Node) throws -> (String?, String?) {
        let m = try mapping(n, "process", allowed: ["run_as_user", "run_as_group"])
        var out: [String: String] = [:]
        for key in ["run_as_user", "run_as_group"] {
            guard let v = m[key] else { continue }
            let s = try string(v, "process.\(key)")
            out[key] = s
            if s == "sandbox" { continue }
            guard let id = UInt64(s), (1...4_294_967_294).contains(id) else {
                throw err(v, "process.\(key)", "must be 'sandbox' or a non-root numeric ID")
            }
        }
        return (out["run_as_user"], out["run_as_group"])
    }

    mutating func middlewares(_ n: Node) throws -> [OpenShellPolicy.Middleware] {
        let entries = try orderedMapping(n, "network_middlewares")
        guard entries.count <= 10 else { throw err(n, "network_middlewares", "at most 10 middlewares") }
        var orders = Set<Int>()
        var out: [OpenShellPolicy.Middleware] = []
        for (key, node) in entries {
            let path = "network_middlewares.\(key)"
            let m = try mapping(node, path, allowed: ["middleware", "endpoints", "order", "config", "on_error", "name"])
            guard let mw = m["middleware"] else { throw err(node, "\(path).middleware", "required field is missing") }
            let kind = try string(mw, "\(path).middleware")
            guard let eps = m["endpoints"] else { throw err(node, "\(path).endpoints", "required field is missing") }
            let em = try mapping(eps, "\(path).endpoints", allowed: ["include", "exclude"])
            guard let inc = em["include"] else { throw err(eps, "\(path).endpoints.include", "required field is missing") }
            let include = try strings(inc, "\(path).endpoints.include")
            let exclude = try em["exclude"].map { try strings($0, "\(path).endpoints.exclude") } ?? []
            guard !include.isEmpty else { throw err(eps, "\(path).endpoints.include", "required field is missing") }
            guard include.count + exclude.count <= 32 else { throw err(eps, "\(path).endpoints", "at most 32 host patterns") }
            for (i, h) in (include + exclude).enumerated() { try validateHost(h.lowercased(), eps, "\(path).endpoints[\(i)]") }
            let order = try m["order"].map { try int($0, "\(path).order") } ?? 0
            guard orders.insert(order).inserted else { throw err(node, "\(path).order", "order values must be unique") }
            var failOpen = false
            if let oe = m["on_error"] {
                let v = try string(oe, "\(path).on_error")
                guard ["fail_closed", "fail_open"].contains(v) else {
                    throw err(oe, "\(path).on_error", "must be fail_closed or fail_open")
                }
                failOpen = v == "fail_open"
            }
            if kind == "openshell/regex", let c = m["config"], !isNull(c) {
                let cm = try mapping(c, "\(path).config", allowed: ["mode"])
                if let mode = cm["mode"], try string(mode, "\(path).config.mode") != "redact" {
                    throw err(mode, "\(path).config.mode", "openshell/regex supports only mode: redact")
                }
            }
            if kind != "openshell/regex" {
                warn("network_middlewares.\(key): external middleware service '\(kind)' isn't reachable from Bromure — traffic it selects is \(failOpen ? "passed through (fail_open)" : "blocked (fail_closed)")")
            }
            out.append(.init(key: key, name: try m["name"].map { try string($0, "\(path).name") } ?? key,
                             kind: kind, include: include.map { $0.lowercased() },
                             exclude: exclude.map { $0.lowercased() }, order: order, failOpen: failOpen))
        }
        return out.sorted { $0.order < $1.order }
    }

    mutating func networkRule(key: String, _ n: Node) throws -> OpenShellPolicy.NetworkRule {
        let path = "network_policies.\(key)"
        let m = try mapping(n, path, allowed: ["name", "endpoints", "binaries"])
        let name = try m["name"].map { try string($0, "\(path).name") } ?? key
        var endpoints: [OpenShellPolicy.Endpoint] = []
        if let e = m["endpoints"] {
            for (i, en) in try sequence(e, "\(path).endpoints").enumerated() {
                endpoints.append(try endpoint(en, "\(path).endpoints[\(i)]"))
            }
        }
        var binaries: [String] = []
        if let b = m["binaries"] {
            for (i, bn) in try sequence(b, "\(path).binaries").enumerated() {
                let bp = "\(path).binaries[\(i)]"
                if bn.scalar != nil {
                    binaries.append(try string(bn, bp))
                } else {
                    let bm = try mapping(bn, bp, allowed: ["path"])
                    guard let p = bm["path"] else { throw err(bn, "\(bp).path", "required field is missing") }
                    binaries.append(try string(p, "\(bp).path"))
                }
            }
        }
        if !binaries.isEmpty {
            warn("binaries: not enforced — each rule applies to every process in the VM (agents hold root in the guest, so process identity can't be trusted)")
        }
        return .init(key: key, name: name, endpoints: endpoints, binaries: binaries)
    }

    private static let endpointFields: Set<String> = [
        "host", "port", "ports", "path", "allowed_ips", "protocol", "tls", "enforcement", "access",
        "rules", "deny_rules", "allow_encoded_slash", "credential_binding",
        "request_body_credential_rewrite", "websocket_credential_rewrite",
        "allow_uninspected_credentials", "credential_signing", "signing_service", "signing_region",
        "persisted_queries", "graphql_persisted_queries", "graphql_max_body_bytes", "mcp", "json_rpc",
    ]

    mutating func endpoint(_ n: Node, _ path: String) throws -> OpenShellPolicy.Endpoint {
        let m = try mapping(n, path, allowed: Self.endpointFields)
        func nonEmpty(_ k: String) throws -> String? {
            guard let v = m[k], !isNull(v) else { return nil }
            let s = try string(v, "\(path).\(k)")
            return s.isEmpty ? nil : s
        }

        // Destination.
        var host = try nonEmpty("host")?.lowercased()
        if let h = host { try validateHost(h, m["host"], "\(path).host") }
        var ports: [UInt16] = []
        if let p = m["port"], !isNull(p) { ports.append(try port(p, "\(path).port")) }
        if let ps = m["ports"] {
            let list = try sequence(ps, "\(path).ports")
            if !list.isEmpty && !ports.isEmpty { throw err(ps, "\(path).ports", "set port or ports, not both") }
            for (i, pn) in list.enumerated() { ports.append(try port(pn, "\(path).ports[\(i)]")) }
        }
        guard !ports.isEmpty else { throw err(n, "\(path).port", "set port or ports") }

        var allowedIPs: [OpenShellPolicy.IPv4Range] = []
        if let a = m["allowed_ips"] {
            // As OpenShell: bad entries don't stop the policy loading; the
            // route's connections are refused ("invalid allowed_ips") by the
            // destination check instead. Warn so the author sees it.
            for (i, s) in try strings(a, "\(path).allowed_ips").enumerated() {
                let ip = "\(path).allowed_ips[\(i)]"
                if s.contains(":") { continue }   // IPv6: honored by the destination check (raw entries)
                guard let r = Self.parseIPv4Range(s) else {
                    warn("\(ip): invalid IP address or CIDR '\(s)' — connections through this endpoint will be refused")
                    continue
                }
                if OpenShellPolicy.blockedRanges.contains(where: { $0.overlaps(r) }) {
                    warn("\(ip): '\(s)' overlaps a blocked range (loopback, link-local or unspecified) — connections through this endpoint will be refused")
                    continue
                }
                allowedIPs.append(r)
            }
        }
        if host == nil {
            guard m["allowed_ips"].map({ (try? strings($0, "")).map { !$0.isEmpty } ?? false }) ?? false else {
                throw err(n, "\(path).host", "set host or allowed_ips")
            }
        }
        if let h = host, EgressPolicy.parseIPv4(h) != nil, allowedIPs.isEmpty {
            // An IP-literal host is its own allowed address.
            allowedIPs = [Self.parseIPv4Range(h)!]
            host = h
        }

        // Inspection.
        var l7: OpenShellPolicy.L7Protocol?
        if let p = try nonEmpty("protocol") {
            guard let pr = OpenShellPolicy.L7Protocol(rawValue: p.lowercased()) else {
                throw err(m["protocol"], "\(path).protocol", "must be rest, websocket, graphql, mcp, json-rpc or tcp")
            }
            l7 = pr
        }
        var tlsSkip = false
        if let t = try nonEmpty("tls") {
            guard t == "skip" else { throw err(m["tls"], "\(path).tls", "only 'skip' is supported") }
            tlsSkip = true
        }
        var enforcement = OpenShellPolicy.Enforcement.audit
        let enforcementSet = try nonEmpty("enforcement")
        if let e = enforcementSet {
            guard let en = OpenShellPolicy.Enforcement(rawValue: e) else {
                throw err(m["enforcement"], "\(path).enforcement", "must be enforce or audit")
            }
            enforcement = en
        }
        var access: OpenShellPolicy.AccessPreset?
        if let a = try nonEmpty("access") {
            guard let ap = OpenShellPolicy.AccessPreset(rawValue: a) else {
                throw err(m["access"], "\(path).access", "must be read-only, read-write or full")
            }
            access = ap
        }
        let allowSlash = try m["allow_encoded_slash"].map { try bool($0, "\(path).allow_encoded_slash") } ?? false
        let pathSel = try nonEmpty("path")
        if let ps = pathSel, !ps.hasPrefix("/"), ps != "**" {
            throw err(m["path"], "\(path).path", "path selector must start with /")
        }

        let ruleNodes = try m["rules"].map { try sequence($0, "\(path).rules") } ?? []
        let denyNodes = try m["deny_rules"].map { try sequence($0, "\(path).deny_rules") } ?? []
        let hasRequestFields = access != nil || !ruleNodes.isEmpty || !denyNodes.isEmpty
            || enforcementSet != nil || pathSel != nil || allowSlash

        // Constraints (schema "Endpoint Constraints").
        if l7 == .tcp {
            guard host != nil else { throw err(n, "\(path).host", "protocol: tcp requires a hostname") }
            if hasRequestFields {
                throw err(n, path, "protocol: tcp accepts no request fields (path, enforcement, access, rules)")
            }
        }
        if access != nil && !ruleNodes.isEmpty {
            throw err(m["rules"], "\(path).rules", "access and rules cannot be combined")
        }
        if tlsSkip, let l7, l7.inspects {
            throw err(m["tls"], "\(path).tls", "tls: skip cannot be used with a request protocol")
        }
        let mcpOpts = try mcpOptions(m["mcp"], "\(path).mcp")
        let mcpAllowAll = mcpOpts.allowAllKnown
        switch l7 {
        case .rest?, .websocket?, .graphql?:
            if access == nil && ruleNodes.isEmpty {
                throw err(n, path, "\(l7!.rawValue) endpoints need access or rules")
            }
        case .mcp?:
            if ruleNodes.isEmpty && !mcpAllowAll {
                throw err(n, path, "mcp endpoints need rules (or mcp.allow_all_known_mcp_methods: true)")
            }
        case .jsonRPC?:
            if ruleNodes.isEmpty { throw err(n, path, "json-rpc endpoints need rules") }
        default: break
        }
        if !denyNodes.isEmpty {
            guard l7 != nil else { throw err(m["deny_rules"], "\(path).deny_rules", "deny_rules require protocol") }
            if l7 != .mcp, access == nil, ruleNodes.isEmpty {
                throw err(m["deny_rules"], "\(path).deny_rules", "deny_rules require rules or access")
            }
        }
        if l7 == nil, (access != nil || !ruleNodes.isEmpty) {
            warn("access / rules without protocol have no effect (\(path))")
        }

        // Rules, by protocol.
        var rules: [OpenShellPolicy.RequestMatcher] = []
        var denies: [OpenShellPolicy.RequestMatcher] = []
        var rpcRules: [OpenShellPolicy.RPCMatcher] = []
        var rpcDenies: [OpenShellPolicy.RPCMatcher] = []
        var gqlRules: [OpenShellPolicy.GraphQLMatcher] = []
        var gqlDenies: [OpenShellPolicy.GraphQLMatcher] = []
        func collect(_ node: Node, _ rp: String, deny: Bool) throws {
            switch l7 {
            case .mcp?, .jsonRPC?:
                let r = try rpcMatcher(node, rp, mcp: l7 == .mcp, options: mcpOpts)
                if deny { rpcDenies.append(r) } else { rpcRules.append(r) }
            case .graphql?:
                let r = try graphqlMatcher(node, rp, isDeny: deny)
                if deny { gqlDenies.append(r) } else { gqlRules.append(r) }
            case .websocket? where graphQLRuleFields(node):
                // GraphQL-over-WebSocket operation policy (l7/mod.rs).
                let m = try mapping(node, rp, allowed: ["method", "path", "query", "command", "operation_type",
                                                        "operation_name", "fields", "tool", "params"])
                if m["method"] != nil || m["path"] != nil || m["query"] != nil {
                    throw err(node, rp, "WebSocket GraphQL \(deny ? "deny" : "allow") rules must not combine method/path/query with operation_type/operation_name/fields")
                }
                let r = try graphqlMatcher(node, rp, isDeny: deny)
                if deny { gqlDenies.append(r) } else { gqlRules.append(r) }
            default:
                guard let r = try matcher(node, rp) else { return }
                if deny { denies.append(r) } else { rules.append(r) }
            }
        }
        /// `has_graphql_rule_fields`: a non-empty operation_type /
        /// operation_name, or a non-empty fields list.
        func graphQLRuleFields(_ node: Node) -> Bool {
            guard let map = node.mapping else { return false }
            for (k, v) in map {
                switch k.scalar?.string {
                case "operation_type"?, "operation_name"?:
                    if let sv = v.scalar?.string, !isNull(v), !sv.isEmpty { return true }
                case "fields"?:
                    if let seq = v.sequence, !seq.isEmpty { return true }
                default: break
                }
            }
            return false
        }
        for (i, rn) in ruleNodes.enumerated() {
            let rp = "\(path).rules[\(i)]"
            let wrapper = try mapping(rn, rp, allowed: ["allow"])
            guard let body = wrapper["allow"] else { throw err(rn, "\(rp).allow", "required field is missing") }
            try collect(body, "\(rp).allow", deny: false)
        }
        for (i, dn) in denyNodes.enumerated() {
            try collect(dn, "\(path).deny_rules[\(i)]", deny: true)
        }
        if l7 == .websocket, !gqlRules.isEmpty || !gqlDenies.isEmpty,
           let i = rules.firstIndex(where: { $0.method.uppercased() == "WEBSOCKET_TEXT" }) {
            throw err(m["rules"], "\(path).rules[\(i)].allow",
                      "WebSocket endpoints with GraphQL operation policy must use operation_type/operation_name/fields rules for client messages instead of WEBSOCKET_TEXT")
        }
        // OpenShell l7/mod.rs: once any allow rule selects tools, a tool-less
        // rule whose method matcher covers tools/call (allow or deny) would
        // swallow every tool call — refused.
        if l7 == .mcp, rpcRules.contains(where: { $0.tool != nil }) {
            func coversToolsCall(_ r: OpenShellPolicy.RPCMatcher, allowSide: Bool) -> Bool {
                guard r.tool == nil else { return false }
                guard let method = r.method else { return allowSide && mcpAllowAll }
                return method == "tools/call" || method == "*"
                    || Glob.match(method, "tools/call", separator: nil, caseInsensitive: false)
            }
            if let i = rpcRules.firstIndex(where: { coversToolsCall($0, allowSide: true) }) {
                throw err(ruleNodes[i], "\(path).rules[\(i)].allow",
                          "method matcher allows every tool call and conflicts with MCP tool allow rules; add tool or params.name to narrow tools/call, or remove the tool allow rules")
            }
            if let i = rpcDenies.firstIndex(where: { coversToolsCall($0, allowSide: false) }) {
                throw err(denyNodes[i], "\(path).deny_rules[\(i)]",
                          "method matcher denies every tool call and conflicts with MCP tool allow rules; add tool or params.name to deny specific tools, or remove the tool allow rules")
            }
        }

        // Protocol options.
        var jsonRPCMax = 65_536
        if let jr = m["json_rpc"], !isNull(jr) {
            let jm = try mapping(jr, "\(path).json_rpc", allowed: ["max_body_bytes"])
            if let b = jm["max_body_bytes"] {
                let v = try int(b, "\(path).json_rpc.max_body_bytes")
                guard v >= 0 else { throw err(b, "\(path).json_rpc.max_body_bytes", "must be a non-negative integer") }
                if v > 0 { jsonRPCMax = v }                // 0 = the default (OpenShell drops it)
            }
        }
        let graphqlMax = try m["graphql_max_body_bytes"].map { n -> Int in
            let v = try int(n, "\(path).graphql_max_body_bytes")
            guard v > 0 else { throw err(n, "\(path).graphql_max_body_bytes", "graphql_max_body_bytes must be a positive integer") }
            return v
        } ?? 65_536
        var allowRegistered = false
        if let pq = try nonEmpty("persisted_queries") {
            guard ["deny", "allow_registered"].contains(pq) else {
                throw err(m["persisted_queries"], "\(path).persisted_queries", "must be deny or allow_registered")
            }
            allowRegistered = pq == "allow_registered"
        }
        var registry: [String: OpenShellPolicy.GraphQLOperation] = [:]
        if let reg = m["graphql_persisted_queries"], !isNull(reg) {
            for (hash, node) in try orderedMapping(reg, "\(path).graphql_persisted_queries") {
                let rp = "\(path).graphql_persisted_queries.\(hash)"
                let rm = try mapping(node, rp, allowed: ["operation_type", "operation_name", "fields"])
                guard let t = rm["operation_type"] else { throw err(node, "\(rp).operation_type", "required field is missing") }
                let type = try string(t, "\(rp).operation_type")
                guard ["query", "mutation", "subscription"].contains(type) else {
                    throw err(t, "\(rp).operation_type", "must be query, mutation or subscription")
                }
                registry[hash] = .init(type: type,
                                       name: try rm["operation_name"].map { try string($0, "\(rp).operation_name") },
                                       fields: try rm["fields"].map { try strings($0, "\(rp).fields") } ?? [])
            }
        }
        // `request_body_credential_rewrite` / `websocket_credential_rewrite`
        // are honored for OpenShell credential placeholders (a workspace
        // option); the rest describe OpenShell providers, which Bromure
        // replaces with its own per-credential host scoping and signing.
        for k in ["credential_binding", "allow_uninspected_credentials", "credential_signing",
                  "signing_service", "signing_region"]
        where m[k] != nil && !isNull(m[k]!) {
            warn("\(k): ignored — Bromure binds each credential to its own hosts and signs AWS requests itself")
        }
        if m["credential_signing"] != nil, m["signing_service"] == nil {
            throw err(n, "\(path).signing_service", "required with credential_signing")
        }

        var ep = OpenShellPolicy.Endpoint(
            host: host, ports: ports, path: pathSel, allowedIPs: allowedIPs, l7: l7,
            tlsSkip: tlsSkip, enforcement: enforcement, access: access, rules: rules,
            denyRules: denies, allowEncodedSlash: allowSlash)
        ep.rpcRules = rpcRules
        ep.rpcDenyRules = rpcDenies
        ep.mcp = mcpOpts
        ep.jsonRPCMaxBody = jsonRPCMax
        ep.gqlRules = gqlRules
        ep.gqlDenyRules = gqlDenies
        ep.graphqlMaxBody = graphqlMax
        ep.persistedQueriesAllowRegistered = allowRegistered
        ep.graphqlRegistry = registry
        var keys = OpenShellPolicy.AmbiguityKeys()
        if let a = m["allowed_ips"] { keys.allowedIPsRaw = try strings(a, "\(path).allowed_ips") }
        func flag(_ k: String) throws -> Bool { try m[k].map { isNull($0) ? false : try bool($0, "\(path).\(k)") } ?? false }
        keys.websocketCredentialRewrite = try flag("websocket_credential_rewrite")
        keys.requestBodyCredentialRewrite = try flag("request_body_credential_rewrite")
        keys.credentialSigning = try nonEmpty("credential_signing") ?? ""
        keys.signingService = try nonEmpty("signing_service") ?? ""
        keys.signingRegion = try nonEmpty("signing_region") ?? ""
        if let cb = m["credential_binding"], !isNull(cb) {
            keys.hasCredentialBinding = true
            if let prov = try mapping(cb, "\(path).credential_binding", allowed: ["provider"])["provider"] {
                keys.credentialBindingProvider = try string(prov, "\(path).credential_binding.provider")
            }
        }
        ep.ambiguity = keys
        return ep
    }

    private func mcpOptions(_ n: Node?, _ path: String) throws -> OpenShellPolicy.MCPOptions {
        var o = OpenShellPolicy.MCPOptions()
        guard let n, !isNull(n) else { return o }
        let m = try mapping(n, path, allowed: ["versions", "max_body_bytes", "strict_tool_names",
                                                "allow_all_known_mcp_methods"])
        if let v = m["versions"] {
            let list = try strings(v, "\(path).versions")
            for (i, s) in list.enumerated() where !OpenShellPolicy.knownMCPVersions.contains(s) {
                throw err(v, "\(path).versions[\(i)]", "unsupported MCP revision '\(s)'")
            }
            if !list.isEmpty { o.versions = list }
        }
        if let b = m["max_body_bytes"] {
            let v = try int(b, "\(path).max_body_bytes")
            guard v >= 0 else { throw err(b, "\(path).max_body_bytes", "must be a non-negative integer") }
            if v > 0 { o.maxBody = v }                     // 0 = the default
        }
        if let s = m["strict_tool_names"] { o.strictToolNames = try bool(s, "\(path).strict_tool_names") }
        if let a = m["allow_all_known_mcp_methods"] { o.allowAllKnown = try bool(a, "\(path).allow_all_known_mcp_methods") }
        return o
    }

    /// A string-or-`{ any: [globs] }` matcher.
    private func globList(_ n: Node, _ path: String) throws -> [String] {
        if n.scalar != nil { return [try string(n, path)] }
        let m = try mapping(n, path, allowed: ["any", "glob"])
        var globs = try m["any"].map { try strings($0, "\(path).any") } ?? []
        if let g = m["glob"] { globs.append(try string(g, "\(path).glob")) }
        guard !globs.isEmpty else { throw err(n, path, "empty matcher") }
        return globs
    }

    /// An MCP / JSON-RPC matcher (schema "MCP Rules" / "JSON-RPC Rules").
    private func rpcMatcher(_ n: Node, _ path: String, mcp: Bool,
                            options: OpenShellPolicy.MCPOptions) throws -> OpenShellPolicy.RPCMatcher {
        let m = try mapping(n, path, allowed: ["method", "path", "query", "command", "operation_type",
                                                "operation_name", "fields", "tool", "params"])
        var method: String?
        if let mn = m["method"], !isNull(mn) {
            let s = try string(mn, "\(path).method")
            method = s.isEmpty ? nil : s
        }
        if let method {
            let glob = method.contains("*") || method.contains("?") || method.contains("[")
            if mcp {
                if method == "*" { throw err(m["method"], "\(path).method", "'*' is not allowed for MCP; use mcp.allow_all_known_mcp_methods") }
                if glob, !method.hasPrefix("tools/") {
                    throw err(m["method"], "\(path).method", "globs are allowed only in the tools/ family")
                }
            } else if glob, method != "*" {
                throw err(m["method"], "\(path).method", "JSON-RPC methods must be exact or '*'")
            }
        } else if !(mcp && options.allowAllKnown) {
            throw err(n, "\(path).method", "required field is missing")
        }
        var tool: [String]?
        if mcp {
            if let t = m["tool"], !isNull(t) { tool = try globList(t, "\(path).tool") }
            if let p = m["params"], !isNull(p) {
                let pm = try mapping(p, "\(path).params", allowed: ["name"])
                if let nn = pm["name"] { tool = (tool ?? []) + (try globList(nn, "\(path).params.name")) }
            }
            if tool != nil, method != "tools/call", !options.allowAllKnown {
                throw err(n, "\(path).method", "rules with tool must set method: tools/call")
            }
            if let tool, tool.contains(where: { $0.contains("*") }), !options.strictToolNames {
                throw err(n, "\(path).tool", "wildcard tool matchers require mcp.strict_tool_names: true")
            }
        }
        return .init(method: method, tool: tool)
    }

    /// A GraphQL matcher (schema "GraphQL Rules").
    private func graphqlMatcher(_ n: Node, _ path: String, isDeny: Bool) throws -> OpenShellPolicy.GraphQLMatcher {
        let m = try mapping(n, path, allowed: ["method", "path", "query", "command", "operation_type",
                                                "operation_name", "fields", "tool", "params"])
        guard let tn = m["operation_type"] else { throw err(n, "\(path).operation_type", "required field is missing") }
        let type = try string(tn, "\(path).operation_type")
        guard ["query", "mutation", "subscription"].contains(type) else {
            throw err(tn, "\(path).operation_type", "must be query, mutation or subscription")
        }
        let name = try m["operation_name"].flatMap { isNull($0) ? nil : try string($0, "\(path).operation_name") }
        var fields: [String]?
        if let f = m["fields"], !isNull(f) {
            let list = try strings(f, "\(path).fields")
            fields = list.isEmpty ? nil : list
        }
        return .init(operationType: type, operationName: name?.isEmpty == true ? nil : name, fields: fields)
    }

    /// One REST / WebSocket allow body or deny rule.
    private func matcher(_ n: Node, _ path: String) throws -> OpenShellPolicy.RequestMatcher? {
        let m = try mapping(n, path, allowed: ["method", "path", "query", "command", "operation_type",
                                                "operation_name", "fields", "tool", "params"])
        guard let mn = m["method"], let method = Optional(try string(mn, "\(path).method")), !method.isEmpty else {
            throw err(n, "\(path).method", "required field is missing")
        }
        guard let pn = m["path"], let p = Optional(try string(pn, "\(path).path")), !p.isEmpty else {
            throw err(n, "\(path).path", "required field is missing")
        }
        var query: [String: OpenShellPolicy.QueryMatcher] = [:]
        if let q = m["query"], !isNull(q) {
            for (k, v) in try orderedMapping(q, "\(path).query") {
                if v.scalar != nil {
                    query[k] = .init(globs: [try string(v, "\(path).query.\(k)")])
                } else {
                    let vm = try mapping(v, "\(path).query.\(k)", allowed: ["any", "glob"])
                    var globs = try vm["any"].map { try strings($0, "\(path).query.\(k).any") } ?? []
                    if let g = vm["glob"] { globs.append(try string(g, "\(path).query.\(k).glob")) }
                    guard !globs.isEmpty else { throw err(v, "\(path).query.\(k)", "empty matcher") }
                    query[k] = .init(globs: globs)
                }
            }
        }
        return .init(method: method.uppercased(), path: p, query: query)
    }

    // MARK: helpers

    /// Schema: a wildcard host needs at least three DNS labels; `*` may appear
    /// within the first label or as a whole later label; `**` only as the
    /// whole first label.
    private func validateHost(_ h: String, _ n: Node?, _ path: String) throws {
        guard !h.contains("/"), !h.contains(":") || h.hasPrefix("[") else {
            throw err(n, path, "host must be a hostname, IP address or wildcard pattern")
        }
        guard h.contains("*") else { return }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3, !labels.contains(where: \.isEmpty) else {
            throw err(n, path, "a wildcard host needs at least three DNS labels")
        }
        for (i, l) in labels.enumerated() {
            if l.contains("**") {
                guard i == 0, l == "**" else { throw err(n, path, "'**' is allowed only as the whole first label") }
            } else if l.contains("*"), i > 0, l != "*" {
                throw err(n, path, "'*' in a later label must be the whole label")
            }
        }
    }

    static func parseIPv4Range(_ s: String) -> OpenShellPolicy.IPv4Range? {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, let ip = EgressPolicy.parseIPv4(String(parts[0])) else { return nil }
        var bits: UInt32 = 32
        if parts.count == 2 {
            guard let b = UInt32(parts[1]), b <= 32 else { return nil }
            bits = b
        }
        let mask: UInt32 = bits == 0 ? 0 : (0xFFFF_FFFF << (32 - bits))
        return .init(net: ip & mask, mask: mask)
    }
}
