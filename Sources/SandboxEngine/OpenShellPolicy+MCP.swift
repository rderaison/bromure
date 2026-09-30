import Foundation

// MARK: - MCP Streamable HTTP inspection (port of OpenShell l7/mcp.rs,
// l7/jsonrpc.rs `parse_mcp_payload` and tower-mcp-types' exact-revision
// method table)
//
// One request is inspected in three steps, as OpenShell's relay does:
//   1. a bootstrap parse (no revision): only a legacy `initialize` survives it;
//   2. revision selection from `MCP-Protocol-Version` (absent → 2025-03-26),
//      checked against the endpoint's `mcp.versions`; a standalone legacy
//      `initialize` negotiates in its body instead;
//   3. re-inspection under the selected revision — batch shape, method
//      availability and direction, typed params, and for the sessionless
//      2026-07-28 revision the `_meta` contract plus the `Mcp-Method` /
//      `Mcp-Name` header mirrors.
// Failures in 1–3 are transport rejections (HTTP 400/403/405), enforced even
// under `enforcement: audit`. The survivors are authorized by the rules.

extension OpenShellPolicy {
    enum MCPRevision: String, CaseIterable, Comparable {
        case r20250326 = "2025-03-26"
        case r20250618 = "2025-06-18"
        case r20251125 = "2025-11-25"
        case r20260728 = "2026-07-28"

        static func < (a: Self, b: Self) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
        static let legacy: Set<Self> = [.r20250326, .r20250618, .r20251125]
        static let all = Set(allCases)
    }

    /// MCP revisions OpenShell knows.
    static let knownMCPVersions = Set(MCPRevision.allCases.map(\.rawValue))

    enum MCPClassification { case available, extension_ }

    struct MCPCall {
        var method: String
        var tool: String?
        var classification: MCPClassification
    }

    /// The inspected request, as OpenShell hands it to its policy engine.
    struct MCPInfo {
        var calls: [MCPCall] = []
        var isBatch = false
        var receiveStream = false
        var hasResponse = false
        var error: String?
        /// 2026-07-28 body fields the HTTP headers must mirror.
        var httpMethod: String?
        var httpName: String?
        var hasHTTPMetadata = false

        static func rejected(_ why: String, batch: Bool = false) -> MCPInfo {
            MCPInfo(isBatch: batch, error: why)
        }
    }

    // MARK: method table (tower-mcp-types METHOD_RULES, client → server)

    private struct MethodRule {
        let name: String
        let isRequest: Bool
        let clientToServer: Set<MCPRevision>
        let known: Bool                          // present in any direction of any revision
        let requiredParams: Set<MCPRevision>
        let validate: ([String: Any], MCPRevision) -> String?
    }

    /// tower-mcp-types' `ParamsValidator` per method (typed params decoding,
    /// ported in `OpenShellMCPParams`).
    private static let validatorNames: [String: String] = [
        "initialize": "Initialize",
        "ping": "Object",
        "completion/complete": "Complete",
        "logging/setLevel": "SetLogLevel",
        "prompts/get": "GetPrompt",
        "prompts/list": "ListPrompts",
        "resources/list": "ListResources",
        "resources/templates/list": "ListResourceTemplates",
        "resources/read": "ReadResource",
        "resources/subscribe": "SubscribeResource",
        "resources/unsubscribe": "UnsubscribeResource",
        "tools/call": "CallTool",
        "tools/list": "ListTools",
        "sampling/createMessage": "CreateMessage",
        "roots/list": "ListRoots",
        "elicitation/create": "Elicit",
        "tasks/get": "GetTask",
        "tasks/result": "GetTaskResult",
        "tasks/list": "ListTasks",
        "tasks/cancel": "CancelTask",
        "tasks/update": "Object",
        "server/discover": "Discover",
        "subscriptions/listen": "SubscriptionsListen",
        "notifications/cancelled": "Cancelled",
        "notifications/progress": "Progress",
        "notifications/initialized": "Object",
        "notifications/roots/list_changed": "Object",
        "notifications/message": "LoggingMessage",
        "notifications/resources/updated": "ResourceUpdated",
        "notifications/resources/list_changed": "Object",
        "notifications/tools/list_changed": "Object",
        "notifications/prompts/list_changed": "Object",
        "notifications/elicitation/complete": "ElicitationComplete",
        "notifications/tasks/status": "TaskStatus",
        "notifications/subscriptions/acknowledged": "SubscriptionsAcknowledged"
    ]

    private static func rule(_ name: String, request: Bool, c2s: Set<MCPRevision>, params: Set<MCPRevision>,
                             _ v: @escaping ([String: Any], MCPRevision) -> String? = { _, _ in nil }) -> MethodRule {
        let validator = validatorNames[name] ?? "Object"
        return MethodRule(name: name, isRequest: request, clientToServer: c2s, known: true, requiredParams: params,
                          validate: { p, rev in OpenShellMCPParams.validate(validator: validator, params: p, revision: rev.rawValue) })
    }

    private static func needString(_ keys: String...) -> ([String: Any], MCPRevision) -> String? {
        { p, _ in keys.first { !(p[$0] is String) }.map { "missing field `\($0)`" } ?? inputFields(p) }
    }

    /// SEP-2322 retry fields (tools/call, prompts/get, resources/read):
    /// `inputResponses` maps ids to a sampling, roots or elicitation result;
    /// `requestState` is an opaque string.
    private static func inputFields(_ p: [String: Any]) -> String? {
        if let rs = p["requestState"], !(rs is String), !(rs is NSNull) { return "invalid type: `requestState`" }
        guard let raw = p["inputResponses"], !(raw is NSNull) else { return nil }
        guard let map = raw as? [String: Any] else { return "invalid type: `inputResponses`" }
        for value in map.values {
            guard let r = value as? [String: Any] else {
                return "data did not match any variant of untagged enum InputResponse"
            }
            let elicit = (r["action"] as? String).map { ["accept", "decline", "cancel"].contains($0) } ?? false
            let roots = r["roots"] is [Any]
            let sampling = r["model"] is String && r["role"] is String && r["content"] != nil
            if !(elicit || roots || sampling) { return "data did not match any variant of untagged enum InputResponse" }
        }
        return nil
    }
    private static func optionalCursor(_ p: [String: Any], _: MCPRevision) -> String? {
        if let c = p["cursor"], !(c is String), !(c is NSNull) { return "invalid type: `cursor`" }
        return nil
    }

    private static let methodRules: [String: MethodRule] = {
        let L = MCPRevision.legacy, A = MCPRevision.all
        let R26: Set<MCPRevision> = [.r20260728], R1125: Set<MCPRevision> = [.r20251125]
        let rules: [MethodRule] = [
            rule("initialize", request: true, c2s: L, params: L) { p, _ in
                guard p["protocolVersion"] is String else { return "missing field `protocolVersion`" }
                guard p["capabilities"] is [String: Any] else { return "missing field `capabilities`" }
                guard let ci = p["clientInfo"] as? [String: Any], ci["name"] is String, ci["version"] is String else {
                    return "missing field `clientInfo`"
                }
                return nil
            },
            rule("ping", request: true, c2s: L, params: []),
            rule("completion/complete", request: true, c2s: A, params: A) { p, _ in
                guard p["ref"] is [String: Any] else { return "missing field `ref`" }
                guard let a = p["argument"] as? [String: Any], a["name"] is String, a["value"] is String else {
                    return "missing field `argument`"
                }
                return nil
            },
            rule("logging/setLevel", request: true, c2s: L, params: L, needString("level")),
            rule("prompts/get", request: true, c2s: A, params: A, needString("name")),
            rule("prompts/list", request: true, c2s: A, params: R26, optionalCursor),
            rule("resources/list", request: true, c2s: A, params: R26, optionalCursor),
            rule("resources/templates/list", request: true, c2s: A, params: R26, optionalCursor),
            rule("resources/read", request: true, c2s: A, params: A, needString("uri")),
            rule("resources/subscribe", request: true, c2s: L, params: L, needString("uri")),
            rule("resources/unsubscribe", request: true, c2s: L, params: L, needString("uri")),
            rule("tools/call", request: true, c2s: A, params: A) { p, _ in
                guard p["name"] is String else { return "missing field `name`" }
                if let a = p["arguments"], !(a is [String: Any]), !(a is NSNull) { return "invalid type: `arguments`" }
                return inputFields(p)
            },
            rule("tools/list", request: true, c2s: A, params: R26, optionalCursor),
            rule("sampling/createMessage", request: true, c2s: [], params: L),
            rule("roots/list", request: true, c2s: [], params: []),
            rule("elicitation/create", request: true, c2s: [], params: [.r20250618, .r20251125]),
            rule("tasks/get", request: true, c2s: R1125, params: R1125, needString("taskId")),
            rule("tasks/result", request: true, c2s: R1125, params: R1125, needString("taskId")),
            rule("tasks/list", request: true, c2s: R1125, params: [], optionalCursor),
            rule("tasks/cancel", request: true, c2s: R1125, params: R1125, needString("taskId")),
            rule("tasks/update", request: true, c2s: [], params: []),
            rule("server/discover", request: true, c2s: R26, params: R26),
            rule("subscriptions/listen", request: true, c2s: R26, params: R26) { p, _ in
                p["notifications"] == nil ? "required `notifications` field is missing" : nil
            },
            rule("notifications/cancelled", request: false, c2s: A, params: A) { p, _ in
                (p["requestId"] == nil || p["requestId"] is NSNull) ? "required non-null `requestId` field is missing" : nil
            },
            rule("notifications/progress", request: false, c2s: L, params: A) { p, _ in
                guard p["progressToken"] != nil else { return "missing field `progressToken`" }
                return p["progress"] is NSNumber ? nil : "missing field `progress`"
            },
            rule("notifications/initialized", request: false, c2s: L, params: []),
            rule("notifications/roots/list_changed", request: false, c2s: L, params: []),
            rule("notifications/message", request: false, c2s: [], params: A),
            rule("notifications/resources/updated", request: false, c2s: [], params: A),
            rule("notifications/resources/list_changed", request: false, c2s: [], params: []),
            rule("notifications/tools/list_changed", request: false, c2s: [], params: []),
            rule("notifications/prompts/list_changed", request: false, c2s: [], params: []),
            rule("notifications/elicitation/complete", request: false, c2s: [], params: R1125),
            rule("notifications/tasks/status", request: false, c2s: R1125, params: R1125),
            rule("notifications/subscriptions/acknowledged", request: false, c2s: [], params: R26),
        ]
        return Dictionary(uniqueKeysWithValues: rules.map { ($0.name, $0) })
    }()

    /// Server-to-client-only or other-revision methods are still "known"; a
    /// method is available when the table lists it for the client in `rev`.
    /// OpenShell's `available_in` = any direction in `rev`.
    private static let serverToClient: [String: Set<MCPRevision>] = {
        let L = MCPRevision.legacy, A = MCPRevision.all
        return ["ping": L, "sampling/createMessage": L, "roots/list": L,
                "elicitation/create": [.r20250618, .r20251125],
                "tasks/get": [.r20251125], "tasks/result": [.r20251125], "tasks/list": [.r20251125],
                "tasks/cancel": [.r20251125],
                "notifications/cancelled": A, "notifications/progress": A, "notifications/message": A,
                "notifications/resources/updated": A, "notifications/resources/list_changed": A,
                "notifications/tools/list_changed": A, "notifications/prompts/list_changed": A,
                "notifications/elicitation/complete": [.r20251125], "notifications/tasks/status": [.r20251125],
                "notifications/subscriptions/acknowledged": [.r20260728]]
    }()

    // MARK: JSON-RPC envelopes (tower-mcp-types inspection.rs)

    private enum Envelope {
        case request(method: String, params: Any?, object: [String: Any])
        case notification(method: String, params: Any?, object: [String: Any])
        case result, error
        var method: String? {
            switch self {
            case .request(let m, _, _), .notification(let m, _, _): return m
            default: return nil
            }
        }
        var isResponse: Bool { if case .result = self { return true }; if case .error = self { return true }; return false }
    }

    struct Why: Error, ExpressibleByStringLiteral {
        let text: String
        init(stringLiteral value: String) { text = value }
        init(_ text: String) { self.text = text }
    }

    private static func isValidID(_ v: Any) -> Bool {
        if v is String { return true }
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
        return n.doubleValue == n.doubleValue.rounded() && abs(n.doubleValue) < 9.3e18
            && !String(describing: n).contains(".")
    }

    private static func envelope(_ o: [String: Any]) -> Result<Envelope, Why> {
        switch o["jsonrpc"] {
        case nil: return .failure("JSON-RPC envelope is missing `jsonrpc`")
        case let v as String where v == "2.0": break
        case is String: return .failure("JSON-RPC version must be `2.0`")
        default: return .failure("JSON-RPC `jsonrpc` field must be a string")
        }
        let hasMethod = o["method"] != nil, hasResult = o["result"] != nil, hasError = o["error"] != nil
        if hasMethod && (hasResult || hasError) { return .failure("JSON-RPC envelope cannot contain both `method` and `result`/`error`") }
        if hasResult && hasError { return .failure("JSON-RPC response cannot contain both `result` and `error`") }
        if hasMethod {
            guard let m = o["method"] as? String else { return .failure("JSON-RPC `method` field must be a string") }
            guard !m.isEmpty else { return .failure("JSON-RPC `method` field must not be empty") }
            if let p = o["params"], !(p is [String: Any]), !(p is [Any]) {
                return .failure("JSON-RPC `params` field must be an object or array when present")
            }
            if let id = o["id"] {
                guard isValidID(id) else { return .failure("JSON-RPC request `id` must be a string or signed integer") }
                return .success(.request(method: m, params: o["params"], object: o))
            }
            return .success(.notification(method: m, params: o["params"], object: o))
        }
        if hasResult {
            guard let id = o["id"], isValidID(id) else { return .failure("JSON-RPC success response `id` must be a string or signed integer") }
            return .success(.result)
        }
        if hasError {
            if let id = o["id"], !(id is NSNull), !isValidID(id) { return .failure("JSON-RPC error response `id` is invalid") }
            guard let e = o["error"] as? [String: Any], e["code"] is NSNumber, e["message"] is String else {
                return .failure("invalid JSON-RPC error response")
            }
            return .success(.error)
        }
        return .failure("JSON-RPC object must contain `method`, `result`, or `error`")
    }

    /// (envelopes, isBatch) or a structural error.
    private static func payload(_ value: Any) -> Result<([Envelope], Bool), Why> {
        if let o = value as? [String: Any] { return envelope(o).map { ([$0], false) } }
        guard let items = value as? [Any] else { return .failure("JSON-RPC payload must be an object or array") }
        guard !items.isEmpty else { return .failure("JSON-RPC batch must contain at least one message") }
        var out: [Envelope] = []
        var responses: Bool?
        for item in items {
            guard let o = item as? [String: Any] else { return .failure("JSON-RPC batch member must be an object") }
            let e: Envelope
            switch envelope(o) { case .success(let x): e = x; case .failure(let why): return .failure(why) }
            if let r = responses, r != e.isResponse { return .failure("JSON-RPC batch cannot mix calls with responses") }
            responses = e.isResponse
            out.append(e)
        }
        return .success((out, true))
    }

    private static let maxLegacyBatch = 64

    // MARK: parse_mcp_payload

    static func inspectMCP(_ body: Data, revision: MCPRevision?, strictToolNames: Bool) -> MCPInfo {
        guard let value = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
            return .rejected("invalid JSON")
        }
        let envelopes: [Envelope], isBatch: Bool
        switch payload(value) {
        case .success(let p): (envelopes, isBatch) = p
        case .failure(let why): return .rejected(why.text, batch: value is [Any])
        }
        func declaredVersion(_ o: Any) -> Any? {
            ((((o as? [String: Any])?["params"] as? [String: Any])?["_meta"]) as? [String: Any])?[
                "io.modelcontextprotocol/protocolVersion"]
        }

        // Legacy initialize proposes a revision rather than selecting one.
        if envelopes.contains(where: { $0.method == "initialize" }), revision != .r20260728,
           (declaredVersion(value) as? String) != MCPRevision.r20260728.rawValue {
            guard !isBatch else { return .rejected("MCP `initialize` must be exactly one non-batched request", batch: true) }
            guard case .request(_, let params, _) = envelopes[0] else {
                return .rejected("MCP `initialize` must be a request with an id")
            }
            guard let p = params as? [String: Any] else {
                return .rejected(params == nil ? "MCP `initialize` params are required" : "invalid MCP `initialize` params")
            }
            if let why = methodRules["initialize"]!.validate(p, .r20251125) {
                return .rejected("invalid MCP `initialize` params: \(why)")
            }
            return MCPInfo(calls: [MCPCall(method: "initialize", tool: nil, classification: .available)])
        }
        guard let revision else { return .rejected("MCP effective protocol revision has not been selected", batch: isBatch) }

        // Common request metadata.
        let messages = (value as? [Any]) ?? [value]
        for m in messages {
            if let d = declaredVersion(m), (d as? String) != revision.rawValue {
                return .rejected("MCP request metadata protocol version must match the selected revision", batch: isBatch)
            }
        }
        var info = MCPInfo(isBatch: isBatch)
        if revision == .r20260728 {
            guard let o = value as? [String: Any], let method = o["method"] as? String else {
                return .rejected("MCP 2026-07-28 HTTP bodies must contain one request or extension notification", batch: isBatch)
            }
            if o["id"] == nil {
                if method == "notifications/cancelled" {
                    return .rejected("MCP 2026-07-28 notifications/cancelled is not available over HTTP")
                }
            } else {
                guard let meta = (o["params"] as? [String: Any])?["_meta"] else {
                    return .rejected("MCP 2026-07-28 requests require params._meta")
                }
                if let why = validate2026Meta(meta) { return .rejected(why) }
                info.hasHTTPMetadata = true
                info.httpMethod = method
            }
        }

        // Exact-revision inspection (tower-mcp-types `inspect_payload`).
        if isBatch {
            if revision != .r20250326 { return .rejected("MCP \(revision.rawValue) does not permit top-level JSON-RPC batches", batch: true) }
            if envelopes.count > maxLegacyBatch { return .rejected("MCP batch exceeds \(maxLegacyBatch) messages", batch: true) }
        }
        for e in envelopes {
            let method: String, params: Any?, isRequest: Bool
            switch e {
            case .request(let m, let p, _): (method, params, isRequest) = (m, p, true)
            case .notification(let m, let p, _): (method, params, isRequest) = (m, p, false)
            case .result, .error: info.hasResponse = true; continue
            }
            guard let rule = methodRules[method] else {
                info.calls.append(MCPCall(method: method, tool: nil, classification: .extension_))
                continue
            }
            let availableIn = rule.clientToServer.union(serverToClient[method] ?? [])
            guard availableIn.contains(revision) else {
                return .rejected("MCP \(revision.rawValue) does not make `\(method)` available", batch: isBatch)
            }
            guard isRequest == rule.isRequest else {
                return .rejected("MCP \(revision.rawValue) defines `\(method)` as a \(rule.isRequest ? "request" : "notification")", batch: isBatch)
            }
            guard rule.clientToServer.contains(revision) else {
                return .rejected("MCP \(revision.rawValue) does not permit `\(method)` in the client-to-server direction", batch: isBatch)
            }
            if isBatch, method == "initialize" {
                return .rejected("MCP `initialize` must not be part of a JSON-RPC batch", batch: true)
            }
            if params == nil, rule.requiredParams.contains(revision) {
                return .rejected("invalid `\(method)` params for MCP \(revision.rawValue): required `params` field is missing", batch: isBatch)
            }
            let p: [String: Any]
            if let params { guard let o = params as? [String: Any] else {
                return .rejected("invalid `\(method)` params: MCP method params must be a JSON object", batch: isBatch)
            }; p = o } else { p = [:] }
            if let why = rule.validate(p, revision) {
                return .rejected("invalid `\(method)` params for MCP \(revision.rawValue): \(why)", batch: isBatch)
            }
            if revision == .r20260728, isRequest {
                guard let meta = p["_meta"] else { return .rejected("required `_meta` field is missing", batch: isBatch) }
                if let why = validate2026Meta(meta) { return .rejected(why, batch: isBatch) }
            }
            var tool: String?
            switch method {
            case "tools/call": tool = p["name"] as? String; info.httpName = tool
            case "prompts/get": info.httpName = p["name"] as? String
            case "resources/read": info.httpName = p["uri"] as? String
            default: break
            }
            if strictToolNames, let t = tool, !isStrictToolName(t) {
                return .rejected("invalid MCP tool name", batch: isBatch)
            }
            info.calls.append(MCPCall(method: method, tool: tool, classification: .available))
        }
        return info
    }

    private static func validate2026Meta(_ meta: Any) -> String? {
        guard let m = meta as? [String: Any] else { return "`_meta` must be an object" }
        guard let v = m["io.modelcontextprotocol/protocolVersion"] else {
            return "missing `_meta` key io.modelcontextprotocol/protocolVersion"
        }
        guard m["io.modelcontextprotocol/clientCapabilities"] is [String: Any] else {
            return "missing `_meta` key io.modelcontextprotocol/clientCapabilities"
        }
        guard (v as? String) == MCPRevision.r20260728.rawValue else {
            return "`_meta[\"io.modelcontextprotocol/protocolVersion\"]` must equal `2026-07-28`"
        }
        return nil
    }

    static func isStrictToolName(_ t: String) -> Bool {
        strictToolName.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    // MARK: transport (l7/mcp.rs)

    /// Select the revision and inspect the request under it. `.failure` is a
    /// transport rejection (400 / 403 / 405).
    func mcpTransportInspect(_ r: L7Request, _ ep: Endpoint) -> Result<MCPInfo, MCPRejection> {
        let body = r.body ?? Data()
        guard r.bodyComplete, body.count <= ep.mcp.maxBody else {
            return .failure(.init(status: 400, reason: "MCP request body exceeds the \(ep.mcp.maxBody)-byte inspection limit"))
        }
        let accepts = (r.headers["accept"] ?? "").split(separator: ",").contains {
            $0.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "text/event-stream"
        }
        let receiveStream = r.method == "GET" && body.isEmpty && accepts
        let bootstrap = receiveStream ? MCPInfo(receiveStream: true)
                                      : Self.inspectMCP(body, revision: nil, strictToolNames: ep.mcp.strictToolNames)

        let version: MCPRevision
        if let raw = r.headers["mcp-protocol-version"] {
            let v = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard !v.isEmpty else {
                return .failure(.init(status: 400, reason: "MCP-Protocol-Version must contain one non-empty end-to-end header value"))
            }
            guard let parsed = MCPRevision(rawValue: v) else {
                return .failure(.init(status: 400, reason: "MCP-Protocol-Version names an unsupported protocol version"))
            }
            version = parsed
        } else {
            version = .r20250326
        }
        let allowed = ep.mcp.versions.compactMap(MCPRevision.init(rawValue:))
        let modernOnly = !allowed.isEmpty && allowed.allSatisfy { $0 == .r20260728 }
        let standaloneInit = !bootstrap.isBatch && !bootstrap.hasResponse && bootstrap.error == nil
            && bootstrap.calls.count == 1 && bootstrap.calls[0].method == "initialize"
        if standaloneInit, version != .r20260728, !modernOnly { return .success(bootstrap) }

        guard allowed.contains(version) else {
            return .failure(.init(status: 403, reason: "MCP protocol version \(version.rawValue) is not allowed by endpoint policy"))
        }
        if version == .r20260728, r.method != "POST" {
            return .failure(.init(status: 405, reason: "MCP protocol version 2026-07-28 requires HTTP POST"))
        }
        let info = receiveStream ? MCPInfo(receiveStream: true)
                                 : Self.inspectMCP(body, revision: version, strictToolNames: ep.mcp.strictToolNames)
        if let e = info.error { return .failure(.init(status: 400, reason: "MCP request rejected: \(e)")) }

        // Sessionless header mirrors.
        if version == .r20260728, info.hasHTTPMetadata {
            let bad = MCPRejection(status: 400, reason: "MCP request headers must match the inspected request metadata")
            guard r.headers["mcp-protocol-version"]?.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                    == MCPRevision.r20260728.rawValue,
                  let m = r.headers["mcp-method"]?.trimmingCharacters(in: CharacterSet(charactersIn: " \t")),
                  Self.isPlainHeaderValue(m), m == info.httpMethod else { return .failure(bad) }
            if let name = info.httpName {
                guard let raw = r.headers["mcp-name"]?.trimmingCharacters(in: CharacterSet(charactersIn: " \t")),
                      let decoded = Self.decodeNameHeader(raw), decoded == name else { return .failure(bad) }
            }
        }
        return .success(info)
    }

    struct MCPRejection: Error { let status: Int; let reason: String }

    private static func isPlainHeaderValue(_ v: String) -> Bool {
        v.utf8.allSatisfy { $0 == 0x09 || (0x20...0x7E).contains($0) }
    }

    private static func decodeNameHeader(_ v: String) -> String? {
        if v.hasPrefix("=?base64?"), v.hasSuffix("?="), v.count >= 11 {
            let enc = String(v.dropFirst(9).dropLast(2))
            guard let d = Data(base64Encoded: enc) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        return isPlainHeaderValue(v) ? v : nil
    }

    // MARK: authorization (sandbox-policy.rego, JSON-RPC family, protocol mcp)

    /// One policy-engine request: a single call, or the whole request when it
    /// carries no call of its own (responses, receive stream).
    struct MCPUnit {
        var call: MCPCall?
        var hasResponse: Bool
        var receiveStream: Bool
    }

    static func mcpUnits(_ info: MCPInfo) -> [MCPUnit] {
        if info.isBatch, !info.calls.isEmpty {
            var units: [MCPUnit] = []
            if info.hasResponse { units.append(MCPUnit(call: nil, hasResponse: true, receiveStream: false)) }
            return units + info.calls.map { MCPUnit(call: $0, hasResponse: false, receiveStream: false) }
        }
        return [MCPUnit(call: info.isBatch ? nil : info.calls.first, hasResponse: info.hasResponse,
                        receiveStream: info.receiveStream)]
    }

    func mcpAllows(_ u: MCPUnit, httpMethod: String, on ep: Endpoint) -> Bool {
        if httpMethod == "GET" { return u.receiveStream && u.call == nil && !u.hasResponse }
        guard httpMethod == "POST" else { return false }
        if u.hasResponse { return true }
        guard let call = u.call else { return false }
        for rule in ep.rpcRules {
            let pattern = rule.method ?? (rule.tool != nil ? "tools/call" : "*")
            guard RegoGlob.match(pattern, delimiters: [], call.method), Self.toolMatches(rule.tool, call.tool) else { continue }
            if call.classification == .available || pattern == call.method { return true }
        }
        if ep.mcp.allowAllKnown, call.classification == .available {
            let narrowed = call.method == "tools/call" && ep.rpcRules.contains { $0.tool != nil }
            if !narrowed { return true }
        }
        return false
    }

    func mcpDenies(_ u: MCPUnit, httpMethod: String, on ep: Endpoint) -> Bool {
        guard httpMethod == "POST", let call = u.call else { return false }
        return ep.rpcDenyRules.contains { rule in
            guard let m = rule.method else { return false }
            return RegoGlob.match(m, delimiters: [], call.method) && Self.toolMatches(rule.tool, call.tool)
        }
    }
}
