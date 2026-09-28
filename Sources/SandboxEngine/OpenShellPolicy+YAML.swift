import Foundation

// MARK: - YAML emission + in-place rule insertion
//
// Used by the policy advisor (an approved proposal becomes a rule appended to
// the workspace's own policy text, comments and layout untouched) and by
// `policy.local`'s `GET /v1/policy/current` (the effective policy, including
// the provider rules Bromure composes).

extension OpenShellPolicy {
    /// One network rule as a YAML mapping entry (`key:` + body), each line
    /// prefixed by `indent`. Strings are emitted as JSON string literals —
    /// valid YAML double-quoted scalars — so no value can break the layout.
    public static func yaml(rule: NetworkRule, indent: String = "  ") -> String {
        var lines: [String] = []
        func q(_ s: String) -> String {
            let d = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data()
            let arr = String(decoding: d, as: UTF8.self)
            return String(arr.dropFirst().dropLast())
        }
        func list(_ xs: [String]) -> String { "[" + xs.map(q).joined(separator: ", ") + "]" }
        func add(_ depth: Int, _ s: String) { lines.append(indent + String(repeating: "  ", count: depth) + s) }

        add(0, "\(q(rule.key)):")
        if rule.name != rule.key { add(1, "name: \(q(rule.name))") }
        add(1, "endpoints:")
        for ep in rule.endpoints {
            var first = true
            func field(_ s: String) { add(2, (first ? "- " : "  ") + s); first = false }
            if let h = ep.host { field("host: \(q(h))") }
            if ep.ports.count == 1 { field("port: \(ep.ports[0])") }
            else { field("ports: [" + ep.ports.map(String.init).joined(separator: ", ") + "]") }
            if let p = ep.path { field("path: \(q(p))") }
            let ips = ep.allowedIPs.filter { !(ep.host.flatMap(EgressPolicy.parseIPv4) == $0.net && $0.mask == 0xFFFF_FFFF) }
            if !ips.isEmpty {
                field("allowed_ips: " + list(ips.map { r in
                    let bits = r.mask == 0 ? 0 : 32 - r.mask.trailingZeroBitCount
                    return bits == 32 ? EgressPolicy.ipv4String(r.net) : "\(EgressPolicy.ipv4String(r.net))/\(bits)"
                }))
            }
            if let l7 = ep.l7 { field("protocol: \(l7.rawValue)") }
            if ep.tlsSkip { field("tls: skip") }
            if ep.l7?.inspects == true { field("enforcement: \(ep.enforcement.rawValue)") }
            if let a = ep.access { field("access: \(a.rawValue)") }
            if ep.allowEncodedSlash { field("allow_encoded_slash: true") }
            func restMatcher(_ m: RequestMatcher) -> String {
                var parts = ["method: \(q(m.method))", "path: \(q(m.path))"]
                if !m.query.isEmpty {
                    let qs = m.query.keys.sorted().map { k in "\(q(k)): { any: \(list(m.query[k]!.globs)) }" }
                    parts.append("query: { " + qs.joined(separator: ", ") + " }")
                }
                return "{ " + parts.joined(separator: ", ") + " }"
            }
            func rpcMatcher(_ m: RPCMatcher) -> String {
                var parts: [String] = []
                if let method = m.method { parts.append("method: \(q(method))") }
                if let t = m.tool { parts.append("tool: { any: \(list(t)) }") }
                return "{ " + parts.joined(separator: ", ") + " }"
            }
            func gqlMatcher(_ m: GraphQLMatcher) -> String {
                var parts = ["operation_type: \(m.operationType)"]
                if let n = m.operationName { parts.append("operation_name: \(q(n))") }
                if let f = m.fields { parts.append("fields: \(list(f))") }
                return "{ " + parts.joined(separator: ", ") + " }"
            }
            let allows = ep.rules.map(restMatcher) + ep.rpcRules.map(rpcMatcher) + ep.gqlRules.map(gqlMatcher)
            if ep.access == nil, !allows.isEmpty {
                field("rules:")
                for a in allows { add(3, "- allow: \(a)") }
            }
            let denies = ep.denyRules.map(restMatcher) + ep.rpcDenyRules.map(rpcMatcher) + ep.gqlDenyRules.map(gqlMatcher)
            if !denies.isEmpty {
                field("deny_rules:")
                for d in denies { add(3, "- \(d)") }
            }
            if ep.l7 == .mcp, ep.mcp != MCPOptions() {
                var parts = ["versions: \(list(ep.mcp.versions))"]
                if ep.mcp.allowAllKnown { parts.append("allow_all_known_mcp_methods: true") }
                if !ep.mcp.strictToolNames { parts.append("strict_tool_names: false") }
                if ep.mcp.maxBody != 65_536 { parts.append("max_body_bytes: \(ep.mcp.maxBody)") }
                field("mcp: { " + parts.joined(separator: ", ") + " }")
            }
        }
        if !rule.binaries.isEmpty {
            add(1, "binaries:")
            for b in rule.binaries { add(2, "- path: \(q(b))") }
        }
        return lines.joined(separator: "\n")
    }

    /// The effective policy as YAML: the authored source, then the rules
    /// Bromure composes (`_provider_*`), which aren't part of `source`.
    public var effectiveYAML: String {
        let managed = networkPolicies.filter { $0.key.hasPrefix("_provider_") }
        guard !managed.isEmpty else { return source }
        let block = managed.map { Self.yaml(rule: $0) }.joined(separator: "\n")
        return (try? Self.insertingRules(block, into: source))
            ?? source + "\n# Rules Bromure adds:\nnetwork_policies:\n" + block + "\n"
    }

    /// `source` with `block` (rules emitted at two-space indent) appended to its
    /// `network_policies` mapping — the rest of the text, comments included,
    /// is left exactly as written. Throws when the result wouldn't parse (a
    /// flow-style `network_policies: {…}` can't be extended in place).
    public static func insertingRules(_ block: String, into source: String) throws -> String {
        var lines = source.components(separatedBy: "\n")
        let isTopLevelKey: (String) -> Bool = { l in
            guard let c = l.first else { return false }
            return c != " " && c != "\t" && c != "#" && c != "-"
        }
        if let start = lines.firstIndex(where: { $0.hasPrefix("network_policies:") }) {
            let rest = lines[start].dropFirst("network_policies:".count)
                .trimmingCharacters(in: .whitespaces)
            guard rest.isEmpty || rest.hasPrefix("#") else {
                throw ParseError(line: start + 1, path: "network_policies",
                                 message: "can't add a rule to a flow-style network_policies mapping")
            }
            // The section ends at the next top-level key; its children's
            // indentation (default two spaces) is reused for the new rule.
            let end = ((start + 1)..<lines.count).first { isTopLevelKey(lines[$0]) } ?? lines.count
            var indent = "  "
            if let child = firstChild(lines, after: start), child < end {
                indent = String(lines[child].prefix { $0 == " " })
            }
            // Insert after the last non-blank line of the section.
            var at = end
            while at > start + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
            let reindented = block.components(separatedBy: "\n").map { l in
                l.hasPrefix("  ") ? indent + l.dropFirst(2) : l
            }
            lines.insert(contentsOf: reindented, at: at)
        } else {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines.append("")
            lines.append("network_policies:")
            lines.append(contentsOf: block.components(separatedBy: "\n"))
        }
        let out = lines.joined(separator: "\n") + (source.hasSuffix("\n") ? "" : "\n")
        _ = try OpenShellPolicy.parse(out)
        return out.hasSuffix("\n\n") ? String(out.dropLast()) : out
    }

    private static func firstChild(_ lines: [String], after start: Int) -> Int? {
        for i in (start + 1)..<lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            return i
        }
        return nil
    }
}
