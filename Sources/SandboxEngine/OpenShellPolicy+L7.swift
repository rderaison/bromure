import Foundation

// MARK: - MCP / JSON-RPC / GraphQL request inspection
//
// Semantics follow OpenShell's schema reference ("MCP Rules", "JSON-RPC
// Rules", "GraphQL Rules") and `sandbox-policy.rego`: one denied message or
// operation denies the whole (batched) request; server responses and
// server-to-client messages are not inspected.

extension OpenShellPolicy {
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
            return RegoGlob.match(pattern, delimiters: [], method)
        }
        return pattern == method
    }

    static func toolMatches(_ globs: [String]?, _ tool: String?) -> Bool {
        guard let globs else { return true }
        guard let tool else { return false }
        return globs.contains { RegoGlob.match($0, delimiters: [], tool) }
    }

    static let strictToolName = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.-]{1,128}$")

    func evaluateJSONRPC(_ r: L7Request, _ ep: Endpoint) -> EndpointVerdict {
        // rego: JSON-RPC rules (allow and deny) apply to POST only.
        guard r.method == "POST" else { return .notPermitted(nil) }
        guard let body = r.body, !body.isEmpty else { return .hardDeny("JSON-RPC request has no body") }
        guard r.bodyComplete, body.count <= ep.jsonRPCMaxBody else {
            return .hardDeny("JSON-RPC request body exceeds the \(ep.jsonRPCMaxBody)-byte inspection limit")
        }
        guard let messages = Self.rpcMessages(body) else { return .hardDeny("request is not valid JSON-RPC") }
        for msg in messages {
            guard let m = msg.method else {
                return .hardDeny("JSON-RPC response frames are not permitted from client to server")
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

    /// One classified operation (l7/graphql.rs `GraphqlOperationInfo`).
    struct GraphQLRequestOp {
        var op: GraphQLOperation            // type "" for a hash/id-only persisted query
        var persisted = false
        var hash: String?
        var id: String?
        var needsRegistry: Bool { persisted && op.type.isEmpty }
        var registryKey: String? { hash ?? id }
    }

    /// Classify a GraphQL HTTP request as OpenShell does: GET from unique
    /// query parameters, POST from a JSON envelope (or non-empty batch), any
    /// other method refused; one operation per envelope, chosen by
    /// `operationName` (required when the document has several).
    static func classifyGraphQL(_ r: L7Request, maxBody: Int) -> Result<[GraphQLRequestOp], GraphQLDocument.ParseError> {
        func fail(_ m: String) -> Result<[GraphQLRequestOp], GraphQLDocument.ParseError> { .failure(.init(message: m)) }
        if let enc = r.headers["content-encoding"]?.trimmingCharacters(in: .whitespaces).lowercased(),
           !enc.isEmpty, enc != "identity" { return fail("GraphQL request content-encoding \"\(enc)\" is not supported") }
        if (r.headers["content-type"] ?? "").trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("multipart/") {
            return fail("GraphQL multipart requests are not supported")
        }
        if !r.bodyComplete || (r.body?.count ?? 0) > maxBody {
            return fail("GraphQL request body exceeds \(maxBody) byte inspection limit")
        }
        func envelope(query: String?, name: String?, extensions: Any?, id: String?) -> Result<GraphQLRequestOp, GraphQLDocument.ParseError> {
            graphQLEnvelope(query: query, name: name, extensions: extensions, id: id)
        }
        switch r.method {
        case "GET":
            func unique(_ k: String) -> Result<String?, GraphQLDocument.ParseError> {
                guard let vs = r.query[k] else { return .success(nil) }
                guard vs.count <= 1 else { return .failure(.init(message: "GraphQL GET parameter \"\(k)\" must not appear more than once")) }
                return .success(vs.first.flatMap { $0.isEmpty ? nil : $0 })
            }
            do {
                let q = try unique("query").get(), name = try unique("operationName").get()
                let ext = try unique("extensions").get().flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                var id: (String, String)?
                for k in ["id", "documentId", "queryId"] {
                    guard let v = try unique(k).get() else { continue }
                    if let (prev, _) = id {
                        return fail("GraphQL GET persisted-query id parameters \"\(prev)\" and \"\(k)\" must not be combined")
                    }
                    id = (k, v)
                }
                return envelope(query: q, name: name, extensions: ext, id: id?.1).map { [$0] }
            } catch let e as GraphQLDocument.ParseError { return .failure(e) } catch { return fail("GraphQL GET rejected") }
        case "POST":
            guard let body = r.body, !body.isEmpty else { return fail("GraphQL POST body is empty") }
            guard let value = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
                return fail("GraphQL request body is not valid JSON")
            }
            let items: [Any]
            if let a = value as? [Any] {
                guard !a.isEmpty else { return fail("GraphQL batch request is empty") }
                items = a
            } else if value is [String: Any] {
                items = [value]
            } else {
                return fail("GraphQL JSON envelope must be an object or array")
            }
            var out: [GraphQLRequestOp] = []
            for item in items {
                guard let o = item as? [String: Any] else { return fail("GraphQL batch item must be an object") }
                let id = (o["id"] ?? o["documentId"] ?? o["queryId"]) as? String
                switch envelope(query: o["query"] as? String, name: o["operationName"] as? String,
                                extensions: o["extensions"], id: id) {
                case .success(let op): out.append(op)
                case .failure(let e): return .failure(e)
                }
            }
            return .success(out)
        default:
            return fail("unsupported GraphQL HTTP method \(r.method)")
        }
    }

    /// One GraphQL request envelope (`classify_envelope`): the operation its
    /// document selects (by `operationName` when there are several), or a
    /// persisted-query reference.
    static func graphQLEnvelope(query: String?, name: String?, extensions: Any?, id: String?) -> Result<GraphQLRequestOp, GraphQLDocument.ParseError> {
            let hash = persistedHash(extensions).flatMap { $0.isEmpty ? nil : $0 }
            if let q = query, !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    let ops = try GraphQLDocument.operations(in: q)
                    let selected: GraphQLOperation
                    if let name, !name.isEmpty {
                        guard let hit = ops.first(where: { $0.name == name }) else {
                            return .failure(.init(message: "GraphQL operationName \"\(name)\" was not found"))
                        }
                        selected = hit
                    } else if ops.count == 1 {
                        selected = ops[0]
                    } else {
                        return .failure(.init(message: "GraphQL document has multiple operations but no operationName"))
                    }
                    return .success(GraphQLRequestOp(op: selected, persisted: hash != nil || id != nil, hash: hash, id: id))
                } catch let e as GraphQLDocument.ParseError {
                    return .failure(.init(message: "GraphQL document parse error: \(e.message)"))
                } catch {
                    return .failure(.init(message: "GraphQL document parse error"))
                }
            }
            if hash != nil || id != nil {
                return .success(GraphQLRequestOp(op: GraphQLOperation(type: "", name: name, fields: []),
                                                 persisted: true, hash: hash, id: id))
            }
            return .failure(.init(message: "GraphQL request has no query document or persisted query identifier"))
        }

    /// A POST batch item / GraphQL-over-WebSocket payload (`classify_json_envelope`).
    static func classifyGraphQLEnvelope(_ o: [String: Any]) -> Result<GraphQLRequestOp, GraphQLDocument.ParseError> {
        graphQLEnvelope(query: o["query"] as? String, name: o["operationName"] as? String,
                        extensions: o["extensions"], id: (o["id"] ?? o["documentId"] ?? o["queryId"]) as? String)
    }

    /// A GraphQL endpoint is authoritative: the request is allowed only when
    /// every operation is allowed, and otherwise denied (never merely "not
    /// permitted", so a broader REST rule can't let it through).
    func evaluateGraphQL(_ r: L7Request, _ ep: Endpoint) -> EndpointVerdict {
        let ops: [GraphQLRequestOp]
        switch Self.classifyGraphQL(r, maxBody: ep.graphqlMaxBody) {
        case .failure(let e): return .deny("GraphQL request rejected: \(e.message)")
        case .success(let o): ops = o
        }
        return evaluateGraphQLOps(ops, ep)
    }

    /// Rego's GraphQL judgement of classified operations on one endpoint.
    func evaluateGraphQLOps(_ ops: [GraphQLRequestOp], _ ep: Endpoint) -> EndpointVerdict {
        guard !ops.isEmpty else { return .deny("GraphQL request has no operation") }
        var effective: [GraphQLOperation] = []
        for o in ops {
            guard o.needsRegistry else { effective.append(o.op); continue }
            guard ep.persistedQueriesAllowRegistered, let key = o.registryKey, let reg = ep.graphqlRegistry[key] else {
                return .deny("GraphQL persisted query is not registered")
            }
            effective.append(reg)
        }
        for op in effective where ep.gqlDenyRules.contains(where: { Self.gqlDenyMatches($0, op) }) {
            return .deny("GraphQL operation blocked by endpoint policy")
        }
        let allow = graphqlAllowMatchers(ep)
        for op in effective where !allow.contains(where: { Self.gqlAllowMatches($0, op) }) {
            return .deny("GraphQL \(op.type)\(op.name.map { " \($0)" } ?? "") not permitted by policy")
        }
        return .allow
    }

    private func graphqlAllowMatchers(_ ep: Endpoint) -> [GraphQLMatcher] {
        guard let access = ep.access else { return ep.gqlRules }
        switch access {
        case .readOnly:  return [GraphQLMatcher(operationType: "query", operationName: nil, fields: nil)]
        case .readWrite: return ["query", "mutation"].map { GraphQLMatcher(operationType: $0, operationName: nil, fields: nil) }
        case .full:      return [GraphQLMatcher(operationType: "*", operationName: nil, fields: nil)]
        }
    }

    static func persistedHash(_ extensions: Any?) -> String? {
        ((extensions as? [String: Any])?["persistedQuery"] as? [String: Any])?["sha256Hash"] as? String
    }

    /// rego `graphql_operation_name_matches`: an anonymous operation's name is "".
    static func gqlNameMatches(_ glob: String?, _ name: String?) -> Bool {
        guard let glob, !glob.isEmpty else { return true }
        return RegoGlob.match(glob, delimiters: [], name ?? "")
    }

    static func gqlTypeMatches(_ expected: String, _ actual: String) -> Bool {
        expected == "*" || (!expected.isEmpty && expected.lowercased() == actual.lowercased())
    }

    /// Allow: type + name match, and EVERY top-level field matches a glob
    /// (a rule with `fields` never matches an operation without fields).
    static func gqlAllowMatches(_ m: GraphQLMatcher, _ op: GraphQLOperation) -> Bool {
        guard gqlTypeMatches(m.operationType, op.type), gqlNameMatches(m.operationName, op.name) else { return false }
        guard let fields = m.fields, !fields.isEmpty else { return true }
        return !op.fields.isEmpty && op.fields.allSatisfy { f in fields.contains { RegoGlob.match($0, delimiters: [], f) } }
    }

    /// Deny: type + name match, and ONE top-level field matches (no `fields`
    /// = every matching operation).
    static func gqlDenyMatches(_ m: GraphQLMatcher, _ op: GraphQLOperation) -> Bool {
        guard gqlTypeMatches(m.operationType, op.type), gqlNameMatches(m.operationName, op.name) else { return false }
        guard let fields = m.fields, !fields.isEmpty else { return true }
        return op.fields.contains { f in fields.contains { RegoGlob.match($0, delimiters: [], f) } }
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

        // As OpenShell collects root fields: unknown fragments contribute
        // nothing, and each fragment is expanded at most once per operation.
        var visited = Set<String>()
        func flatten(_ sels: [Selection], _ seen: Set<String>) throws -> [String] {
            var out: [String] = []
            for s in sels {
                switch s {
                case .field(let f): out.append(f)
                case .inline(let inner): out += try flatten(inner, seen)
                case .spread(let n):
                    guard visited.insert(n).inserted, let frag = fragments[n] else { continue }
                    out += try flatten(frag, seen)
                }
            }
            return out
        }
        return try ops.map { op in
            visited = []
            return .init(type: op.type, name: op.name, fields: Array(Set(try flatten(op.selections, []))).sorted())
        }
    }

    indirect enum Selection { case field(String), spread(String), inline([Selection]) }
}
