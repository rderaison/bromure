import Foundation
#if canImport(SandboxEngine)
import SandboxEngine
#endif

/// The proxy's egress, OpenShell and guardrails decisions, and the answer a
/// refused guest gets. Shared by the macOS MITM (HTTPMitmConnection) and the
/// Linux daemon's proxy (MitmProxy), so both decide alike, log the same
/// Security Timeline events, and send the guest the same bytes.
enum ProxyPolicy {
    /// What a request step decided: forward this request (maybe rewritten),
    /// or answer the guest with these bytes and stop.
    enum Step {
        case forward(Data)
        case answer(Data)
    }

    // MARK: - Connection layer (CONNECT / forward proxy)

    /// Connection-layer egress verdict for proxied flows — the same `verdict`
    /// the switch/transparent layers apply, with a deny logged under layer
    /// "proxy". Method-level `web` restrictions and OpenShell request rules
    /// stay in the policy chain, which sees the decrypted request.
    static func egressVerdict(policy: EgressPolicy?, profileID: UUID, host: String, port: Int,
                              identity: OpenShellPolicy.BinaryIdentity?) -> EgressPolicy.Verdict {
        guard let policy else { return .allow }
        let p16 = UInt16(truncatingIfNeeded: port)
        let verdict = policy.verdict(ip: nil, hostnames: [host], proto: .tcp, port: p16, identity: identity)
        guard verdict == .deny else { return verdict }
        // Refused every time; reported once a minute per destination.
        guard EgressReportDeduper.shared.shouldReport(profileID: profileID, host: host,
                                                      port: port, denied: true) else { return .deny }
        SupplyChainLog.shared.record(
            "[firewall] ✗ deny tcp \(host):\(port) (\(profileID.uuidString.prefix(8)))")
        BACEventEmitter.shared.emitDetached(
            profileID: profileID, eventType: "egress.firewall",
            eventData: ["action": .string("deny"), "proto": .string("tcp"),
                        "host": .string(host), "port": .int(port), "layer": .string("proxy"),
                        "rule": .of(policy.firstMatch(ip: nil, hostnames: [host], proto: .tcp, port: p16)?.text),
                        "by_policy": .bool(true)])
        return .deny
    }

    /// An allowed CONNECT / forward-proxy request, for the Security Timeline —
    /// the proxy-route twin of the switch's allowed-flow report, with the same
    /// fields, the same "Log allowed connections" gate and the same
    /// per-destination dedupe. The on-host local-inference endpoint is never
    /// reported (it never leaves this Mac).
    static func reportAllowed(policy: EgressPolicy?, profileID: UUID, host: String, port: Int) {
        guard let policy, policy.reportsAllowed,
              host.lowercased() != InferenceService.localMitmHost else { return }
        let rule = policy.firstMatch(ip: nil, hostnames: [host], proto: .tcp,
                                     port: UInt16(truncatingIfNeeded: port))?.text
        let data: [String: AnyJSON] = ["action": .string("allow"), "proto": .string("tcp"),
                                       "host": .string(host), "port": .int(port), "layer": .string("proxy"),
                                       "rule": .of(rule), "by_policy": .bool(true)]
        guard EgressReportDeduper.shared.shouldReport(profileID: profileID, host: host,
                                                      port: port, denied: false) else {
            // A repeat within the dedupe window: counted on the folded row.
            EgressReportDeduper.countRepeat(profileID: profileID, eventData: data)
            return
        }
        SupplyChainLog.shared.record(
            "[firewall] → allow tcp \(host):\(port) (\(profileID.uuidString.prefix(8)))")
        BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "egress.firewall", eventData: data)
    }

    /// The rule a tracked connection is registered under
    /// (`EgressConnectionRegistry.register`).
    static func trackedRule(policy: EgressPolicy?, host: String, port: Int) -> String? {
        policy?.firstMatch(ip: nil, hostnames: [host], proto: .tcp, port: UInt16(truncatingIfNeeded: port))?.text
    }

    /// Whether a connection, once registered with the firewall's registry, is
    /// denied after all: a policy swap that landed between the opening check
    /// and the registration. `policy.local` (the OpenShell advisor) is
    /// answered by the proxy, never forwarded: no rule governs it. Decided for
    /// the attested program: without it, a strict workspace's `binaries:`
    /// rules match nothing and every flow they allow would be closed, unlogged.
    static func deniedOnceTracked(policy: EgressPolicy?, host: String, port: Int,
                                  identity: OpenShellPolicy.BinaryIdentity?) -> Bool {
        guard host.lowercased() != OpenShellAdvisor.host, let policy else { return false }
        return policy.verdict(ip: nil, hostnames: [host], proto: .tcp, port: UInt16(truncatingIfNeeded: port),
                              identity: identity) == .deny
    }

    /// The 403 for a proxied connection the firewall refused. Under an
    /// OpenShell policy it carries OpenShell's `policy_denied` body (layer
    /// `l4`), with the advisor's next steps when agents may propose rules.
    static func connectDenied(policy: EgressPolicy?, profileID: UUID, host: String, port: Int) -> String {
        guard policy?.openShell != nil else {
            return "HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
        }
        let advisor = OpenShellAdvisor.shared.modeProvider(profileID) != .off
        var obj: [String: Any] = ["error": "policy_denied", "layer": "l4", "host": host, "port": port,
                                  "detail": "no network policy allows \(host):\(port)",
                                  "next_steps": advisor ? OpenShellAdvisor.nextSteps : []]
        if advisor { obj["agent_guidance"] = OpenShellAdvisor.agentGuidance }
        let body = String(decoding: (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data(),
                          as: UTF8.self)
        return "HTTP/1.1 403 Forbidden\r\ncontent-type: application/json\r\ncontent-length: \(body.utf8.count)\r\nconnection: close\r\n\r\n\(body)"
    }

    /// OpenShell's CONNECT denial for a destination that failed validation.
    static func destinationDenied(host: String, port: Int, reason: String) -> String {
        let body = "{\"error\":\"destination_denied\",\"detail\":\(jsonString(reason)),\"host\":\(jsonString(host)),\"port\":\(port)}"
        return "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    // MARK: - Request layer (inside the tunnel, before credentials are swapped)

    /// OpenShell's checks on the request head: its authority must name this
    /// tunnel's endpoint, an upgrade the inspected route can't follow is
    /// refused, and an inspected route forwards the canonical request-target
    /// (`request` is rewritten in place). Returns the answer for a refused
    /// request, nil to go on.
    static func openShellHeadAnswer(_ request: inout Data, policy: EgressPolicy?, profileID: UUID,
                                    host: String, port: Int, cleartext: Bool, scheme: String,
                                    identity: OpenShellPolicy.BinaryIdentity?) -> Data? {
        guard let openShell = policy?.openShell,
              let sep = request.range(of: Data("\r\n\r\n".utf8)),
              let head = try? OpenShellHTTP.parseHead(request.subdata(in: 0..<sep.upperBound)) else { return nil }
        guard OpenShellHTTP.authorityMatchesEndpoint(head, host: host, port: UInt16(truncatingIfNeeded: port),
                                                     transportDefaultPort: cleartext ? 80 : 443) else {
            return beforePolicyAnswer(status: 403, error: "request_authority_mismatch",
                                      detail: "HTTP request authority does not match the authorized tunnel endpoint",
                                      host: host, port: port, method: head.method, path: head.target,
                                      profileID: profileID, scheme: scheme)
        }
        // An upgrade the inspected route can't follow (h2c anywhere; any
        // Upgrade on JSON-RPC / MCP / GraphQL) is refused whatever the
        // enforcement mode — after it, no rule would see the traffic.
        if let detail = openShell.unsupportedUpgradeDetail(
            host: host, port: UInt16(truncatingIfNeeded: port), target: head.target,
            headerBlock: head.headerString, identity: identity,
            enforceBinaries: policy?.enforceBinaries ?? false) {
            return beforePolicyAnswer(status: 403, error: "unsupported_l7_protocol", detail: detail,
                                      host: host, port: port, method: head.method, path: head.target,
                                      profileID: profileID, scheme: scheme)
        }
        if let canonical = openShell.canonicalRequestTarget(host: host, port: UInt16(truncatingIfNeeded: port),
                                                            target: head.target),
           canonical != head.target {
            request = rewritingRequestTarget(request, method: head.method, target: canonical, version: head.version)
        }
        return nil
    }

    /// The answer to a request refused before any policy ran (OpenShell's
    /// framing and authority checks, a destination that failed validation),
    /// logged; the connection closes after it.
    static func beforePolicyAnswer(status: Int, error: String, detail: String, host: String, port: Int,
                                   method: String? = nil, path: String? = nil,
                                   profileID: UUID, scheme: String) -> Data {
        SupplyChainLog.shared.record(
            "[firewall] ✗ deny \(host):\(port) — \(detail) (\(profileID.uuidString.prefix(8)))")
        var data: [String: AnyJSON] = [
            "action": .string("deny"), "layer": .string("l7"), "proto": .string("tcp"),
            "host": .string(host), "port": .int(port), "reason": .string(detail), "scheme": .string(scheme),
        ]
        if let method { data["method"] = .string(method) }
        if let path { data["path"] = .string(path) }
        BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "egress.firewall", eventData: data)
        let body = "{\"error\":\"\(error)\",\"detail\":\(jsonString(detail)),\"layer\":\"l7\"}"
        let reason = status == 403 ? "Forbidden" : "Bad Request"
        let resp = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        return Data(resp.utf8)
    }

    /// `http://policy.local` — the OpenShell policy advisor's agent API,
    /// answered by the proxy and never forwarded.
    static func advisorAnswer(profileID: UUID, method: String, path: String, request: Data,
                              policy: @escaping @Sendable () -> EgressPolicy?) async -> Data {
        let body = bodyPrefix(of: request) ?? Data()
        let (status, type, payload) = await OpenShellAdvisor.shared.handle(
            profileID: profileID, method: method, target: path, body: body,
            policyReloaded: { key in
                policy()?.openShell?.networkPolicies.contains { $0.key == key } ?? false
            })
        var resp = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        resp += "Content-Type: \(type)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        var out = Data(resp.utf8)
        out.append(payload)
        return out
    }

    /// OpenShell request rules (method / path / query on inspected
    /// endpoints). An `audit` endpoint logs the violation and forwards; an
    /// `enforce` one answers OpenShell's `policy_denied` 403 so agents that
    /// know OpenShell read it the same way. Returns that answer, nil to go on.
    static func requestRuleAnswer(policy: EgressPolicy?, profileID: UUID, host: String, port: Int,
                                  method: String, path: String, request: Data, bodyComplete: Bool,
                                  scheme: String, identity: OpenShellPolicy.BinaryIdentity?) -> Data? {
        guard let openShell = policy?.openShell,
              case .violation(let reason, let rule, let enforced) = openShell.evaluateRequest(
                  host: host, port: UInt16(truncatingIfNeeded: port), method: method, target: path,
                  headers: lowercasedHeaders(of: request),
                  // A body spooled to disk is past every inspector's size limit.
                  body: bodyPrefix(of: request), bodyComplete: bodyComplete,
                  identity: identity,
                  enforceBinaries: policy?.enforceBinaries ?? false) else { return nil }
        SupplyChainLog.shared.record(
            "[firewall] \(enforced ? "✗ deny" : "⚠ audit") \(method) \(host)\(path) — \(reason) (\(profileID.uuidString.prefix(8)))")
        var data: [String: AnyJSON] = [
            "action": .string(enforced ? "deny" : "audit"), "layer": .string("l7"),
            "proto": .string("tcp"), "host": .string(host), "port": .int(port),
            "method": .string(method), "path": .string(path), "reason": .string(reason),
            "scheme": .string(scheme),
        ]
        if let rule { data["rule"] = .string(rule) }
        BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "egress.firewall",
                                            eventData: data)
        guard enforced else { return nil }
        let body = openShellDeniedBody(policy: rule, reason: reason, method: method,
                                       path: path, host: host, port: port,
                                       advisor: OpenShellAdvisor.shared.modeProvider(profileID) != .off)
        var resp = "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\n"
        resp += "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        return Data(resp.utf8)
    }

    /// Run the workspace's OpenShell middleware chain for this request: the
    /// (possibly rewritten) request to forward, or the 403 for a fail-closed
    /// middleware that couldn't run. `keep`: values the regex redactor leaves
    /// alone (the workspace's own stand-in credentials).
    static func middleware(_ request: Data, policy: EgressPolicy?, profileID: UUID, host: String, port: Int,
                           method: String, path: String, spooled: Bool,
                           keep: @escaping (String) -> Bool) -> Step {
        guard let chain = policy?.openShell?.middlewares(for: host),
              !chain.isEmpty else { return .forward(request) }
        var out = request
        for mw in chain {
            var failure = "middleware service unavailable"
            if mw.isBuiltinRegex {
                let outcome = spooled ? .failed("request_body_over_capacity")
                    : OpenShellPolicy.regexMiddleware(bodyPrefix(of: out) ?? Data(), keep: keep)
                switch outcome {
                case .unchanged: continue
                case .rewritten(let redacted, let count):
                    out = replacingBody(of: out, with: redacted)
                    BACEventEmitter.shared.emitDetached(
                        profileID: profileID, eventType: "egress.middleware",
                        eventData: ["middleware": .string(mw.kind), "entry": .string(mw.key), "host": .string(host),
                                    "action": .string("redact"), "count": .int(count)])
                    continue
                case .failed(let why): failure = why
                }
            }
            BACEventEmitter.shared.emitDetached(
                profileID: profileID, eventType: "egress.middleware",
                eventData: ["middleware": .string(mw.kind), "entry": .string(mw.key), "host": .string(host),
                            "action": .string(mw.failOpen ? "skipped" : "deny"),
                            "reason": .string(failure)])
            if mw.failOpen { continue }
            let reason = "middleware_failed: \(failure) (\(mw.name), \(mw.kind), fails closed)"
            SupplyChainLog.shared.record("[firewall] ✗ deny \(method) \(host)\(path) — \(reason)")
            let body = openShellDeniedBody(policy: mw.key, reason: reason, method: method,
                                           path: path, host: host, port: port)
            var resp = "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\n"
            resp += "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            return .answer(Data(resp.utf8))
        }
        return .forward(out)
    }

    /// Guardrails: host-side destructive-op removal across protocols
    /// (Kubernetes, AWS, DigitalOcean, Docker registries, GitHub/GitLab/
    /// Bitbucket, HTTPS databases), and the egress policy's `web` method
    /// rules. Decided before a single byte is forwarded, so a compromised
    /// agent in the VM can't bypass it; the agent gets a hard 403 it can react
    /// to. `.promptOnWrite` asks the user (the broker) first. Returns the 403,
    /// nil to forward.
    static func guardrailsAnswer(_ request: Data, guardrails: GuardrailsConfig, host: String, port: Int,
                                 method: String, path: String,
                                 broker: GuardrailsConsentBroker, profileID: UUID) async -> Data? {
        // AWS needs the action name from the request, so parse X-Amz-Target /
        // the Action= body param only for AWS hosts.
        var amzTarget: String?
        var formAction: String?
        if guardrails.aws != .off, GuardrailsConfig.isAWSHost(host) {
            let headerText: String
            var bodyPrefix = ""
            if let sep = request.range(of: Data("\r\n\r\n".utf8)) {
                headerText = String(decoding: request[request.startIndex..<sep.lowerBound], as: UTF8.self)
                let bEnd = request.index(sep.upperBound, offsetBy: 4096, limitedBy: request.endIndex) ?? request.endIndex
                bodyPrefix = String(decoding: request[sep.upperBound..<bEnd], as: UTF8.self)
            } else {
                headerText = String(decoding: request, as: UTF8.self)
            }
            amzTarget = SubscriptionAuthRewrite.headerValue("x-amz-target", inHeaderSection: headerText)
            formAction = amzTarget == nil ? formActionValue(bodyPrefix) : nil
        }
        // ClickHouse carries the verb in the SQL — pull it from the URL
        // `query=` param and/or the request body (param leads, since
        // `POST /?query=INSERT…` puts the statement there and data in body).
        var dbQuery: String?
        if guardrails.dbNeedsQuery(host: host) {
            var sql = SubscriptionAuthRewrite.urlQueryParam("query", inPath: path) ?? ""
            if let sep = request.range(of: Data("\r\n\r\n".utf8)) {
                let bEnd = request.index(sep.upperBound, offsetBy: 8192, limitedBy: request.endIndex) ?? request.endIndex
                let body = String(decoding: request[sep.upperBound..<bEnd], as: UTF8.self)
                if !body.isEmpty { sql += (sql.isEmpty ? "" : "\n") + body }
            }
            dbQuery = sql
        }
        // Use the async variant so `.promptOnWrite` mode can ask
        // the user before a sync block fires. Modes that decide
        // synchronously (off / destructive / readOnly) short-
        // circuit inside denyAsync and return immediately.
        guard let denial = await guardrails.denyAsync(
            host: host, method: method, path: path,
            amzTarget: amzTarget, formAction: formAction,
            dbQuery: dbQuery,
            broker: broker,
            profileID: profileID) else { return nil }
        // Structured event → the Security Timeline window. A `web`
        // method rule is the egress firewall's decision, recorded under
        // the Firewall engine — not Guardrails (B39).
        let (eventType, data) = denialEvent(denial, host: host, port: port, method: method, path: path)
        if denial.isFirewall {
            SupplyChainLog.shared.record(
                "[firewall] ✗ deny web \(method) \(host)\(path) (\(profileID.uuidString.prefix(8)))")
        } else {
            FileHandle.standardError.write(Data(
                "[mitm] Guardrails blocked \(method) \(host)\(path) — \(denial.reason)\n".utf8))
        }
        BACEventEmitter.shared.emitDetached(
            profileID: profileID, eventType: eventType, eventData: data)
        var resp = "HTTP/1.1 403 Forbidden\r\nContent-Type: \(denial.contentType)\r\n"
        if let t = denial.amzErrorType { resp += "x-amzn-ErrorType: \(t)\r\n" }
        resp += "Content-Length: \(denial.body.utf8.count)\r\nConnection: close\r\n\r\n\(denial.body)"
        return Data(resp.utf8)
    }

    // MARK: - Helpers

    /// `request` with its body replaced and `Content-Length` set to match.
    static func replacingBody(of request: Data, with body: Data) -> Data {
        guard let sep = request.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: request.subdata(in: request.startIndex..<sep.lowerBound), encoding: .isoLatin1)
        else { return request }
        var lines = head.components(separatedBy: "\r\n").filter {
            let l = $0.lowercased()
            return !l.hasPrefix("content-length:") && !l.hasPrefix("transfer-encoding:")
        }
        lines.append("Content-Length: \(body.count)")
        var out = Data(lines.joined(separator: "\r\n").utf8)
        out.append(Data("\r\n\r\n".utf8))
        out.append(body)
        return out
    }

    /// Request headers as a lowercased-name map (last value wins).
    static func lowercasedHeaders(of request: Data) -> [String: String] {
        guard let hdr = SubscriptionAuthRewrite.rawHeaderSection(of: request) else { return [:] }
        var out: [String: String] = [:]
        for line in hdr.components(separatedBy: "\r\n").dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            out[line[..<c].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// Replace the request line's target (OpenShell `rewrite_request_line_target`).
    static func rewritingRequestTarget(_ request: Data, method: String, target: String, version: String) -> Data {
        guard let eol = request.range(of: Data("\r\n".utf8)) else { return request }
        var out = Data("\(method) \(target) \(version)".utf8)
        out.append(request.subdata(in: eol.lowerBound..<request.count))
        return out
    }

    static func jsonString(_ s: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [s]), encoding: .utf8))
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    static func bodyPrefix(of request: Data) -> Data? {
        guard let sep = request.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let body = request.subdata(in: sep.upperBound..<request.endIndex)
        return body.isEmpty ? nil : body
    }

    /// Whether `value` is a host-minted subscription placeholder (Claude /
    /// Codex / Grok / Kimi bogus keys the transforms replace with the real
    /// OAuth credential) — Bromure's own, never an unmanaged secret.
    static func isSubscriptionPlaceholder(_ value: String) -> Bool {
        if let (store, _) = SubscriptionProviders.claude?(), store.profileForBogusKey(value) != nil { return true }
        if SubscriptionProviders.codex?()?.0.profileForBogusKey(value) != nil { return true }
        if SubscriptionProviders.grok?()?.0.profileForBogusKey(value) != nil { return true }
        if SubscriptionProviders.kimi?()?.0.profileForBogusKey(value) != nil { return true }
        return false
    }

    /// OpenShell's L7 denial body (`error: policy_denied`, same keys as its
    /// REST inspector), so tooling and agents built for OpenShell parse it.
    static func openShellDeniedBody(policy: String?, reason: String, method: String,
                                    path: String, host: String, port: Int,
                                    advisor: Bool = false) -> String {
        var obj: [String: Any] = [
            "error": "policy_denied", "policy": policy ?? "", "rule": "\(method) \(path)",
            "detail": reason, "layer": "l7", "protocol": "rest", "method": method,
            "path": path, "host": host, "port": port,
            "rule_missing": ["type": "rest_allow", "layer": "l7", "method": method,
                             "path": path, "host": host, "port": port] as [String: Any],
        ]
        // OpenShell adds the advisor's next steps while it's enabled.
        obj["next_steps"] = advisor ? OpenShellAdvisor.nextSteps : []
        if advisor { obj["agent_guidance"] = OpenShellAdvisor.agentGuidance }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The standard reason phrase for a status (RFC 9110), for response heads
    /// the proxy writes itself — not Foundation's localized description.
    static func reasonPhrase(_ code: Int) -> String {
        let phrases: [Int: String] = [
            100: "Continue", 101: "Switching Protocols", 200: "OK", 201: "Created", 202: "Accepted",
            203: "Non-Authoritative Information", 204: "No Content", 205: "Reset Content", 206: "Partial Content",
            300: "Multiple Choices", 301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
            307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request", 401: "Unauthorized",
            402: "Payment Required", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
            406: "Not Acceptable", 407: "Proxy Authentication Required", 408: "Request Timeout", 409: "Conflict",
            410: "Gone", 411: "Length Required", 412: "Precondition Failed", 413: "Content Too Large",
            414: "URI Too Long", 415: "Unsupported Media Type", 416: "Range Not Satisfiable",
            417: "Expectation Failed", 418: "I'm a teapot", 421: "Misdirected Request", 422: "Unprocessable Content",
            425: "Too Early", 426: "Upgrade Required", 428: "Precondition Required", 429: "Too Many Requests",
            431: "Request Header Fields Too Large", 451: "Unavailable For Legal Reasons",
            500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway", 503: "Service Unavailable",
            504: "Gateway Timeout", 505: "HTTP Version Not Supported",
        ]
        return phrases[code] ?? "Status"
    }

    /// The Security Timeline event for a pre-forward policy denial: a `web`
    /// method rule is the egress firewall's (`egress.firewall`, engine
    /// "Firewall"); everything else is a protocol guardrail (`guardrails.block`).
    static func denialEvent(_ denial: GuardrailsConfig.Denial, host: String, port: Int,
                            method: String, path: String) -> (String, [String: AnyJSON]) {
        if denial.isFirewall {
            return ("egress.firewall", [
                "action": .string("deny"),
                "layer": .string("web"),
                "proto": .string("web"),
                "host": .string(host),
                "port": .int(port),
                "method": .string(method),
                "path": .string(path),
                "reason": .string(denial.reason),
            ])
        }
        return ("guardrails.block", [
            "host": .string(host),
            "method": .string(method),
            "path": .string(path),
            "reason": .string(denial.reason),
        ])
    }

    /// Extract the `Action` value from a form-urlencoded AWS query-protocol
    /// body (e.g. `Action=TerminateInstances&Version=…`). `Action` need not
    /// be the first field.
    static func formActionValue(_ body: String) -> String? {
        for pair in body.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "Action" {
                return kv[1].removingPercentEncoding ?? String(kv[1])
            }
        }
        return nil
    }
}

// MARK: - Prompt-injection enforcement and content-scan records
// (HTTPProxy's, shared with the Linux proxy; HTTPMitmConnection forwards here.)

extension ProxyPolicy {
    /// Record that a request to an AI host could not go through the content
    /// scans (prompt injection / PII) — never skip them silently. `blocked`:
    /// the request was refused instead of forwarded (fail closed).
    ///
    /// Every occurrence is emitted — no host-side de-duplication, so the
    /// audit log and the enrolled-install event stream see each request.
    /// The Security Timeline folds repeats into one row with a count
    /// (`coalesceKey`), so a client that hits this on every call shows
    /// "×N" instead of one row that hides how often it happened.
    static func recordScanSkipped(host: String, path: String, engines: [String],
                                  reason: String, profileID: UUID, blocked: Bool = false) {
        let verdict = blocked ? "BLOCKED, not forwarded" : "not scanned"
        FileHandle.standardError.write(Data(
            "[mitm] \(host) \(path): \(reason) — \(verdict) (\(engines.joined(separator: ", ")))\n".utf8))
        SupplyChainLog.shared.record("[content-scan] \(verdict): \(reason) → \(host)")
        var data: [String: AnyJSON] = [
            "host": .string(host),
            "path": .string(path),
            "reason": .string(reason),
            "engines": .array(engines.map { .string($0) }),
        ]
        if blocked { data["action"] = .string("blocked") }
        BACEventEmitter.shared.emitDetached(
            profileID: profileID, eventType: "content_scan.skipped", eventData: data)
    }

    /// The detectors an enforcing prompt-injection policy waits on whose
    /// model is still loading.
    static func warmingDetectors(injection pi: PromptInjectionPolicy,
                                 source: ModelReadiness, rules: ModelReadiness) -> [String] {
        guard pi.isActive, pi.onDetection != .log else { return [] }
        var out: [String] = []
        if pi.detectSourceInjection, source == .loading { out.append("prompt-injection detection") }
        if pi.detectRulesInjection, rules == .loading { out.append("instruction-file detection") }
        return out
    }

    /// 503 while a detector's model loads (seconds, at first use or after an
    /// idle release). Every agent retries a 503 on its own, by then against
    /// a loaded model; nothing was sent.
    static func detectorWarmingResponse(_ detectors: [String]) -> Data {
        let body = "Bromure is loading its \(detectors.joined(separator: " and ")) model. "
            + "This request was not sent; retry in a few seconds.\n"
        var r = "HTTP/1.1 503 Service Unavailable\r\n"
        r += "Content-Type: text/plain; charset=utf-8\r\n"
        r += "Content-Length: \(body.utf8.count)\r\n"
        r += "Retry-After: \(detectorWarmingRetryAfter)\r\n"
        r += "X-Bromure-Blocked: detector-model-loading\r\n"
        r += "Connection: close\r\n\r\n"
        r += body
        return Data(r.utf8)
    }

    static let detectorWarmingRetryAfter = 2

    /// One Security Timeline row per request that swapped personal data the
    /// provider hadn't seen yet (history resent every turn isn't recounted).
    static func recordPIISwaps(_ o: PIIRewriter.Outcome, host: String, profileID: UUID, ms: Double) {
        var data: [String: AnyJSON] = ["host": .string(host), "count": .int(o.total),
                                       "latency_ms": .int(Int(ms.rounded()))]
        for (kind, n) in o.newSwaps { data[kind.rawValue] = .int(n) }
        if o.partial { data["partial"] = .bool(true) }
        BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "privacy.pii_swap", eventData: data)
    }

    /// Why a request body couldn't be decoded, for the Security Timeline:
    /// `encoding` is a coding's name (a content-coding is a token, no spaces)
    /// or the decoder's own reason ("an unreadable header line").
    static func undecodableReason(_ encoding: String) -> String {
        encoding.contains(" ") ? "request body could not be decoded (\(encoding))"
            : "\(encoding)-compressed request body could not be decoded"
    }

    /// 415 the guest sees when a request body's Content-Encoding can't be
    /// decoded while a content scan is on for the host: the request is not
    /// forwarded (it would leave unscanned). 415 is the status RFC 9110
    /// §15.5.16 assigns to an unsupported content coding; the plain-text body
    /// tells the user why their agent's call failed and what to change.
    static func undecodableBodyResponse(encoding: String, engines: [String]) -> Data {
        let names = engines.map { $0 == "pii" ? "PII protection" : "prompt-injection scanning" }
            .joined(separator: " and ")
        let what = encoding.contains(" ") ? "its body could not be decoded (\(encoding))"
            : "its body is \(encoding)-compressed in a way Bromure could not decode"
        let body = "Bromure blocked this request: \(what), so \(names) could not check it. It was not sent. "
            + "Retry, or turn the setting off for this workspace if the agent keeps sending it.\n"
        var r = "HTTP/1.1 415 Unsupported Media Type\r\n"
        r += "Content-Type: text/plain; charset=utf-8\r\n"
        r += "Content-Length: \(body.utf8.count)\r\n"
        r += "X-Bromure-Blocked: undecodable-content-encoding\r\n"
        r += "Connection: close\r\n\r\n"
        r += body
        return Data(r.utf8)
    }

    /// A request went out with tool output the user had blocked replaced by
    /// the placeholder (`PromptInjectionRedactions`): the security log only —
    /// it happens on every later turn, the Timeline already has the block.
    static func recordInjectionRedacted(count: Int, host: String, profileID: UUID) {
        SupplyChainLog.shared.record(
            "[prompt-injection] redacted: \(count) blocked tool output(s) or instruction file(s) replaced by a placeholder → \(host)")
        FileHandle.standardError.write(Data(
            "[prompt-injection] \(host): \(count) blocked tool output(s) or instruction file(s) sent as a placeholder (workspace \(profileID.uuidString.prefix(8)))\n".utf8))
    }

    /// "Unavailable For Legal Reasons - Bromure blocked: possible prompt
    /// injection" — the standard words first, then the block (letters,
    /// spaces and punctuation only: a valid reason phrase).
    static func injectionReasonPhrase(detector: String) -> String {
        let d = detector.filter { $0.isLetter || $0 == " " || $0 == "-" }
        return "Unavailable For Legal Reasons - Bromure blocked: possible \(d)"
    }

    static func injectionBlockResponse(detector: String, source: String,
                                       instructionsWithheld: Bool = false) -> Data {
        // The agent shows this text: say what happens next. Tool output that
        // was blocked is taken out of later requests (the session goes on);
        // rewinding or a new session clears it for good.
        // The next step goes on its own line: agents that print one line of
        // the error (omp's TUI wraps it; the chat card shows the line) still
        // show a whole sentence instead of "…Bromure will replace that content".
        let next = injectionNextStep(detector: detector, instructionsWithheld: instructionsWithheld)
        let body = "Bromure blocked this request: possible \(detector) detected in \(source).\(next)\n"
        // The reason phrase names the block too: an agent that reports only
        // the status line (Grok: "API error (status 451 …): Request failed")
        // still says which engine blocked it (`BromureBlock.of`).
        var r = "HTTP/1.1 451 \(injectionReasonPhrase(detector: detector))\r\n"
        r += "Content-Type: text/plain; charset=utf-8\r\n"
        r += "Content-Length: \(body.utf8.count)\r\n"
        r += "Connection: close\r\n\r\n"
        r += body
        return Data(r.utf8)
    }

    /// The enforcement scan (ask / block): fresh tool output through the
    /// source model, then the instructions through the rules scanner + model.
    static func detectPromptInjection(in conv: Conversation,
                                      policy pi: PromptInjectionPolicy) async -> PromptInjectionFlag? {
        if pi.detectSourceInjection {
            // A blocked output already went out as the placeholder: scan what's
            // left, never the placeholder itself.
            let spans = ToolResultSpans.newest(in: conv)
            if let preview = await PromptInjectionClassifier.shared.detect(
                spans: PromptInjectionRedactions.scannable(spans)) {
                return PromptInjectionFlag(detector: "prompt injection", method: "model",
                                           source: "tool output", preview: preview,
                                           spans: spans.map(\.content))
            }
        }
        if pi.detectRulesInjection {
            // Heuristic scanner first (catches obfuscation the model can't
            // read); then the ModernBERT semantic pass over the spans.
            // Repo instruction files pasted into the conversation (Codex's
            // AGENTS.md user message, Claude's CLAUDE.md reminder) count too.
            let extra = RulesFileScanner.scannable(RulesFileScanner.conversationInstructionSpans(conv))
            if let hit = RulesFileScanner.shared.detect(systemPrompt: conv.systemPrompt,
                                                        extraSpans: extra) {
                let all = extra + (conv.systemPrompt.map(RulesFileScanner.extractInstructionSpans) ?? [])
                let flagged = all.filter { $0.source == hit.source && RulesFileScanner.isHighRisk($0.content) }
                return PromptInjectionFlag(detector: "rogue instructions", method: "heuristic",
                                           source: hit.source, preview: hit.preview,
                                           ruleSpans: flagged.map(\.content))
            }
            let ruleSpans = RulesFileScanner.classifierSpans(conv.systemPrompt, extraSpans: extra)
            if let preview = await PromptInjectionClassifier.claudeMd.detect(spans: ruleSpans) {
                // Which file(s) tripped it (each verdict is cached: cheap).
                var flagged: [(id: String?, content: String)] = []
                for s in ruleSpans where await PromptInjectionClassifier.claudeMd.detect(spans: [s]) != nil {
                    flagged.append(s)
                }
                let named = flagged.compactMap(\.id)
                let source = named.count == 1 ? named[0]
                    : extra.isEmpty ? "CLAUDE.md"
                    : extra.count == 1 ? extra[0].source : "instruction files"
                return PromptInjectionFlag(detector: "rogue instructions", method: "model",
                                           source: source, preview: preview,
                                           ruleSpans: flagged.map(\.content))
            }
        }
        return nil
    }

    /// What the agent is told happens next, on its own line (agents that
    /// print one line of the error still show a whole sentence).
    ///  - tool output: later requests carry a placeholder instead.
    ///  - instructions: the conversation itself carries the file's text —
    ///    resent every turn, so removing CLAUDE.md alone never unblocked the
    ///    session. When the flagged bodies are known they're withheld from
    ///    later requests too; otherwise the way out is a new session / clear.
    static func injectionNextStep(detector: String, instructionsWithheld: Bool) -> String {
        if detector == "prompt injection" {
            return "\nLater requests carry a placeholder instead of that output, so the next message can go through."
                + " If it keeps failing, rewind the conversation past that step or start a new session."
        }
        if instructionsWithheld {
            return "\nThis conversation still carries those instructions, so later requests carry a placeholder instead of them and the next message can go through."
                + " Fix or remove the flagged file too; to drop them from the conversation entirely, start a new session (or /clear)."
        }
        return "\nThis conversation still carries those instructions: removing the file isn't enough for this session."
            + " Fix or remove the flagged file, then start a new session (or /clear)."
    }

    /// Security log + cloud event for a resolved detection ("blocked" /
    /// "allowed").
    static func recordPromptInjection(_ f: PromptInjectionFlag, outcome: String,
                                      host: String, profileID: UUID) {
        if outcome == "blocked" {
            BromureBlockLog.shared.record(f.detectorCode == "rules" ? .rulesInjection : .promptInjection,
                                          profileID: profileID)
        }
        SupplyChainLog.shared.record(
            "[prompt-injection] \(outcome): \(f.detector) in \(f.source) → \(host)")
        PromptInjectionCloudEvent.emit(
            profileID: profileID, detector: f.detectorCode, method: f.method,
            action: outcome, host: host, source: f.source, score: nil,
            signals: [], toolUseId: nil, snippet: f.preview)
    }
}
