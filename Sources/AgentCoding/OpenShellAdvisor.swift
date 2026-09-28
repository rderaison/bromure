import Foundation
import SandboxEngine

/// How a workspace's OpenShell policy advisor handles proposals.
public enum OpenShellAdvisorMode: String, Codable, CaseIterable, Sendable {
    /// No agent API (`policy.local` answers `feature_disabled`); blocked
    /// connections are still drafted as proposals for the user to review.
    case off
    /// Agents may propose rules; every proposal waits for the user.
    case review
    /// Proposals the risk check finds nothing in are approved automatically.
    case auto
}

/// The OpenShell policy advisor, Bromure-side: an agent blocked by the
/// workspace's OpenShell policy can propose the narrow rule it needs through
/// `http://policy.local` (the same API and payloads as OpenShell's), Bromure
/// drafts proposals from blocked connections on its own, and each proposal is
/// risk-checked before the user (or automatic mode) decides. An approved
/// proposal is appended to the workspace's policy text as its own rule and
/// takes effect live.
public final class OpenShellAdvisor: @unchecked Sendable {
    public static let shared = OpenShellAdvisor()
    public static let host = "policy.local"
    public static let changedNotification = Notification.Name("OpenShellAdvisorChanged")

    public enum Status: String, Sendable { case pending, approved, rejected }

    public struct Proposal: Identifiable, Sendable {
        public let id: String
        public let profileID: UUID
        public let rule: OpenShellPolicy.NetworkRule
        /// The rule as it will be appended (two-space-indented YAML entry).
        public let yaml: String
        /// `agent_authored` or `mechanistic` (a draft from a blocked connection).
        public let source: String
        public let intent: String
        public let createdAt: Date
        /// Risk-check findings (`credential_reach_expansion`, …) and flags
        /// (`wildcard_host`, `database_port`, …). Any one needs a human.
        public let findings: [String]
        public var status: Status = .pending
        public var rejectionReason: String?
        public var applicationError: String?
        public var auto = false

        public var host: String { rule.endpoints.first?.host ?? "?" }
        public var port: UInt16 { rule.endpoints.first?.ports.first ?? 0 }
    }

    public struct Denial: Sendable {
        public let time: Date
        public let layer: String
        public let host: String
        public let port: Int
        public let method: String?
        public let path: String?
        public let reason: String

        /// OpenShell-style shorthand log line (query strings redacted).
        var line: String {
            let ts = ISO8601DateFormatter().string(from: time)
            let what = method.map { "HTTP:\($0) \(host):\(port)\(path.map(Self.redactQuery) ?? "")" }
                ?? "NET:OPEN \(host):\(port)"
            return "\(ts) \(what) DENIED [\(layer)] \(reason)"
        }
        static func redactQuery(_ p: String) -> String {
            guard let q = p.firstIndex(of: "?") else { return p }
            return String(p[..<q]) + "?[redacted]"
        }
    }

    private let lock = NSLock()
    private var proposals: [UUID: [Proposal]] = [:]
    private var denials: [UUID: [Denial]] = [:]
    private var nextID = 1

    // Wiring (set by the app).
    /// The workspace's advisor mode.
    public var modeProvider: (@Sendable (UUID) -> OpenShellAdvisorMode) = { _ in .off }
    /// The workspace's effective OpenShell policy (nil: not in OpenShell mode).
    public var policyProvider: (@Sendable (UUID) -> OpenShellPolicy?) = { _ in nil }
    /// Host scopes Bromure injects credentials on, for the risk check.
    public var credentialScopesProvider: (@Sendable (UUID) -> [String]) = { _ in [] }
    /// Append an approved rule to the workspace's policy, persist, and apply it
    /// live. Returns an error message, or nil on success.
    public var applyApproved: (@Sendable (UUID, Proposal) async -> String?) = { _, _ in "advisor not wired" }

    // MARK: - Queries (UI)

    public func proposals(for profileID: UUID) -> [Proposal] {
        lock.lock(); defer { lock.unlock() }
        return proposals[profileID] ?? []
    }

    public func pending(for profileID: UUID) -> [Proposal] {
        proposals(for: profileID).filter { $0.status == .pending }
    }

    public func reset(profileID: UUID) {
        lock.lock()
        proposals[profileID] = nil
        denials[profileID] = nil
        lock.unlock()
        notify()
    }

    // MARK: - Denials → mechanistic drafts

    /// Record a denial from the firewall (fed by the event emitter). A
    /// connection denied for want of a rule is drafted as a proposal: one host
    /// and port, no inspection — the user can approve it or wait for the
    /// agent's narrower L7 proposal, which supersedes it.
    public func recordDenial(profileID: UUID, layer: String, host: String, port: Int,
                             method: String?, path: String?, reason: String) {
        guard policyProvider(profileID) != nil else { return }
        lock.lock()
        var list = denials[profileID] ?? []
        list.append(Denial(time: Date(), layer: layer, host: host, port: port,
                           method: method, path: path, reason: reason))
        if list.count > 100 { list.removeFirst(list.count - 100) }
        denials[profileID] = list
        lock.unlock()

        // Draft only connection-level denials of a named host (an IP-only flow
        // has nothing narrow to allow; L7 denials need the agent's intent).
        guard ["l4", "sni", "proxy"].contains(layer), port > 0, port <= 65_535,
              EgressPolicy.parseIPv4Address(host) == nil, host.contains(".") else { return }
        lock.lock()
        let exists = (proposals[profileID] ?? []).contains {
            $0.host == host.lowercased() && Int($0.port) == port && $0.status != .approved
        }
        lock.unlock()
        guard !exists else { return }
        let key = "allow_" + host.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
            .reduce(into: "") { $0.append($1) } + "_\(port)"
        let ep = OpenShellPolicy.Endpoint(host: host.lowercased(), ports: [UInt16(port)], path: nil,
                                          allowedIPs: [], l7: nil, tlsSkip: false, enforcement: .audit,
                                          access: nil, rules: [], denyRules: [], allowEncodedSlash: false)
        _ = enqueue(profileID: profileID, rule: .init(key: key, name: key, endpoints: [ep], binaries: []),
                    source: "mechanistic", intent: "Drafted from a blocked connection to \(host):\(port)")
    }

    // MARK: - Proposals

    /// Validate, risk-check and queue a proposal; auto-approve when allowed.
    /// Returns the proposal id, or a rejection reason.
    @discardableResult
    func enqueue(profileID: UUID, rule: OpenShellPolicy.NetworkRule, source: String,
                 intent: String) -> Refusable<String> {
        guard let current = policyProvider(profileID) else { return .refused("workspace has no OpenShell policy") }
        if current.networkPolicies.contains(where: { $0.key == rule.key }) {
            return .refused("a rule named \(rule.key) already exists")
        }
        // Validate as OpenShell would: the rule alone, then merged with the
        // current authored policy (overlap consistency).
        let yaml = OpenShellPolicy.yaml(rule: rule)
        do {
            _ = try OpenShellPolicy.parse("version: 1\nnetwork_policies:\n" + yaml + "\n")
            _ = try OpenShellPolicy.insertingRules(yaml, into: current.source)
        } catch {
            return .refused("\(error)")
        }
        for ep in rule.endpoints {
            if let h = ep.host, let ip = EgressPolicy.parseIPv4Address(h),
               OpenShellPolicy.blockedRanges.contains(where: { $0.contains(ip) }) {
                return .refused("\(h) is always blocked (loopback / link-local / metadata)")
            }
        }

        var findings = riskFindings(rule, profileID: profileID, current: current)
        // Never auto-approve past the organization boundary.
        if let merged = try? OpenShellPolicy.insertingRules(yaml, into: current.source),
           let result = OpenShellGovernance.shared.check(policyYAML: merged), !result.passed {
            findings.append("exceeds_boundary")
        }
        lock.lock()
        // An agent's proposal for the same host:port supersedes a mechanistic draft.
        if source == "agent_authored" {
            for i in (proposals[profileID] ?? []).indices {
                let p = proposals[profileID]![i]
                if p.source == "mechanistic", p.status == .pending,
                   rule.endpoints.contains(where: { $0.host == p.host && $0.ports.contains(p.port) }) {
                    proposals[profileID]![i].status = .rejected
                    proposals[profileID]![i].rejectionReason = "superseded by an agent-authored proposal"
                }
            }
        }
        let id = "chunk-\(nextID)"
        nextID += 1
        let proposal = Proposal(id: id, profileID: profileID, rule: rule, yaml: yaml, source: source,
                                intent: intent, createdAt: Date(), findings: findings)
        proposals[profileID, default: []].append(proposal)
        if proposals[profileID]!.count > 200 { proposals[profileID]!.removeFirst() }
        lock.unlock()
        emit(proposal, status: "submitted")
        notify()

        if modeProvider(profileID) == .auto, findings.isEmpty {
            Task { await self.approve(id: id, profileID: profileID, auto: true) }
        }
        return .ok(id)
    }

    /// OpenShell's proposal risk check (prover findings) and destination flags.
    func riskFindings(_ rule: OpenShellPolicy.NetworkRule, profileID: UUID,
                      current: OpenShellPolicy) -> [String] {
        var out: [String] = []
        let scopes = credentialScopesProvider(profileID).map { $0.lowercased() }
        let metadataHosts: Set<String> = ["metadata.google.internal", "metadata", "instance-data",
                                          "metadata.azure.com", "169.254.169.254"]
        let dbPorts: Set<UInt16> = [1433, 1521, 3306, 5432, 5984, 6379, 9042, 9200, 11211, 27017]
        func credentialed(_ h: String) -> Bool {
            scopes.contains { h == $0 || h.hasSuffix("." + $0) }
        }
        for ep in rule.endpoints {
            let h = ep.host ?? ""
            if metadataHosts.contains(h) || h.hasPrefix("169.254.") { out.append("link_local_reach") }
            if let ip = EgressPolicy.parseIPv4Address(h),
               OpenShellPolicy.privateRanges.contains(where: { $0.contains(ip) }) { out.append("private_ip_host") }
            if h.contains("*") { out.append("wildcard_host") }
            if ep.host == nil { out.append("hostless_allowed_ips") }
            if ep.allowedIPs.contains(where: { r in OpenShellPolicy.privateRanges.contains { $0.overlaps(r) } }) {
                out.append("private_allowed_ips")
            }
            if ep.ports.contains(where: { $0 > 49_152 }) { out.append("high_port") }
            if ep.ports.contains(where: dbPorts.contains) { out.append("database_port") }
            guard !h.isEmpty, credentialed(h) else { continue }
            if !(ep.l7?.inspects ?? false) { out.append("l7_bypass_credentialed") }
            for port in ep.ports {
                if case .deny = current.evaluateConnect(hostnames: [h], ip: nil, port: port) {
                    out.append("credential_reach_expansion")
                    continue
                }
                // New methods at an already-credentialed host:port.
                for m in ep.allowMatchers {
                    let sample = m.path.replacingOccurrences(of: "**", with: "x").replacingOccurrences(of: "*", with: "x")
                    let methods = m.method == "*" ? ["POST", "PUT", "PATCH", "DELETE"] : [m.method]
                    for method in methods where current.evaluateRequest(host: h, port: port, method: method,
                                                                        target: sample.hasPrefix("/") ? sample : "/" + sample) != .allow {
                        out.append("capability_expansion")
                    }
                }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    public func approve(id: String, profileID: UUID, auto: Bool = false) async {
        guard let p = proposal(id: id, profileID: profileID), p.status == .pending else { return }
        let error = await applyApproved(profileID, p)
        lock.lock()
        if let i = proposals[profileID]?.firstIndex(where: { $0.id == id }) {
            if let error {
                proposals[profileID]![i].status = .rejected
                proposals[profileID]![i].rejectionReason = "could not be applied: \(error)"
                proposals[profileID]![i].applicationError = error
            } else {
                proposals[profileID]![i].status = .approved
                proposals[profileID]![i].auto = auto
            }
        }
        let updated = proposals[profileID]?.first { $0.id == id }
        lock.unlock()
        if let updated { emit(updated, status: updated.status.rawValue) }
        notify()
    }

    public func reject(id: String, profileID: UUID, reason: String) {
        lock.lock()
        if let i = proposals[profileID]?.firstIndex(where: { $0.id == id && $0.status == .pending }) {
            proposals[profileID]![i].status = .rejected
            proposals[profileID]![i].rejectionReason = reason.isEmpty ? nil : reason
        }
        let updated = proposals[profileID]?.first { $0.id == id }
        lock.unlock()
        if let updated { emit(updated, status: "rejected") }
        notify()
    }

    func proposal(id: String, profileID: UUID) -> Proposal? {
        lock.lock(); defer { lock.unlock() }
        return proposals[profileID]?.first { $0.id == id }
    }

    private func emit(_ p: Proposal, status: String) {
        var data: [String: AnyJSON] = [
            "status": .string(status), "host": .string(p.host), "port": .int(Int(p.port)),
            "rule": .string(p.rule.key), "source": .string(p.source), "chunk_id": .string(p.id),
        ]
        if !p.findings.isEmpty { data["findings"] = .array(p.findings.map { .string($0) }) }
        if p.auto { data["auto"] = .bool(true) }
        if let r = p.rejectionReason { data["reason"] = .string(r) }
        BACEventEmitter.shared.emitDetached(profileID: p.profileID, eventType: "policy.proposal", eventData: data)
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changedNotification, object: nil) }
    }

    // MARK: - Agent API (http://policy.local)

    /// Serve one `policy.local` request. Returns (status, content type, body).
    func handle(profileID: UUID, method: String, target: String, body: Data,
                policyReloaded: @escaping @Sendable (String) -> Bool) async -> (Int, String, Data) {
        func json(_ status: Int, _ obj: Any) -> (Int, String, Data) {
            (status, "application/json",
             (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data())
        }
        guard policyProvider(profileID) != nil, modeProvider(profileID) != .off else {
            return json(404, ["error": "feature_disabled",
                              "detail": "the policy advisor is off for this workspace"])
        }
        let parts = target.split(separator: "?", maxSplits: 1)
        let path = String(parts.first ?? "")
        let query = parts.count > 1 ? String(parts[1]) : ""
        func param(_ name: String) -> String? {
            query.split(separator: "&").compactMap { kv -> String? in
                let p = kv.split(separator: "=", maxSplits: 1)
                return p.count == 2 && p[0] == name ? String(p[1]) : nil
            }.first
        }

        switch (method, path) {
        case ("GET", "/v1/policy/current"):
            return (200, "application/yaml", Data((policyProvider(profileID)?.effectiveYAML ?? "").utf8))
        case ("GET", "/v1/denials"):
            let last = min(100, max(1, Int(param("last") ?? "") ?? 10))
            lock.lock()
            let lines = (denials[profileID] ?? []).suffix(last).reversed().map(\.line)
            lock.unlock()
            return json(200, ["denials": Array(lines)])
        case ("GET", "/v1/guide"), ("GET", "/v1/skill"):
            return (200, "text/markdown", Data(Self.guide.utf8))
        case ("POST", "/v1/proposals"):
            return json(202, submit(profileID: profileID, body: body))
        case ("GET", _) where path.hasPrefix("/v1/proposals/"):
            let rest = path.dropFirst("/v1/proposals/".count)
            let isWait = rest.hasSuffix("/wait")
            let id = String(isWait ? rest.dropLast("/wait".count) : rest)
            guard var p = proposal(id: id, profileID: profileID) else {
                return json(404, ["error": "not_found", "detail": "no proposal \(id)"])
            }
            var timedOut = false
            if isWait {
                let timeout = min(300, max(1, Double(param("timeout") ?? "") ?? 60))
                let deadline = Date().addingTimeInterval(timeout)
                while p.status == .pending || (p.status == .approved && !policyReloaded(p.rule.key)) {
                    if Date() >= deadline { timedOut = p.status == .pending; break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard let q = proposal(id: id, profileID: profileID) else { break }
                    p = q
                }
            }
            var payload: [String: Any] = [
                "chunk_id": p.id, "status": p.status.rawValue, "rule_name": p.rule.key,
                "binary": p.rule.binaries.first ?? "", "rejection_reason": p.rejectionReason ?? "",
                "validation_result": p.findings.isEmpty ? "" : "findings: " + p.findings.joined(separator: ", "),
                "application_error": p.applicationError ?? "",
            ]
            if timedOut { payload["timed_out"] = true }
            if p.status == .approved { payload["policy_reloaded"] = policyReloaded(p.rule.key) }
            return json(200, payload)
        default:
            return json(404, ["error": "not_found", "detail": "\(method) \(path)"])
        }
    }

    /// `POST /v1/proposals`: `{intent_summary, operations: [{addRule: {ruleName, rule}}]}`.
    func submit(profileID: UUID, body: Data) -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let ops = obj["operations"] as? [[String: Any]], !ops.isEmpty else {
            return ["status": "submitted", "accepted_chunks": 0, "rejected_chunks": 1,
                    "rejection_reasons": ["body must be {intent_summary, operations: [{addRule: …}]}"],
                    "accepted_chunk_ids": [String]()]
        }
        let intent = obj["intent_summary"] as? String ?? ""
        var accepted: [String] = []
        var reasons: [String] = []
        for op in ops {
            guard let add = op["addRule"] as? [String: Any],
                  let name = (add["ruleName"] as? String) ?? ((add["rule"] as? [String: Any])?["name"] as? String),
                  let ruleObj = add["rule"] as? [String: Any] else {
                reasons.append("only addRule operations with a ruleName and rule are supported")
                continue
            }
            switch Self.rule(fromAgentJSON: ruleObj, key: name) {
            case .refused(let why): reasons.append("\(name): \(why)")
            case .ok(let rule):
                switch enqueue(profileID: profileID, rule: rule, source: "agent_authored", intent: intent) {
                case .ok(let id): accepted.append(id)
                case .refused(let why): reasons.append("\(name): \(why)")
                }
            }
        }
        return ["status": "submitted", "accepted_chunks": accepted.count, "rejected_chunks": reasons.count,
                "rejection_reasons": reasons, "accepted_chunk_ids": accepted]
    }

    /// Build a rule from an agent's JSON, keeping only what agents may propose
    /// (OpenShell: endpoints with host, port(s), protocol rest/websocket,
    /// enforcement, access, method+path allow rules, deny rules, allowed_ips,
    /// allow_encoded_slash; binaries). No `tcp`, no `tls: skip`.
    static func rule(fromAgentJSON r: [String: Any], key: String) -> Refusable<OpenShellPolicy.NetworkRule> {
        guard key.range(of: #"^[A-Za-z0-9_.-]{1,128}$"#, options: .regularExpression) != nil,
              !key.hasPrefix("_provider_") else {
            return .refused("ruleName must match [A-Za-z0-9_.-]{1,128} and not start with _provider_")
        }
        guard let eps = r["endpoints"] as? [[String: Any]], !eps.isEmpty else {
            return .refused("rule needs at least one endpoint")
        }
        var yamlEndpoints: [String] = []
        func q(_ s: String) -> String {
            let d = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data()
            return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
        }
        for ep in eps {
            var f: [String] = []
            if let h = ep["host"] as? String { f.append("host: \(q(h))") }
            if let p = ep["port"] as? Int { f.append("port: \(p)") }
            if let ps = ep["ports"] as? [Int] { f.append("ports: [\(ps.map(String.init).joined(separator: ", "))]") }
            if let proto = ep["protocol"] as? String, !proto.isEmpty {
                guard ["rest", "websocket"].contains(proto) else {
                    return .refused("agents may propose protocol rest or websocket only")
                }
                f.append("protocol: \(proto)")
            }
            if let tls = ep["tls"] as? String, tls == "skip" { return .refused("agents can't propose tls: skip") }
            if let e = ep["enforcement"] as? String { f.append("enforcement: \(q(e))") }
            if let a = ep["access"] as? String, !a.isEmpty { f.append("access: \(q(a))") }
            if let ips = ep["allowed_ips"] as? [String], !ips.isEmpty {
                f.append("allowed_ips: [" + ips.map(q).joined(separator: ", ") + "]")
            }
            if ep["allow_encoded_slash"] as? Bool == true { f.append("allow_encoded_slash: true") }
            func matcher(_ m: [String: Any]) -> String? {
                guard let method = m["method"] as? String, let path = m["path"] as? String else { return nil }
                return "{ method: \(q(method)), path: \(q(path)) }"
            }
            if let rules = ep["rules"] as? [[String: Any]], !rules.isEmpty {
                f.append("rules:")
                for rr in rules {
                    guard let a = rr["allow"] as? [String: Any], let m = matcher(a) else {
                        return .refused("each rule needs allow: {method, path}")
                    }
                    f.append("  - allow: \(m)")
                }
            }
            if let denies = ep["deny_rules"] as? [[String: Any]], !denies.isEmpty {
                f.append("deny_rules:")
                for d in denies {
                    guard let m = matcher(d) else { return .refused("each deny rule needs method and path") }
                    f.append("  - \(m)")
                }
            }
            guard let first = f.first else { return .refused("empty endpoint") }
            yamlEndpoints.append((["      - " + first] + f.dropFirst().map { "        " + $0 }).joined(separator: "\n"))
        }
        var binaries: [String] = []
        for b in r["binaries"] as? [Any] ?? [] {
            if let s = b as? String { binaries.append(s) }
            else if let d = b as? [String: Any], let p = d["path"] as? String { binaries.append(p) }
        }
        var yaml = "version: 1\nnetwork_policies:\n  \(q(key)):\n    endpoints:\n" + yamlEndpoints.joined(separator: "\n")
        if !binaries.isEmpty {
            yaml += "\n    binaries:\n" + binaries.map { "      - path: \(q($0))" }.joined(separator: "\n")
        }
        do {
            let p = try OpenShellPolicy.parse(yaml + "\n")
            guard let rule = p.networkPolicies.first else { return .refused("empty rule") }
            return .ok(rule)
        } catch {
            return .refused("\(error)")
        }
    }

    /// Guidance embedded in L7 denial bodies while the advisor is on.
    static let agentGuidance = "Bromure blocked this request with the workspace's OpenShell sandbox policy. If the user's task still needs this network action, do not stop here: read http://policy.local/v1/guide, submit the narrowest policy proposal to http://policy.local/v1/proposals, wait for approval and `policy_reloaded: true`, then retry the original request."

    static var nextSteps: [[String: String]] {
        [["action": "read_skill", "url": "http://policy.local/v1/guide"],
         ["action": "inspect_policy", "method": "GET", "url": "http://policy.local/v1/policy/current"],
         ["action": "inspect_recent_denials", "method": "GET", "url": "http://policy.local/v1/denials?last=5"],
         ["action": "submit_proposal", "method": "POST", "url": "http://policy.local/v1/proposals",
          "body_type": "PolicyMergeOperation"]]
    }

    /// The agent guide served at `/v1/guide` — adapted from OpenShell's
    /// `policy_advisor.md` (Apache-2.0).
    static let guide = """
    # Policy Advisor (Bromure, OpenShell-compatible)

    Use this when a request fails with `policy_denied` (HTTP 403) or a connection
    is refused by the workspace's sandbox policy.

    ## Goal
    Draft the smallest policy proposal that lets the user's current task proceed
    without giving the workspace broad new network access. The user approves or
    rejects it. Never try to bypass the policy.

    ## API (http://policy.local — use the proxy the environment already sets)
    - `GET /v1/policy/current` — the effective policy as YAML.
    - `GET /v1/denials?last=10` — recent denials, newest first.
    - `POST /v1/proposals` — submit `{"intent_summary": "...", "operations": [{"addRule": {"ruleName": "...", "rule": {...}}}]}`.
      The 202 response lists `accepted_chunk_ids` and `rejection_reasons`.
    - `GET /v1/proposals/{chunk_id}` — `pending`, `approved` or `rejected`.
    - `GET /v1/proposals/{chunk_id}/wait?timeout=300` — wait for the decision; on
      approval, `policy_reloaded: true` means the new rule is live: retry.

    ## Workflow
    1. Read the denial body (`host`, `port`, `method`, `path`, `detail`).
    2. Fetch the current policy and, if needed, recent denials.
    3. Prefer REST-inspected rules: exact host, exact port, exact method, the
       narrowest path (`protocol: rest`, `enforcement: enforce`, `rules` with
       `allow: {method, path}`).
    4. Never propose `protocol: tcp` or `tls: skip` — they're refused.
    5. Submit, then wait on each accepted chunk id. On `rejected`, read
       `rejection_reason` / `validation_result` and submit something narrower
       or ask the user.

    ## Review
    Proposals that reach a host where a workspace credential is used, add a new
    method there, use a wildcard host, a private address, a database port or a
    port above 49152 always wait for the user. Others may be approved
    automatically if the workspace allows it.

    ## Example
    ```json
    {"intent_summary": "Allow updating docs in acme/app only.",
     "operations": [{"addRule": {"ruleName": "github_contents_docs_write",
       "rule": {"endpoints": [{"host": "api.github.com", "port": 443, "protocol": "rest",
         "enforcement": "enforce",
         "rules": [{"allow": {"method": "PUT", "path": "/repos/acme/app/contents/docs/**"}}]}]}}}]}
    ```
    """
}

/// Thread-safe snapshot of each workspace's advisor mode (the proxy asks from
/// its own threads; profiles live on the main actor).
final class OpenShellAdvisorModeCache: @unchecked Sendable {
    static let shared = OpenShellAdvisorModeCache()
    private let lock = NSLock()
    private var modes: [UUID: OpenShellAdvisorMode] = [:]
    private var watchdog: [UUID: AgentWatchdogMode] = [:]

    func refresh(_ profiles: [Profile]) {
        var m: [UUID: OpenShellAdvisorMode] = [:]
        var w: [UUID: AgentWatchdogMode] = [:]
        for p in profiles {
            if p.usesOpenShellPolicy || OpenShellGovernance.shared.boundaryYAML != nil {
                m[p.id] = OpenShellGovernance.shared.effectiveAdvisorMode(
                    OpenShellAdvisorMode(rawValue: p.openShellAdvisorMode) ?? .off)
            }
            w[p.id] = AgentWatchdogMode(rawValue: p.watchdogMode) ?? .off
        }
        lock.lock(); modes = m; watchdog = w; lock.unlock()
    }

    func watchdogMode(for id: UUID) -> AgentWatchdogMode {
        lock.lock(); defer { lock.unlock() }
        return watchdog[id] ?? .off
    }

    func mode(for id: UUID) -> OpenShellAdvisorMode {
        lock.lock(); defer { lock.unlock() }
        return modes[id] ?? .off
    }
}

/// A value, or the reason it was refused (shown to the agent / user verbatim).
enum Refusable<T> {
    case ok(T)
    case refused(String)
}
