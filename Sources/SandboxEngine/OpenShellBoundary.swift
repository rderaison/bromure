import Foundation

/// Boundary check: does a candidate policy allow anything a boundary policy
/// (an organization's maximum) doesn't? Same question, result names and
/// semantics as NVIDIA's `openshell-prover check candidate --boundary b`;
/// Bromure runs the real prover when it's installed and falls back to this
/// native checker, which is conservative: whatever it can't decide exactly is
/// `unsupported`, never a pass (only `withinBoundary` counts as passing).
public enum OpenShellBoundary {
    public enum Result: Sendable, Equatable {
        case withinBoundary
        case exceedsBoundary(counterexample: String)
        case unsupported(reason: String)
        case error(String)

        public var passed: Bool { self == .withinBoundary }
        public var summary: String {
            switch self {
            case .withinBoundary: return "within boundary"
            case .exceedsBoundary(let c): return "exceeds boundary: \(c)"
            case .unsupported(let r): return "can't be checked: \(r)"
            case .error(let e): return "check failed: \(e)"
            }
        }
    }

    public static func check(candidate: OpenShellPolicy, boundary: OpenShellPolicy) -> Result {
        if let r = checkFilesystem(candidate, boundary) { return r }
        if let r = checkProcess(candidate, boundary) { return r }
        if let r = checkLandlock(candidate, boundary) { return r }
        for rule in candidate.networkPolicies {
            for ep in rule.endpoints {
                // Checked both with binary identity enforced and without
                // (a runtime may turn enforcement off), like the prover.
                for enforce in [false, true] {
                    if enforce, rule.binaries.isEmpty { continue }      // allows nothing
                    if let r = covered(ep, binaries: enforce ? rule.binaries : nil, in: boundary, rule: rule.key) {
                        return r
                    }
                }
            }
        }
        return .withinBoundary
    }

    // MARK: Filesystem / process / Landlock (path-by-path, like the prover)

    static func checkFilesystem(_ c: OpenShellPolicy, _ b: OpenShellPolicy) -> Result? {
        guard let cf = c.filesystem else { return nil }
        let bf = b.filesystem ?? .init(includeWorkdir: false, readOnly: [], readWrite: [])
        if cf.includeWorkdir, !bf.includeWorkdir {
            return .unsupported(reason: "candidate depends on the sandbox working directory")
        }
        func check(_ path: String, write: Bool) -> Result? {
            let allowed = write ? bf.readWrite : bf.readOnly + bf.readWrite
            if allowed.contains(path) || (!write && bf.readOnly.contains("/")) { return nil }
            let nested = allowed.contains { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            if nested { return .unsupported(reason: "\(path) is inside a boundary path, not equal to one") }
            return .exceedsBoundary(counterexample: "filesystem \(write ? "write" : "read") \(path)")
        }
        for p in cf.readWrite { if let r = check(p, write: true) { return r } }
        for p in cf.readOnly { if let r = check(p, write: false) { return r } }
        return nil
    }

    static func checkProcess(_ c: OpenShellPolicy, _ b: OpenShellPolicy) -> Result? {
        for (cv, bv, field) in [(c.runAsUser, b.runAsUser, "run_as_user"), (c.runAsGroup, b.runAsGroup, "run_as_group")] {
            guard let cv, cv != bv else { continue }
            if bv == nil { return .unsupported(reason: "boundary sets no \(field)") }
            return .unsupported(reason: "\(field) \(cv) differs from the boundary's \(bv!)")
        }
        return nil
    }

    static func checkLandlock(_ c: OpenShellPolicy, _ b: OpenShellPolicy) -> Result? {
        if b.landlockHardRequirement == true, c.landlockHardRequirement != true {
            return .exceedsBoundary(counterexample: "landlock best_effort (boundary requires hard_requirement)")
        }
        return nil
    }

    // MARK: Network

    /// nil when some boundary rule covers the candidate endpoint.
    static func covered(_ ep: OpenShellPolicy.Endpoint, binaries: [String]?, in boundary: OpenShellPolicy,
                        rule: String) -> Result? {
        let label = "\(rule): \(ep.host ?? "(allowed_ips)"):\(ep.ports.map(String.init).joined(separator: ","))"
        if let l7 = ep.l7, [.graphql, .mcp, .jsonRPC, .websocket].contains(l7) {
            return .unsupported(reason: "\(label) uses protocol \(l7.rawValue); only L4 and REST are modeled")
        }
        var lastUnsupported: String?
        for bRule in boundary.networkPolicies {
            if let bins = binaries {
                switch binariesCovered(bins, by: bRule.binaries) {
                case .no: continue
                case .unsupported(let r): lastUnsupported = r; continue
                case .yes: break
                }
            }
            for bEp in bRule.endpoints {
                switch endpointCovered(ep, by: bEp) {
                case .yes: return nil
                case .no: continue
                case .unsupported(let r): lastUnsupported = r
                }
            }
        }
        if let lastUnsupported { return .unsupported(reason: "\(label): \(lastUnsupported)") }
        let who = binaries.map { " for " + $0.joined(separator: ", ") } ?? ""
        return .exceedsBoundary(counterexample: "network \(label)\(who)")
    }

    enum Cover { case yes, no, unsupported(String) }

    static func binariesCovered(_ candidate: [String], by boundary: [String]) -> Cover {
        for c in candidate {
            if boundary.contains(c) { continue }
            let cGlob = c.contains("*") || c.contains("?") || c.contains("[")
            if !cGlob, boundary.contains(where: { $0.contains("*") && Glob.match($0, c, separator: "/", caseInsensitive: false) }) {
                return .unsupported("exact binary \(c) is covered only by a glob (a symlink could escape it)")
            }
            if cGlob { return .unsupported("binary glob \(c) isn't one of the boundary's") }
            return .no
        }
        return .yes
    }

    static func endpointCovered(_ c: OpenShellPolicy.Endpoint, by b: OpenShellPolicy.Endpoint) -> Cover {
        guard Set(c.ports).isSubset(of: Set(b.ports)) else { return .no }
        // Host.
        switch (c.host, b.host) {
        case (nil, _?): return .no
        case (_?, nil):
            // A hostless boundary endpoint covers only via allowed_ips.
            guard !c.allowedIPs.isEmpty else { return .no }
        case let (ch?, bh?):
            if ch != bh {
                if ch.contains("*") {
                    // Wildcard in the candidate: only an identical or a `**.`
                    // superset pattern is decidable.
                    guard bh.hasPrefix("**."), ch.hasSuffix(String(bh.dropFirst(2))) else {
                        return bh.contains("*") ? .unsupported("wildcard hosts \(ch) and \(bh) overlap undecidably") : .no
                    }
                } else if !(bh.contains("*") && Glob.match(bh, ch, separator: ".", caseInsensitive: true)) {
                    return .no
                } else if c.allowedIPs.isEmpty && b.allowedIPs.isEmpty {
                    return .unsupported("exact host \(ch) under wildcard \(bh) without allowed_ips")
                }
            }
        case (nil, nil): break
        }
        // Destination addresses.
        if !b.allowedIPs.isEmpty {
            guard !c.allowedIPs.isEmpty else {
                return .unsupported("the boundary pins \(b.host ?? "the endpoint") to allowed_ips; the candidate doesn't")
            }
            for r in c.allowedIPs where !b.allowedIPs.contains(where: { $0.mask <= r.mask && $0.contains(r.net) }) {
                return .no
            }
        }
        if b.tlsSkip != c.tlsSkip { return .unsupported("tls settings differ") }
        // Requests.
        guard let bl7 = b.l7, bl7.inspects else { return .yes }              // boundary allows every request
        guard bl7 == .rest, b.enforcement == .enforce else {
            return .unsupported("boundary endpoint in audit mode or not REST")
        }
        guard c.l7 == .rest, c.enforcement == .enforce else { return .no }  // candidate allows every request
        if !b.denyRules.isEmpty, b.denyRules != c.denyRules {
            return .unsupported("boundary deny rules not replicated in the candidate")
        }
        for a in c.allowMatchers {
            guard !a.query.isEmpty || true else { continue }
            let ok = b.allowMatchers.contains { bm in
                methodCovers(bm.method, a.method) && pathCovers(bm.path, a.path)
                    && (bm.query.isEmpty || bm.query == a.query)
            }
            if !ok { return .no }
        }
        return .yes
    }

    static func methodCovers(_ b: String, _ c: String) -> Bool {
        b == "*" || b == c || (c == "HEAD" && b == "GET")
    }

    static func pathCovers(_ b: String, _ c: String) -> Bool {
        if b == "**" || b == c { return true }
        let cWild = c.contains("*") || c.contains("?") || c.contains("[")
        if !cWild { return Glob.match(b, c, separator: "/", caseInsensitive: false) }
        // `/a/**` covers any pattern under `/a/`.
        if b.hasSuffix("/**") {
            let base = String(b.dropLast(2))
            return c.hasPrefix(base) && !base.contains("*")
        }
        return false
    }
}
