import Foundation

// MARK: - MCP / JSON-RPC / GraphQL request inspection
//
// Semantics follow OpenShell's schema reference ("MCP Rules", "JSON-RPC
// Rules", "GraphQL Rules") and `sandbox-policy.rego`: one denied message or
// operation denies the whole (batched) request; server responses and
// server-to-client messages are not inspected.

extension OpenShellPolicy {
    /// MCP revisions OpenShell knows.
    static let knownMCPVersions: Set<String> = ["2025-03-26", "2025-06-18", "2025-11-25"]

    /// Client-to-server MCP methods ("every MCP method" for
    /// `mcp.allow_all_known_mcp_methods`).
    static let knownMCPMethods: Set<String> = [
        "initialize", "ping", "tools/list", "tools/call", "resources/list", "resources/read",
        "resources/templates/list", "resources/subscribe", "resources/unsubscribe", "prompts/list",
        "prompts/get", "completion/complete", "logging/setLevel", "notifications/initialized",
        "notifications/cancelled", "notifications/progress", "notifications/roots/list_changed",
        "tasks/get", "tasks/list", "tasks/cancel", "tasks/result",
    ]

    /// A JSON-RPC message the client sent.
    struct RPCMessage {
        var method: String?
        var toolName: String?
        var isResponse: Bool
    }

    static func rpcMessages(_ body: Data) -> [RPCMessage]? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) else { return nil }
        let list: [Any]
        if let a = obj as? [Any] { list = a } else { list = [obj] }
        guard !list.isEmpty else { return nil }
        var out: [RPCMessage] = []
        for item in list {
            guard let m = item as? [String: Any] else { return nil }
            let method = m["method"] as? String
            let tool = (m["params"] as? [String: Any])?["name"] as? String
            let isResponse = method == nil && (m["result"] != nil || m["error"] != nil)
            guard method != nil || isResponse else { return nil }
            out.append(RPCMessage(method: method, toolName: tool, isResponse: isResponse))
        }
        return out
    }

    /// Method matching: exact, `*` (JSON-RPC only — validated), or a glob in
    /// the MCP `tools/` family.
    static func rpcMethodMatches(_ pattern: String?, _ method: String) -> Bool {
        guard let pattern else { return true }
        if pattern == "*" { return true }
        if pattern.contains("*") || pattern.contains("?") || pattern.contains("[") {
            return Glob.match(pattern, method, separator: "/", caseInsensitive: false)
        }
        return pattern == method
    }

    static func toolMatches(_ globs: [String]?, _ tool: String?) -> Bool {
        guard let globs else { return true }
        guard let tool else { return false }
        return globs.contains { Glob.match($0, tool, separator: ".", caseInsensitive: false) }
    }

    static let strictToolName = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.-]{1,128}$")

    func evaluateMCP(_ r: L7Request, _ ep: Endpoint) -> EndpointVerdict {
        // Streamable HTTP: GET opens the server stream, DELETE ends the
        // session — no client message to inspect.
        if ["GET", "DELETE", "HEAD", "OPTIONS"].contains(r.method), (r.body ?? Data()).isEmpty { return .allow }
        guard let body = r.body, !body.isEmpty else { return .deny("MCP request has no body") }
        guard r.bodyComplete, body.count <= ep.mcp.maxBody else {
            return .deny("MCP request body exceeds the \(ep.mcp.maxBody)-byte inspection limit")
        }
        guard let messages = Self.rpcMessages(body) else { return .deny("MCP request is not valid JSON-RPC") }

        // Revision: from the header, except on a lone `initialize` (it negotiates).
        let isInitialize = messages.count == 1 && messages[0].method == "initialize"
        if !isInitialize {
            let v = r.headers["mcp-protocol-version"] ?? "2025-03-26"
            guard Self.knownMCPVersions.contains(v) else { return .deny("unsupported MCP-Protocol-Version \(v)") }
            guard ep.mcp.versions.contains(v) else { return .deny("MCP revision \(v) is not allowed on this endpoint") }
        }

        let toolRules = ep.rpcRules.filter { $0.tool != nil }
        for msg in messages {
            if msg.isResponse { continue }                       // answers to server requests
            let m = msg.method!
            if m == "tools/call", ep.mcp.strictToolNames {
                guard let t = msg.toolName, Self.strictToolName.firstMatch(
                    in: t, range: NSRange(t.startIndex..., in: t)) != nil else {
                    return .deny("tools/call with an invalid tool name")
                }
            }
            if ep.rpcDenyRules.contains(where: { Self.rpcMethodMatches($0.method, m) && Self.toolMatches($0.tool, msg.toolName) }) {
                return .deny("MCP \(m)\(msg.toolName.map { " \($0)" } ?? "") blocked by deny rule")
            }
            let allowed: Bool
            if ep.mcp.allowAllKnown {
                allowed = Self.knownMCPMethods.contains(m)
                    && (m != "tools/call" || toolRules.isEmpty
                        || toolRules.contains { Self.toolMatches($0.tool, msg.toolName) })
            } else {
                allowed = ep.rpcRules.contains { Self.rpcMethodMatches($0.method, m) && Self.toolMatches($0.tool, msg.toolName) }
            }
            if !allowed {
                return .notPermitted("MCP \(m)\(msg.toolName.map { " \($0)" } ?? "") not permitted by policy")
            }
        }
        return .allow
    }

    func evaluateJSONRPC(_ r: L7Request, _ ep: Endpoint) -> EndpointVerdict {
        guard let body = r.body, !body.isEmpty else { return .deny("JSON-RPC request has no body") }
        guard r.bodyComplete, body.count <= ep.jsonRPCMaxBody else {
            return .deny("JSON-RPC request body exceeds the \(ep.jsonRPCMaxBody)-byte inspection limit")
        }
        guard let messages = Self.rpcMessages(body) else { return .deny("request is not valid JSON-RPC") }
        for msg in messages {
            guard let m = msg.method else {
                return .deny("JSON-RPC response frames are not permitted from client to server")
            }
            if ep.rpcDenyRules.contains(where: { Self.rpcMethodMatches($0.method, m) }) {
                return .deny("JSON-RPC \(m) blocked by deny rule")
            }
            if !ep.rpcRules.contains(where: { Self.rpcMethodMatches($0.method, m) }) {
                return .notPermitted("JSON-RPC \(m) not permitted by policy")
            }
        }
        return .allow
    }

    // MARK: GraphQL

    func evaluateGraphQL(_ r: L7Request, _ ep: Endpoint) -> EndpointVerdict {
        if !r.bodyComplete || (r.body?.count ?? 0) > ep.graphqlMaxBody {
            return .deny("GraphQL request body exceeds the \(ep.graphqlMaxBody)-byte inspection limit")
        }
        // Collect (query text?, persisted hash?) per request in a (batched) call.
        var requests: [(query: String?, hash: String?)] = []
        if r.method == "GET" {
            let q = r.query["query"]?.first
            requests.append((q, Self.persistedHash(r.query["extensions"]?.first.flatMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) })))
        } else if let body = r.body, !body.isEmpty {
            if (r.headers["content-type"] ?? "").lowercased().hasPrefix("application/graphql") {
                requests.append((String(decoding: body, as: UTF8.self), nil))
            } else {
                guard let obj = try? JSONSerialization.jsonObject(with: body) else {
                    return .deny("GraphQL request rejected: body is not JSON")
                }
                let list = (obj as? [Any]) ?? [obj]
                for item in list {
                    guard let d = item as? [String: Any] else { return .deny("GraphQL request rejected: malformed batch") }
                    let hash = Self.persistedHash(d["extensions"])
                        ?? (d["id"] as? String) ?? (d["documentId"] as? String)
                    requests.append((d["query"] as? String, hash))
                }
            }
        }
        guard !requests.isEmpty else { return .deny("GraphQL request has no operation") }

        var ops: [GraphQLOperation] = []
        for req in requests {
            if let q = req.query, !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do { ops += try GraphQLDocument.operations(in: q) }
                catch { return .deny("GraphQL request rejected: \(error)") }
            } else if let h = req.hash {
                guard ep.persistedQueriesAllowRegistered, let op = ep.graphqlRegistry[h] else {
                    return .deny("GraphQL persisted query is not registered")
                }
                ops.append(op)
            } else {
                return .deny("GraphQL request rejected: no query")
            }
        }

        let allow = graphqlAllowMatchers(ep)
        for op in ops {
            if ep.gqlDenyRules.contains(where: { Self.gqlDenyMatches($0, op) }) {
                return .deny("GraphQL operation blocked by endpoint policy")
            }
        }
        for op in ops where !allow.contains(where: { Self.gqlAllowMatches($0, op) }) {
            return .notPermitted("GraphQL \(op.type)\(op.name.map { " \($0)" } ?? "") not permitted by policy")
        }
        return .allow
    }

    private func graphqlAllowMatchers(_ ep: Endpoint) -> [GraphQLMatcher] {
        guard let access = ep.access else { return ep.gqlRules }
        let types: [String]
        switch access {
        case .readOnly:  types = ["query"]
        case .readWrite: types = ["query", "mutation"]
        case .full:      types = ["query", "mutation", "subscription"]
        }
        return types.map { GraphQLMatcher(operationType: $0, operationName: nil, fields: nil) }
    }

    static func persistedHash(_ extensions: Any?) -> String? {
        ((extensions as? [String: Any])?["persistedQuery"] as? [String: Any])?["sha256Hash"] as? String
    }

    static func gqlNameMatches(_ glob: String?, _ name: String?) -> Bool {
        guard let glob else { return true }
        guard let name else { return false }
        return Glob.match(glob, name, separator: nil, caseInsensitive: false)
    }

    /// Allow: type + name match, and EVERY top-level field matches a glob.
    static func gqlAllowMatches(_ m: GraphQLMatcher, _ op: GraphQLOperation) -> Bool {
        guard m.operationType == op.type, gqlNameMatches(m.operationName, op.name) else { return false }
        guard let fields = m.fields else { return true }
        return op.fields.allSatisfy { f in fields.contains { Glob.match($0, f, separator: nil, caseInsensitive: false) } }
    }

    /// Deny: type + name match, and ONE top-level field matches (no `fields`
    /// = every matching operation).
    static func gqlDenyMatches(_ m: GraphQLMatcher, _ op: GraphQLOperation) -> Bool {
        guard m.operationType == op.type, gqlNameMatches(m.operationName, op.name) else { return false }
        guard let fields = m.fields else { return true }
        return op.fields.contains { f in fields.contains { Glob.match($0, f, separator: nil, caseInsensitive: false) } }
    }
}

/// Just enough of a GraphQL parser to list each operation's type, name and
/// top-level fields (aliases resolved to the field name; inline fragments and
/// fragment spreads at the top level flattened into their fields).
enum GraphQLDocument {
    struct ParseError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    enum Token: Equatable { case name(String), punct(Character), spread, string, number, variable(String) }

    static func tokenize(_ s: String) throws -> [Token] {
        var out: [Token] = []
        let c = Array(s.unicodeScalars)
        var i = 0
        func isNameStart(_ u: Unicode.Scalar) -> Bool { u == "_" || (u.value < 128 && CharacterSet.letters.contains(u)) }
        func isName(_ u: Unicode.Scalar) -> Bool { isNameStart(u) || (u.value >= 48 && u.value <= 57) }
        while i < c.count {
            let u = c[i]
            if u == " " || u == "\t" || u == "\n" || u == "\r" || u == "," || u == "\u{FEFF}" { i += 1; continue }
            if u == "#" { while i < c.count, c[i] != "\n" { i += 1 }; continue }
            if u == "\"" {
                if i + 2 < c.count, c[i + 1] == "\"", c[i + 2] == "\"" {           // block string
                    i += 3
                    while i + 2 < c.count, !(c[i] == "\"" && c[i + 1] == "\"" && c[i + 2] == "\"") {
                        if c[i] == "\\" { i += 1 }
                        i += 1
                    }
                    guard i + 2 < c.count else { throw ParseError(message: "unterminated block string") }
                    i += 3
                } else {
                    i += 1
                    while i < c.count, c[i] != "\"" {
                        if c[i] == "\n" { throw ParseError(message: "unterminated string") }
                        if c[i] == "\\" { i += 1 }
                        i += 1
                    }
                    guard i < c.count else { throw ParseError(message: "unterminated string") }
                    i += 1
                }
                out.append(.string); continue
            }
            if u == ".", i + 2 < c.count, c[i + 1] == ".", c[i + 2] == "." { out.append(.spread); i += 3; continue }
            if u == "$" {
                var j = i + 1
                while j < c.count, isName(c[j]) { j += 1 }
                out.append(.variable(String(String.UnicodeScalarView(c[(i + 1)..<j])))); i = j; continue
            }
            if isNameStart(u) {
                var j = i
                while j < c.count, isName(c[j]) { j += 1 }
                out.append(.name(String(String.UnicodeScalarView(c[i..<j])))); i = j; continue
            }
            if u == "-" || (u.value >= 48 && u.value <= 57) {
                var j = i + 1
                while j < c.count, isName(c[j]) || c[j] == "." || c[j] == "+" || c[j] == "-" { j += 1 }
                out.append(.number); i = j; continue
            }
            if "{}()[]:=@!|&".unicodeScalars.contains(u) { out.append(.punct(Character(u))); i += 1; continue }
            throw ParseError(message: "unexpected character '\(Character(u))'")
        }
        return out
    }

    static func operations(in source: String) throws -> [OpenShellPolicy.GraphQLOperation] {
        let t = try tokenize(source)
        var i = 0
        var ops: [(type: String, name: String?, selections: [Selection])] = []
        var fragments: [String: [Selection]] = [:]

        func peek() -> Token? { i < t.count ? t[i] : nil }
        func skipBalanced(_ open: Character, _ close: Character) throws {
            guard peek() == .punct(open) else { return }
            var depth = 0
            repeat {
                guard i < t.count else { throw ParseError(message: "unbalanced '\(open)'") }
                if t[i] == .punct(open) { depth += 1 }
                if t[i] == .punct(close) { depth -= 1 }
                i += 1
            } while depth > 0
        }
        func skipDirectives() throws {
            while peek() == .punct("@") {
                i += 1
                guard case .name? = peek() else { throw ParseError(message: "directive name expected") }
                i += 1
                try skipBalanced("(", ")")
            }
        }
        // Top-level selections of a selection set; nested sets are skipped.
        func selectionSet() throws -> [Selection] {
            guard peek() == .punct("{") else { throw ParseError(message: "selection set expected") }
            i += 1
            var sels: [Selection] = []
            while let tok = peek(), tok != .punct("}") {
                if tok == .spread {
                    i += 1
                    if case .name(let n)? = peek(), n != "on" {
                        i += 1
                        try skipDirectives()
                        sels.append(.spread(n))
                    } else {
                        if case .name("on")? = peek() { i += 2 }            // on TypeName
                        try skipDirectives()
                        sels.append(.inline(try selectionSet()))
                    }
                    continue
                }
                guard case .name(var field) = tok else { throw ParseError(message: "field expected") }
                i += 1
                if peek() == .punct(":") {                                  // alias: field
                    i += 1
                    guard case .name(let real)? = peek() else { throw ParseError(message: "field expected after alias") }
                    field = real
                    i += 1
                }
                try skipBalanced("(", ")")
                try skipDirectives()
                try skipBalanced("{", "}")
                sels.append(.field(field))
            }
            guard peek() == .punct("}") else { throw ParseError(message: "unterminated selection set") }
            i += 1
            return sels
        }

        while let tok = peek() {
            switch tok {
            case .punct("{"):
                ops.append(("query", nil, try selectionSet()))
            case .name(let kw) where ["query", "mutation", "subscription"].contains(kw):
                i += 1
                var name: String?
                if case .name(let n)? = peek() { name = n; i += 1 }
                try skipBalanced("(", ")")
                try skipDirectives()
                ops.append((kw, name, try selectionSet()))
            case .name("fragment"):
                i += 1
                guard case .name(let n)? = peek() else { throw ParseError(message: "fragment name expected") }
                i += 1
                guard case .name("on")? = peek() else { throw ParseError(message: "'on' expected") }
                i += 2
                try skipDirectives()
                fragments[n] = try selectionSet()
            default:
                throw ParseError(message: "unexpected token at the top level")
            }
        }
        guard !ops.isEmpty else { throw ParseError(message: "document has no operation") }

        func flatten(_ sels: [Selection], _ seen: Set<String>) throws -> [String] {
            var out: [String] = []
            for s in sels {
                switch s {
                case .field(let f): out.append(f)
                case .inline(let inner): out += try flatten(inner, seen)
                case .spread(let n):
                    guard let frag = fragments[n] else { throw ParseError(message: "unknown fragment \(n)") }
                    guard !seen.contains(n) else { throw ParseError(message: "fragment cycle at \(n)") }
                    out += try flatten(frag, seen.union([n]))
                }
            }
            return out
        }
        return try ops.map { .init(type: $0.type, name: $0.name, fields: try flatten($0.selections, [])) }
    }

    indirect enum Selection { case field(String), spread(String), inline([Selection]) }
}
