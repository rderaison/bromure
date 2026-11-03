import Foundation
import Testing
@testable import SandboxEngine

/// Test vectors lifted from OpenShell's own unit tests (Apache-2.0), so
/// Bromure's port agrees with the reference on the documented edge cases.
/// Sources: openshell-supervisor-network `l7/path.rs`, `l7/mcp.rs`,
/// `l7/jsonrpc.rs`; openshell-core `endpoint_path.rs`; globset / regorus
/// semantics behind the Rego `glob.match`.
@Suite("OpenShell reference test vectors")
struct OpenShellVectorTests {

    // MARK: l7/path.rs — request-target canonicalization

    private func canon(_ t: String, slash: Bool = false) -> String? {
        try? OpenShellPolicy.canonicalize(target: t, allowEncodedSlash: slash).get().path
    }

    @Test("path.rs: canonical forms")
    func canonicalForms() {
        let vectors: [(String, String)] = [
            ("/a/./b", "/a/b"), ("/a/b/.", "/a/b/"), ("/a/../b", "/b"), ("/a/b/..", "/a/"),
            ("/public/%2e%2e/secret", "/secret"), ("/public/%2E%2E/secret", "/secret"),
            ("/public/%2e/secret", "/public/secret"),
            ("//", "/"), ("//public//../secret", "/secret"), ("/public//secret", "/public/secret"),
            ("http://host/a/../b", "/b"), ("https://host", "/"), ("http://host:443/foo", "/foo"),
            ("/fetch/http://example.test?next=http://other.test", "/fetch/http:/example.test"),
            ("/files/hello%20world.txt", "/files/hello%20world.txt"), ("/search/a%3Fb", "/search/a%3Fb"),
            ("/users/%40alice", "/users/@alice"),
            ("/a;jsessionid=xyz/b", "/a/b"), ("/public;x=1/../secret", "/secret"),
            ("/users/caf%C3%A9", "/users/caf%C3%A9"), ("/a/caf%c3%a9", "/a/caf%C3%A9"),
            ("", "/"), ("/", "/"), ("/a?q=1&r=2", "/a"),
            ("/public/../secret", "/secret"), ("//public/../secret", "/secret"), ("/public/./../secret", "/secret"),
            ("/public/..;/secret", "/secret"), ("/public/..;x/secret", "/secret"),
            ("/public/..;jsessionid=xyz/secret", "/secret"), ("/public/.;/secret", "/public/secret"),
            ("/public/.;x/secret", "/public/secret"),
            ("/public/%2e%2e;/secret", "/secret"), ("/public/..%3B/secret", "/secret"),
            ("/public/..%3b/secret", "/secret"),
            ("/a/%252F/b", "/a/%252F/b"), ("/a/100%25/b", "/a/100%25/b"),
        ]
        for (input, expected) in vectors {
            #expect(canon(input) == expected, "\(input) → \(canon(input) ?? "REJECTED")")
        }
    }

    @Test("path.rs: rejected targets")
    func rejectedTargets() {
        let rejected = [
            "/..", "/a/../..", "/a/%2e%2e/%2e%2e",                         // above root
            "/a/%2f/b", "/public/..%2fsecret", "/public/%2E%2E%2Fsecret",   // encoded slash
            "/a%00b", "/a%0Ab", "/a%0Db", "/a%7Fb", "/a\nb",                // control bytes
            "/a#b",                                                          // fragment
            "/aé",                                                           // raw non-ASCII
            "/public/..;/..;/secret", "/api/v1/..;/..;/..;/admin/keys", "/..;",
            "/" + String(repeating: "a", count: 8192),                       // too long
        ]
        for t in rejected { #expect(canon(t) == nil, "\(t.prefix(40))") }
    }

    @Test("path.rs: encoded slash when the endpoint opts in")
    func encodedSlashOptIn() {
        #expect(canon("/a/%2f/b", slash: true) == "/a/%2F/b")
        #expect(canon("/a/%2F/b", slash: true) == "/a/%2F/b")
        #expect(canon("/repos/group%2fproject/issues", slash: true) == "/repos/group%2Fproject/issues")
        // The %2F sentinel must not smuggle a dot-segment past resolution.
        for t in ["/public/..%2fsecret", "/public/..%2f..%2fsecret", "/public/.%2fsecret"] {
            #expect(canon(t, slash: true) == nil, "\(t) → \(canon(t, slash: true) ?? "")")
        }
    }

    @Test("path.rs: output never contains dot-segments")
    func noDotSegments() {
        for t in ["/public/..;/secret", "/public/.;/secret", "/public/%2e%2e;/secret", "/a;jsessionid=xyz/b",
                  "/public//../secret", "/a/b/..", "/a/b/."] {
            if let p = canon(t) { #expect(!p.split(separator: "/").contains { $0 == ".." || $0 == "." }, "\(t)") }
        }
    }

    // MARK: l7/rest.rs — query parsing (`parse_target_query` tests)

    private func query(_ t: String) -> [String: [String]]? {
        try? OpenShellPolicy.canonicalize(target: t, allowEncodedSlash: false).get().query
    }

    @Test("rest.rs: query parameters")
    func queryParams() {
        #expect(query("/download?tag=a&tag=b") == ["tag": ["a", "b"]])
        #expect(query("/download?slug=my%2Fskill&name=Foo+Bar") == ["slug": ["my/skill"], "name": ["Foo Bar"]])
        #expect(query("/search?q=a%2Bb") == ["q": ["a+b"]])
        #expect(query("/api?tag=") == ["tag": [""]])
        #expect(query("/api?verbose") == ["verbose": [""]])
        #expect(query("/search?q=caf%C3%A9") == ["q": ["café"]])
        #expect(query("/api?") == [:])
        #expect(query("/download?slug=bad%2") == nil)            // malformed escape rejects the request
        #expect(query("/x?q=%C3%28") == nil)                      // not UTF-8 after decoding
    }

    // MARK: MCP rule conflicts (l7/mod.rs validation)

    @Test("MCP: a tool-less rule covering tools/call can't sit beside tool rules")
    func mcpToolConflicts() {
        func load(_ rules: String, deny: String = "", allowAll: Bool = false) -> Bool {
            (try? OpenShellPolicy.parse("""
            version: 1
            network_policies:
              m:
                endpoints:
                  - host: mcp.example.com
                    port: 443
                    protocol: mcp
                    mcp: { versions: ["2025-11-25"]\(allowAll ? ", allow_all_known_mcp_methods: true" : "") }
                    rules:
            \(rules)
            \(deny)
            """)) != nil
        }
        let tool = "          - allow: { method: tools/call, tool: search }"
        #expect(load(tool))
        #expect(!load(tool + "\n          - allow: { method: \"tools/*\" }"))
        #expect(!load(tool + "\n          - allow: { method: tools/call }"))
        #expect(load(tool + "\n          - allow: { method: tools/list }"))
        #expect(!load(tool, deny: "        deny_rules:\n          - { method: tools/call }"))
        #expect(load(tool, deny: "        deny_rules:\n          - { method: tools/call, tool: send_email }"))
    }

    // MARK: openshell-core endpoint_path.rs — endpoint `path` selectors

    private func selects(_ pattern: String, _ path: String) -> Bool {
        OpenShellPolicy.Endpoint(host: "h", ports: [443], path: pattern, allowedIPs: [], l7: .rest, tlsSkip: false,
                                 enforcement: .enforce, access: .full, rules: [], denyRules: [],
                                 allowEncodedSlash: false).selects(path: path)
    }

    @Test("endpoint_path.rs: selector semantics")
    func endpointPathSelectors() {
        #expect(selects("", "/v1/messages"))
        #expect(selects("/**", "/v1/messages"))
        #expect(selects("/v1/**", "/v1"))
        #expect(selects("/v1/**", "/v1/messages"))
        #expect(selects("/v*/messages", "/v1/messages"))
        #expect(selects("/v1/*", "/v1/chat/messages"))
        #expect(!selects("/v1/**", "/v2/messages"))
        #expect(!selects("/v1/*/messages", "/v1/chat/completions"))
        #expect(selects("/v1/**", "/v1/chat/messages"))
        #expect(!selects("/v*/messages", "/v1/completions"))
    }

    // MARK: Rego glob.match (regorus → globset)

    @Test("glob.match: globset + delimiter rewriting")
    func regoGlob() {
        let g = RegoGlob.match
        // Binaries ("/" delimiter): `/**/` matches zero or more directories.
        #expect(g("/usr/lib/**/node", ["/"], "/usr/lib/node"))
        #expect(g("/usr/lib/**/node", ["/"], "/usr/lib/a/b/node"))
        #expect(!g("/usr/lib/*/node", ["/"], "/usr/lib/a/b/node"))
        #expect(g("/usr/bin/python3*", ["/"], "/usr/bin/python3.12"))
        #expect(!g("/usr/local/bin/*", ["/"], "/usr/local/bin/a/b"))
        // Paths: a trailing `/**` needs something below the prefix.
        #expect(!g("/v1/**", ["/"], "/v1"))
        #expect(g("/v1/**", ["/"], "/v1/"))
        #expect(g("/repos/*/*", ["/"], "/repos/a/b"))
        #expect(!g("/repos/*/*", ["/"], "/repos/a/b/c"))
        // Hosts ("." delimiter): `*` is one label, `**` spans labels.
        #expect(g("*.example.com", ["."], "api.example.com"))
        #expect(!g("*.example.com", ["."], "a.b.example.com"))
        #expect(g("**.example.com", ["."], "a.b.example.com"))
        #expect(!g("**.example.com", ["."], "example.com"))
        #expect(g("api-*.example.org", ["."], "api-.example.org"))
        // `[]` means ["."]: a `/` in the value is an ordinary byte, `.` is not.
        #expect(g("tools/*", [], "tools/call"))
        #expect(g("list_*", [], "list_issues"))
        #expect(!g("send*", [], "send.email"))
        #expect(g("{get,list}_*", [], "get_repo"))
        #expect(g("[a-c]x", [], "bx"))
        #expect(!g("[!a-c]x", [], "bx"))
        #expect(!g("[", [], "["))                                   // invalid glob: no match
    }

    // MARK: l7/mcp.rs + l7/jsonrpc.rs — MCP transport

    private static let mcp26Policy = """
    version: 1
    network_policies:
      m:
        endpoints:
          - host: mcp.example.com
            port: 443
            protocol: mcp
            enforcement: enforce
            mcp: { versions: ["2025-11-25", "2026-07-28"] }
            rules:
              - allow: { method: initialize }
              - allow: { method: tools/list }
              - allow: { method: prompts/get }
              - allow: { method: tools/call, tool: get_weather }
    """

    private func mcp(_ p: OpenShellPolicy, _ body: String, _ headers: [String: String], method: String = "POST")
        -> OpenShellPolicy.RequestDecision {
        p.evaluateRequest(host: "mcp.example.com", port: 443, method: method, target: "/mcp",
                          headers: headers, body: body.isEmpty ? nil : Data(body.utf8))
    }

    private static let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#

    @Test("mcp.rs: sessionless revision needs matching Mcp-Method / Mcp-Name mirrors")
    func sessionlessMirrors() throws {
        let p = try OpenShellPolicy.parse(Self.mcp26Policy)
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_weather",\#(Self.meta)}}"#
        let good = ["mcp-protocol-version": "2026-07-28", "mcp-method": "tools/call", "mcp-name": "get_weather"]
        #expect(mcp(p, body, good) == .allow)
        #expect(mcp(p, body, good.merging(["mcp-method": "tools/list"]) { _, b in b }) != .allow)
        #expect(mcp(p, body, good.filter { $0.key != "mcp-method" }) != .allow)
        #expect(mcp(p, body, good.filter { $0.key != "mcp-name" }) != .allow)
        #expect(mcp(p, body, good.merging(["mcp-name": "other"]) { _, b in b }) != .allow)
        // Names may be base64-encoded; they are decoded before comparison.
        let b64 = "=?base64?" + Data("get_weather".utf8).base64EncodedString() + "?="
        #expect(mcp(p, body, good.merging(["mcp-name": b64]) { _, b in b }) == .allow)
        #expect(mcp(p, body, good.merging(["mcp-name": "=?base64?***?="]) { _, b in b }) != .allow)
        // Sessionless messages require POST.
        #expect(mcp(p, "", ["mcp-protocol-version": "2026-07-28", "accept": "text/event-stream"], method: "GET") != .allow)
    }

    @Test("jsonrpc.rs: sessionless bodies carry _meta and are never batched")
    func sessionlessBodies() throws {
        let p = try OpenShellPolicy.parse(Self.mcp26Policy)
        let h = ["mcp-protocol-version": "2026-07-28", "mcp-method": "tools/list"]
        #expect(mcp(p, #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{\#(Self.meta)}}"#, h) == .allow)
        #expect(mcp(p, #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#, h) != .allow)
        #expect(mcp(p, #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#, h) != .allow)
        #expect(mcp(p, #"[{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{\#(Self.meta)}}]"#, h) != .allow)
        // Legacy lifecycle methods don't exist in the sessionless revision.
        #expect(mcp(p, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2026-07-28","capabilities":{},"clientInfo":{"name":"t","version":"1"},\#(Self.meta)}}"#,
                    ["mcp-protocol-version": "2026-07-28", "mcp-method": "initialize"]) != .allow)
        // A body declaring 2026-07-28 can't be reinterpreted under a legacy header.
        #expect(mcp(p, #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{\#(Self.meta)}}"#,
                    ["mcp-protocol-version": "2025-11-25"]) != .allow)
    }

    @Test("mcp.rs: revision selection")
    func revisionSelection() throws {
        let p = try OpenShellPolicy.parse(Self.mcp26Policy)
        let list = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        #expect(mcp(p, list, ["mcp-protocol-version": "2025-11-25"]) == .allow)
        #expect(mcp(p, list, [:]) != .allow)                                   // absent = 2025-03-26, not allowed
        #expect(mcp(p, list, ["mcp-protocol-version": "2099-01-01"]) != .allow)  // unsupported
        #expect(mcp(p, list, ["mcp-protocol-version": ""]) != .allow)
        // A standalone legacy initialize negotiates in its body.
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
        #expect(mcp(p, initialize, [:]) == .allow)
        // …unless the endpoint allows only the sessionless revision.
        let modern = try OpenShellPolicy.parse(Self.mcp26Policy.replacingOccurrences(
            of: #"["2025-11-25", "2026-07-28"]"#, with: #"["2026-07-28"]"#))
        #expect(mcp(modern, initialize, [:]) != .allow)
    }

    @Test("tower-mcp: per-revision method availability, batches, typed params")
    func methodTable() throws {
        let p = try OpenShellPolicy.parse(Self.mcp26Policy.replacingOccurrences(
            of: #"["2025-11-25", "2026-07-28"]"#, with: #"["2025-03-26", "2025-11-25"]"#))
        let v0325 = ["mcp-protocol-version": "2025-03-26"], v1125 = ["mcp-protocol-version": "2025-11-25"]
        let batch = #"[{"jsonrpc":"2.0","id":1,"method":"tools/list"},{"jsonrpc":"2.0","id":2,"method":"tools/list"}]"#
        #expect(mcp(p, batch, v0325) == .allow)          // only 2025-03-26 permits batches
        #expect(mcp(p, batch, v1125) != .allow)
        // tools/call requires params.name.
        #expect(mcp(p, #"{"jsonrpc":"2.0","id":1,"method":"tools/call"}"#, v1125) != .allow)
        // server/discover exists only in 2026-07-28.
        #expect(mcp(p, #"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{}}"#, v1125) != .allow)
        // Request ids are strings or integers.
        #expect(mcp(p, #"{"jsonrpc":"2.0","id":1.5,"method":"tools/list"}"#, v1125) != .allow)
        // A client response to a server request is not a call; it passes.
        #expect(mcp(p, #"{"jsonrpc":"2.0","id":9,"result":{}}"#, v1125) == .allow)
        // Batches can't mix calls and responses.
        #expect(mcp(p, #"[{"jsonrpc":"2.0","id":1,"method":"tools/list"},{"jsonrpc":"2.0","id":2,"result":{}}]"#, v0325) != .allow)
    }
}

/// l7/relay.rs `request_authority_matches_endpoint` and l7/rest.rs authority
/// parsing: the request must name the tunnel's endpoint.
@Suite("OpenShell request authority")
struct OpenShellAuthorityTests {
    private func head(_ raw: String) throws -> OpenShellHTTP.RequestHead {
        try OpenShellHTTP.parseHead(Data(raw.utf8))
    }

    @Test("Host header must name the tunnel endpoint, port included")
    func authority() throws {
        let m = OpenShellHTTP.authorityMatchesEndpoint
        #expect(m(try head("GET / HTTP/1.1\r\nHost: api.example.com\r\n\r\n"), "api.example.com", 443, 443))
        #expect(m(try head("GET / HTTP/1.1\r\nHost: API.Example.com.\r\n\r\n"), "api.example.com", 443, 443))
        #expect(m(try head("GET / HTTP/1.1\r\nHost: api.example.com:443\r\n\r\n"), "api.example.com", 443, 443))
        #expect(!m(try head("GET / HTTP/1.1\r\nHost: evil.example.com\r\n\r\n"), "api.example.com", 443, 443))
        #expect(!m(try head("GET / HTTP/1.1\r\nHost: api.example.com:8443\r\n\r\n"), "api.example.com", 443, 443))
        #expect(m(try head("GET / HTTP/1.1\r\nHost: user@api.example.com\r\n\r\n"), "api.example.com", 443, 443))
        #expect(m(try head("GET / HTTP/1.1\r\nHost: [::1]:8080\r\n\r\n"), "::1", 8080, 80))
        // Absolute-form: its own scheme's default port.
        #expect(m(try head("GET http://api.example.com/x HTTP/1.1\r\nHost: api.example.com\r\n\r\n"), "api.example.com", 80, 443))
        // HTTP/1.0 without Host passes.
        #expect(m(try head("GET / HTTP/1.0\r\n\r\n"), "api.example.com", 443, 443))
    }

    @Test("Invalid Host authorities are refused")
    func invalidHost() {
        for h in ["", "a b", "h:99999", "h:port", "[::1", "h/x"] {
            #expect(throws: OpenShellHTTP.Rejection.self) { try head("GET / HTTP/1.1\r\nHost: \(h)\r\n\r\n") }
        }
    }

    @Test("Inspected routes forward the canonical request-target, raw query kept")
    func canonicalTarget() throws {
        let p = try OpenShellPolicy.parse("""
        version: 1
        network_policies:
          a:
            endpoints:
              - { host: api.example.com, port: 443, protocol: rest, access: full }
              - { host: raw.example.com, port: 443 }
        """)
        #expect(p.canonicalRequestTarget(host: "api.example.com", port: 443, target: "/public/..;/secret?x=%41+b") == "/secret?x=%41+b")
        #expect(p.canonicalRequestTarget(host: "api.example.com", port: 443, target: "/a") == "/a")
        #expect(p.canonicalRequestTarget(host: "raw.example.com", port: 443, target: "/public/../x") == nil)
    }
}

/// identity.rs `verify_or_cache_supplied_identity` tests, ported.
@Suite("OpenShell binary identity pinning")
struct OpenShellBinaryPinTests {
    typealias Store = OpenShellPolicy.BinaryPinStore

    @Test("Reuses a pin; refuses a replaced leaf or ancestor")
    func replacement() {
        var s = Store()
        #expect(s.verifyOrPin([("/sandbox/tool", "11")]) == nil)
        #expect(s.verifyOrPin([("/sandbox/tool", "11")]) == nil)
        #expect(s.verifyOrPin([("/sandbox/tool", "22")])?.contains("integrity violation") == true)
        var a = Store()
        #expect(a.verifyOrPin([("/sandbox/tool", "11"), ("/sandbox/launcher", "22")]) == nil)
        #expect(a.verifyOrPin([("/sandbox/tool", "11"), ("/sandbox/launcher", "33")])?.contains("/sandbox/launcher") == true)
    }

    @Test("Missing evidence and relative or empty paths are refused")
    func evidence() {
        var s = Store()
        #expect(s.verifyOrPin([("/sandbox/tool", nil)])?.contains("missing digest") == true)
        #expect(s.verifyOrPin([("/sandbox/tool", "11"), ("/sandbox/launcher", nil)])?.contains("missing digest") == true)
        #expect(s.verifyOrPin([("tool", "11")])?.contains("must be absolute") == true)
        #expect(s.verifyOrPin([("", "11")])?.contains("must be absolute") == true)
    }

    @Test("Duplicates dedupe; conflicts and capacity refusals pin nothing")
    func atomic() {
        var s = Store()
        #expect(s.verifyOrPin([("/a", "11"), ("/a", "11")]) == nil)
        #expect(s.pins == ["/a": "11"])
        var c = Store()
        #expect(c.verifyOrPin([("/new", "11"), ("/new", "22")])?.contains("conflicting evidence") == true)
        #expect(c.pins.isEmpty)
        var e = Store()
        _ = e.verifyOrPin([("/pinned", "11")])
        #expect(e.verifyOrPin([("/fresh", "22"), ("/pinned", "33")]) != nil)
        #expect(e.pins["/fresh"] == nil)
        var full = Store()
        for i in 0..<(Store.capacity - 1) { _ = full.verifyOrPin([("/b\(i)", "1")]) }
        #expect(full.verifyOrPin([("/x", "1"), ("/y", "1")])?.contains("capacity") == true)
        #expect(full.pins.count == Store.capacity - 1)
        #expect(full.verifyOrPin([("/x", "1")]) == nil)
    }
}
