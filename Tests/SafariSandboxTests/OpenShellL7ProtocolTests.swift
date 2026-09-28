import Foundation
import Testing
@testable import SandboxEngine

@Suite("OpenShell MCP / JSON-RPC / GraphQL inspection")
struct OpenShellL7ProtocolTests {
    private func policy(_ yaml: String) throws -> OpenShellPolicy { try OpenShellPolicy.parse(yaml) }

    private func post(_ p: OpenShellPolicy, _ host: String, _ path: String, _ json: String,
                      headers: [String: String] = [:], method: String = "POST") -> OpenShellPolicy.RequestDecision {
        p.evaluateRequest(host: host, port: 443, method: method, target: path, headers: headers,
                          body: json.isEmpty ? nil : Data(json.utf8))
    }

    private func allowed(_ d: OpenShellPolicy.RequestDecision) -> Bool { d == .allow }

    static let mcpPolicy = """
    version: 1
    network_policies:
      mcp:
        endpoints:
          - host: mcp.example.com
            port: 443
            protocol: mcp
            enforcement: enforce
            mcp: { versions: ["2025-06-18", "2025-11-25"] }
            rules:
              - allow: { method: initialize }
              - allow: { method: notifications/initialized }
              - allow: { method: tools/list }
              - allow:
                  method: tools/call
                  tool: { any: [search_web, "list_*"] }
            deny_rules:
              - { method: tools/call, tool: send_email }
    """

    @Test("MCP: allowed tools pass, others and deny rules block")
    func mcpTools() throws {
        let p = try policy(Self.mcpPolicy)
        let v = ["mcp-protocol-version": "2025-11-25"]
        #expect(allowed(post(p, "mcp.example.com", "/mcp", #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)))
        #expect(allowed(post(p, "mcp.example.com", "/mcp",
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_issues"}}"#, headers: v)))
        #expect(!allowed(post(p, "mcp.example.com", "/mcp",
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"delete_repo"}}"#, headers: v)))
        #expect(post(p, "mcp.example.com", "/mcp",
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"send_email"}}"#, headers: v)
            == .violation(reason: "MCP tools/call send_email blocked by deny rule", rule: "mcp", enforced: true))
        // One denied message denies the whole batch.
        #expect(!allowed(post(p, "mcp.example.com", "/mcp",
            #"[{"jsonrpc":"2.0","id":5,"method":"tools/list"},{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"send_email"}}]"#, headers: v)))
        // Client responses to server requests are not inspected.
        #expect(allowed(post(p, "mcp.example.com", "/mcp", #"{"jsonrpc":"2.0","id":9,"result":{}}"#, headers: v)))
        // Opening the server stream carries no message.
        #expect(allowed(post(p, "mcp.example.com", "/mcp", "", method: "GET")))
    }

    @Test("MCP: revision header is checked (absent = 2025-03-26)")
    func mcpVersions() throws {
        let p = try policy(Self.mcpPolicy)
        let list = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        #expect(!allowed(post(p, "mcp.example.com", "/mcp", list)))                          // 2025-03-26 not allowed
        #expect(allowed(post(p, "mcp.example.com", "/mcp", list, headers: ["mcp-protocol-version": "2025-06-18"])))
        #expect(!allowed(post(p, "mcp.example.com", "/mcp", list, headers: ["mcp-protocol-version": "1999-01-01"])))
    }

    @Test("MCP: allow_all_known_mcp_methods with tool narrowing, strict tool names")
    func mcpAllowAll() throws {
        let p = try policy("""
        version: 1
        network_policies:
          m:
            endpoints:
              - host: mcp.example.com
                port: 443
                protocol: mcp
                enforcement: enforce
                mcp: { allow_all_known_mcp_methods: true }
                rules:
                  - allow: { tool: read_file }
        """)
        let v = ["mcp-protocol-version": "2025-11-25"]
        #expect(allowed(post(p, "mcp.example.com", "/", #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#, headers: v)))
        #expect(allowed(post(p, "mcp.example.com", "/", #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_file"}}"#, headers: v)))
        #expect(!allowed(post(p, "mcp.example.com", "/", #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"write_file"}}"#, headers: v)))
        #expect(!allowed(post(p, "mcp.example.com", "/", #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"bad name!"}}"#, headers: v)))
        #expect(!allowed(post(p, "mcp.example.com", "/", #"{"jsonrpc":"2.0","id":1,"method":"made/up"}"#, headers: v)))
    }

    @Test("MCP rule validation")
    func mcpValidation() {
        #expect(throws: OpenShellPolicy.ParseError.self) {
            try OpenShellPolicy.parse("""
            version: 1
            network_policies:
              m:
                endpoints: [{ host: a.example.com, port: 443, protocol: mcp, rules: [{ allow: { method: "*" } }] }]
            """)
        }
        #expect(throws: OpenShellPolicy.ParseError.self) {
            try OpenShellPolicy.parse("""
            version: 1
            network_policies:
              m:
                endpoints: [{ host: a.example.com, port: 443, protocol: mcp, rules: [{ allow: { method: "resources/*" } }] }]
            """)
        }
    }

    @Test("JSON-RPC: exact methods, deny rules, no client response frames")
    func jsonRPC() throws {
        let p = try policy("""
        version: 1
        network_policies:
          r:
            endpoints:
              - host: rpc.example.com
                port: 443
                protocol: json-rpc
                enforcement: enforce
                rules: [{ allow: { method: "*" } }]
                deny_rules: [{ method: reports.delete }]
        """)
        #expect(allowed(post(p, "rpc.example.com", "/", #"{"jsonrpc":"2.0","id":1,"method":"reports.search"}"#)))
        #expect(!allowed(post(p, "rpc.example.com", "/", #"{"jsonrpc":"2.0","id":1,"method":"reports.delete"}"#)))
        #expect(!allowed(post(p, "rpc.example.com", "/", #"{"jsonrpc":"2.0","id":1,"result":1}"#)))
        #expect(!allowed(post(p, "rpc.example.com", "/", "not json")))
    }

    static let gqlPolicy = """
    version: 1
    network_policies:
      gh:
        endpoints:
          - host: api.github.com
            port: 443
            path: /graphql
            protocol: graphql
            enforcement: enforce
            persisted_queries: allow_registered
            graphql_persisted_queries:
              abc123: { operation_type: query, operation_name: GetViewer, fields: [viewer] }
            rules:
              - allow: { operation_type: query }
              - allow: { operation_type: mutation, fields: [createIssue, "add*"] }
            deny_rules:
              - { operation_type: mutation, fields: [deleteRepository] }
    """

    @Test("GraphQL: operation types, top-level fields, deny rules")
    func graphql() throws {
        let p = try policy(Self.gqlPolicy)
        func q(_ query: String) -> OpenShellPolicy.RequestDecision {
            let body = try! JSONSerialization.data(withJSONObject: ["query": query])
            return p.evaluateRequest(host: "api.github.com", port: 443, method: "POST", target: "/graphql",
                                     headers: ["content-type": "application/json"], body: body)
        }
        #expect(allowed(q("{ viewer { login } }")))
        #expect(allowed(q("query Repos($n: Int = 5) @cached { repository(owner: \"a\", name: \"b\") { issues(first: $n) { nodes { title } } } }")))
        #expect(allowed(q("mutation { createIssue(input: {title: \"x\"}) { issue { id } } }")))
        #expect(allowed(q("mutation M { first: addComment(input: {}) { clientMutationId } }")))   // alias → addComment
        #expect(!allowed(q("mutation { createIssue(input: {}) { issue { id } } closeIssue(input: {}) { issue { id } } }")))
        #expect(q("mutation { deleteRepository(input: {}) { clientMutationId } }")
                == .violation(reason: "GraphQL operation blocked by endpoint policy", rule: "gh", enforced: true))
        #expect(!allowed(q("subscription { issueUpdated { id } }")))
        // Fragments at the top level are flattened.
        #expect(!allowed(q("mutation { ...F } fragment F on Mutation { deleteRepository(input: {}) { clientMutationId } }")))
        #expect(!allowed(q("{ viewer { login }")))                                                // parse error
        // Comments and strings don't confuse the tokenizer.
        #expect(allowed(q("# mutation { deleteRepository }\n{ viewer { login(arg: \"} mutation {\") } }")))
    }

    @Test("GraphQL: persisted queries need a registry entry; GET and batches are inspected")
    func graphqlPersistedAndGet() throws {
        let p = try policy(Self.gqlPolicy)
        func body(_ obj: Any) -> Data { try! JSONSerialization.data(withJSONObject: obj) }
        let registered = body(["extensions": ["persistedQuery": ["version": 1, "sha256Hash": "abc123"]]])
        #expect(allowed(p.evaluateRequest(host: "api.github.com", port: 443, method: "POST", target: "/graphql", body: registered)))
        let unknown = body(["extensions": ["persistedQuery": ["version": 1, "sha256Hash": "zzz"]]])
        #expect(!allowed(p.evaluateRequest(host: "api.github.com", port: 443, method: "POST", target: "/graphql", body: unknown)))
        let get = "/graphql?query=" + "mutation{deleteRepository(input:{}){clientMutationId}}"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(!allowed(p.evaluateRequest(host: "api.github.com", port: 443, method: "GET", target: get)))
        let batch = body([["query": "{ viewer { login } }"], ["query": "mutation { deleteRepository(input: {}) { x } }"]])
        #expect(!allowed(p.evaluateRequest(host: "api.github.com", port: 443, method: "POST", target: "/graphql", body: batch)))
    }

    @Test("A body too large to buffer is refused, not judged on a prefix")
    func incompleteBody() throws {
        let p = try policy(Self.mcpPolicy)
        let d = p.evaluateRequest(host: "mcp.example.com", port: 443, method: "POST", target: "/mcp",
                                  headers: ["mcp-protocol-version": "2025-11-25"],
                                  body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8), bodyComplete: false)
        #expect(!allowed(d))
    }
}
