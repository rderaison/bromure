import Foundation
import Testing
@testable import bromure_ac

// MARK: - ProfileSecrets MCP Extraction

@Suite("MCP ProfileSecrets Extraction")
struct MCPSecretsTests {

    private func makeProfile(bearerToken: String = "", oauthState: MCPOAuthState? = nil) -> Profile {
        var p = Profile(name: "Test", tool: .claude, authMode: .token)
        p.mcpServers = [
            MCPServer(
                name: "fellow",
                transport: .http,
                url: "https://fellow.app/mcp",
                bearerTokenEnvVar: "MCP_OAUTH_FELLOW",
                bearerToken: bearerToken,
                oauthState: oauthState
            )
        ]
        return p
    }

    private func sampleOAuth() -> MCPOAuthState {
        MCPOAuthState(
            clientID: "test-client",
            clientSecret: "test-secret",
            authorizationEndpoint: "https://fellow.app/mcp/authorize",
            tokenEndpoint: "https://fellow.app/mcp/token",
            accessToken: "real-access-token-12345",
            refreshToken: "real-refresh-token-67890",
            expiresAt: Date().addingTimeInterval(86400)
        )
    }

    @Test("Bearer token stripped from profile during extraction")
    func bearerTokenStripped() {
        var profile = makeProfile(bearerToken: "secret-token")
        let secrets = ProfileSecrets.extract(stripping: &profile)
        #expect(profile.mcpServers[0].bearerToken.isEmpty)
        #expect(secrets.mcpBearerTokens?[profile.mcpServers[0].id.uuidString] == "secret-token")
    }

    @Test("OAuth state stripped from profile during extraction")
    func oauthStateStripped() {
        let oauth = sampleOAuth()
        var profile = makeProfile(bearerToken: oauth.accessToken, oauthState: oauth)
        let secrets = ProfileSecrets.extract(stripping: &profile)
        #expect(profile.mcpServers[0].oauthState == nil)
        #expect(profile.mcpServers[0].bearerToken.isEmpty)
        let restored = secrets.mcpOAuthStates?[profile.mcpServers[0].id.uuidString]
        #expect(restored?.accessToken == "real-access-token-12345")
        #expect(restored?.refreshToken == "real-refresh-token-67890")
        #expect(restored?.clientID == "test-client")
    }

    @Test("Secrets apply restores bearer token and OAuth state")
    func applyRestores() {
        let oauth = sampleOAuth()
        var profile = makeProfile(bearerToken: oauth.accessToken, oauthState: oauth)
        let secrets = ProfileSecrets.extract(stripping: &profile)
        #expect(profile.mcpServers[0].bearerToken.isEmpty)
        #expect(profile.mcpServers[0].oauthState == nil)
        secrets.apply(to: &profile)
        #expect(profile.mcpServers[0].bearerToken == "real-access-token-12345")
        #expect(profile.mcpServers[0].oauthState?.clientID == "test-client")
        #expect(profile.mcpServers[0].oauthState?.refreshToken == "real-refresh-token-67890")
    }

    @Test("Empty MCP secrets don't affect isEmpty")
    func emptySecrets() {
        var profile = makeProfile()
        let secrets = ProfileSecrets.extract(stripping: &profile)
        #expect(secrets.mcpBearerTokens == nil)
        #expect(secrets.mcpOAuthStates == nil)
    }

    @Test("Multiple MCP servers extracted independently")
    func multipleServers() {
        var profile = Profile(name: "Multi", tool: .claude, authMode: .token)
        profile.mcpServers = [
            MCPServer(name: "server-a", transport: .http, url: "https://a.example.com",
                      bearerToken: "token-a"),
            MCPServer(name: "server-b", transport: .http, url: "https://b.example.com",
                      bearerToken: "token-b", oauthState: sampleOAuth()),
            MCPServer(name: "server-c", transport: .stdio, command: "npx"),
        ]
        let idA = profile.mcpServers[0].id.uuidString
        let idB = profile.mcpServers[1].id.uuidString
        let secrets = ProfileSecrets.extract(stripping: &profile)
        #expect(secrets.mcpBearerTokens?[idA] == "token-a")
        #expect(secrets.mcpBearerTokens?[idB] == "token-b")
        #expect(secrets.mcpOAuthStates?[idB] != nil)
        #expect(profile.mcpServers.allSatisfy { $0.bearerToken.isEmpty })
        #expect(profile.mcpServers.allSatisfy { $0.oauthState == nil })
    }
}

// MARK: - Refreshed OAuth state persisted

/// A launch refreshed an expiring MCP access token into its own copy only:
/// the stored refresh token was then spent on a server that rotates them,
/// and the next launch's refresh failed (invalid_grant).
@Suite("MCP refreshed OAuth state is saved", .serialized)
struct MCPOAuthRefreshPersistTests {
    static func oauth(_ access: String, _ refresh: String, client: String = "c1") -> MCPOAuthState {
        MCPOAuthState(clientID: client, authorizationEndpoint: "https://mcp.example/authorize",
                      tokenEndpoint: "https://mcp.example/token", accessToken: access,
                      refreshToken: refresh, expiresAt: Date().addingTimeInterval(3600))
    }

    static func workspace() -> Profile {
        var p = Profile(name: "w", tool: .claude, authMode: .token)
        p.mcpServers = [
            MCPServer(name: "a", transport: .http, url: "https://a.example/mcp", oauthState: oauth("a-at1", "a-rt1")),
            MCPServer(name: "b", transport: .http, url: "https://b.example/mcp", oauthState: oauth("b-at1", "b-rt1")),
        ]
        return p
    }

    @Test("only the refreshed server's state is written; edits saved since stay")
    func persistsOnlyThatServer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-oauth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let p = Self.workspace()
        try store.save(p)
        let launchCopy = p   // what the launch refreshed from

        // Saved meanwhile (editor / other process): a field, and server b re-authorized.
        var edited = p
        edited.comments = "notes saved meanwhile"
        edited.mcpServers[1].oauthState = Self.oauth("b-at2", "b-rt2")
        try store.update(edited)

        let old = try #require(launchCopy.mcpServers[0].oauthState)
        var refreshed = old
        refreshed.accessToken = "a-at2"
        refreshed.refreshToken = "a-rt2"
        #expect(try store.persistRefreshedMCPOAuth(refreshed, from: old,
                                                   serverID: p.mcpServers[0].id, profileID: p.id))

        let loaded = try #require(store.loadAll().first { $0.id == p.id })
        #expect(loaded.mcpServers[0].oauthState?.refreshToken == "a-rt2")
        #expect(loaded.mcpServers[0].oauthState?.accessToken == "a-at2")
        #expect(loaded.mcpServers[1].oauthState?.refreshToken == "b-rt2")
        #expect(loaded.comments == "notes saved meanwhile")
        // On disk it's in the encrypted secrets, not profile.json.
        let json = try String(contentsOf: store.profileDirectory(for: p).appendingPathComponent("profile.json"), encoding: .utf8)
        #expect(!json.contains("a-rt2"))
    }

    @Test("a re-authorization saved meanwhile wins over the refresh")
    func reauthorizationWins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-oauth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let p = Self.workspace()
        try store.save(p)
        let old = try #require(p.mcpServers[0].oauthState)

        var reauth = p
        reauth.mcpServers[0].oauthState = Self.oauth("a-fresh", "a-fresh-rt", client: "c2")
        try store.update(reauth)

        var refreshed = old
        refreshed.accessToken = "a-at2"
        refreshed.refreshToken = "a-rt2"
        #expect(try !store.persistRefreshedMCPOAuth(refreshed, from: old,
                                                    serverID: p.mcpServers[0].id, profileID: p.id))
        let loaded = try #require(store.loadAll().first { $0.id == p.id })
        #expect(loaded.mcpServers[0].oauthState?.refreshToken == "a-fresh-rt")
        // An unknown server or workspace writes nothing.
        #expect(try !store.persistRefreshedMCPOAuth(refreshed, from: old, serverID: UUID(), profileID: p.id))
        #expect(try !store.persistRefreshedMCPOAuth(refreshed, from: old,
                                                    serverID: p.mcpServers[0].id, profileID: UUID()))
    }

    @Test("the in-memory merge touches only a copy still on the old state")
    func mergeHelper() {
        var p = Self.workspace()
        let old = p.mcpServers[0].oauthState!
        var refreshed = old
        refreshed.refreshToken = "a-rt2"
        #expect(ProfileStore.mergeRefreshedMCPOAuth(refreshed, from: old, serverID: p.mcpServers[0].id, into: &p))
        #expect(p.mcpServers[0].oauthState?.refreshToken == "a-rt2")
        #expect(p.mcpServers[1].oauthState?.refreshToken == "b-rt1")
        // Applied twice: already current, no change.
        #expect(!ProfileStore.mergeRefreshedMCPOAuth(refreshed, from: old, serverID: p.mcpServers[0].id, into: &p))
    }

    @Test("the refresh box: a result delivered before the waiter collects is the waiter's")
    func boxDeliveredInTime() {
        let box = MCPRefreshBox()
        let r = Self.oauth("at2", "rt2")
        #expect(!box.deliver(r))             // not late: the waiter uses it (and saves it)
        #expect(box.collect() == r)
    }

    @Test("the refresh box: a result after the waiter gave up is late, kept by the task")
    func boxDeliveredLate() {
        let box = MCPRefreshBox()
        #expect(box.collect() == nil)        // the 10 s wait timed out: stale token this boot
        #expect(box.deliver(Self.oauth("at2", "rt2")))   // late: the task saves it itself
        #expect(box.collect() == nil)        // never handed to the waiter afterwards
    }

    @Test("the refresh box: a failed refresh hands over nothing")
    func boxFailed() {
        let box = MCPRefreshBox()
        #expect(!box.deliver(nil))
        #expect(box.collect() == nil)
    }

    @Test("an open editor's save keeps an OAuth state the launch refreshed, unless the editor changed it")
    func editorKeepsRefreshed() {
        let opened = Self.workspace()
        var current = opened                 // the app's copy after keepRefreshedMCPOAuth
        current.mcpServers[0].oauthState = Self.oauth("a-at2", "a-rt2")

        var draft = opened
        draft.memoryGB = 8
        draft.adoptAppEdits(from: current, opened: opened)
        #expect(draft.mcpServers[0].oauthState?.refreshToken == "a-rt2")
        #expect(draft.mcpServers[1].oauthState?.refreshToken == "b-rt1")
        #expect(draft.memoryGB == 8)

        var reauth = opened                  // Authorize in the editor
        reauth.mcpServers[0].oauthState = Self.oauth("a-mine", "a-mine-rt", client: "c9")
        reauth.adoptAppEdits(from: current, opened: opened)
        #expect(reauth.mcpServers[0].oauthState?.refreshToken == "a-mine-rt")

        var signedOut = opened               // Sign out in the editor
        signedOut.mcpServers[0].oauthState = nil
        signedOut.adoptAppEdits(from: current, opened: opened)
        #expect(signedOut.mcpServers[0].oauthState == nil)

        var added = opened                   // a server added in the editor: untouched
        added.mcpServers.append(MCPServer(name: "c", transport: .http, url: "https://c.example/mcp",
                                          oauthState: Self.oauth("c-at", "c-rt")))
        added.adoptAppEdits(from: current, opened: opened)
        #expect(added.mcpServers[2].oauthState?.refreshToken == "c-rt")
    }
}

// MARK: - Config Generation

@Suite("MCP Config Generation")
struct MCPConfigTests {

    @Test("OAuth server emits no auth fields in Claude Code config")
    func oauthServerNoAuthFields() {
        let server = MCPServer(
            name: "fellow",
            transport: .http,
            url: "https://fellow.app/mcp",
            bearerTokenEnvVar: "MCP_OAUTH_FELLOW",
            bearerToken: "real-token",
            oauthState: MCPOAuthState(
                clientID: "c", authorizationEndpoint: "https://a",
                tokenEndpoint: "https://t", accessToken: "real-token")
        )
        let fakes = ["fellow": (envVar: "MCP_OAUTH_FELLOW", fake: "brm-mcp_fake123")]
        let json = SessionDisk.claudeCodeMCPConfig(servers: [server], fakes: fakes)
        #expect(!json.contains("bearerTokenEnvVar"))
        #expect(!json.contains("brm-mcp_fake123"))
        #expect(json.contains("fellow.app"))
    }

    @Test("Static bearer token emits bearerTokenEnvVar and fake in env")
    func staticBearerToken() {
        let server = MCPServer(
            name: "my-api",
            transport: .http,
            url: "https://api.example.com/mcp",
            bearerTokenEnvVar: "MY_API_TOKEN",
            bearerToken: "real-static-token"
        )
        let fakes = ["my-api": (envVar: "MY_API_TOKEN", fake: "brm-mcp_staticfake")]
        let json = SessionDisk.claudeCodeMCPConfig(servers: [server], fakes: fakes)
        #expect(json.contains("bearerTokenEnvVar"))
        #expect(json.contains("MY_API_TOKEN"))
        #expect(json.contains("brm-mcp_staticfake"))
        #expect(!json.contains("real-static-token"))
    }

    @Test("Claude Code JSON generates valid multi-server config")
    func claudeCodeJsonMultiServer() {
        let httpServer = MCPServer(
            name: "My API",
            transport: .http,
            url: "https://api.example.com/mcp",
            environment: [
                EnvironmentVariable(name: "REGION", value: "us-east-1")
            ],
            bearerTokenEnvVar: "MY_API_TOKEN"
        )
        let stdioServer = MCPServer(
            name: "memory",
            transport: .stdio,
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-memory"]
        )
        let fakes = ["My API": (envVar: "MY_API_TOKEN", fake: "brm-mcp_fake123")]
        let json = SessionDisk.claudeCodeMCPConfig(
            servers: [httpServer, stdioServer], fakes: fakes)
        let data = json.data(using: .utf8)!
        let root = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let servers = root["mcpServers"] as! [String: Any]

        // HTTP server
        let api = servers["My API"] as! [String: Any]
        #expect(api["type"] as? String == "http")
        #expect(api["url"] as? String == "https://api.example.com/mcp")
        #expect(api["bearerTokenEnvVar"] as? String == "MY_API_TOKEN")
        let apiEnv = api["env"] as! [String: String]
        #expect(apiEnv["MY_API_TOKEN"] == "brm-mcp_fake123")
        #expect(apiEnv["REGION"] == "us-east-1")

        // STDIO server
        let mem = servers["memory"] as! [String: Any]
        #expect(mem["command"] as? String == "npx")
        #expect(mem["args"] as? [String] == ["-y", "@modelcontextprotocol/server-memory"])
        #expect(mem["type"] == nil)
        #expect(mem["url"] == nil)
    }

    @Test("Disabled server excluded from config")
    func disabledServerExcluded() {
        let server = MCPServer(
            name: "disabled-one",
            transport: .http,
            url: "https://example.com/mcp",
            enabled: false
        )
        let json = SessionDisk.claudeCodeMCPConfig(servers: [server].filter(\.enabled), fakes: [:])
        #expect(!json.contains("disabled-one"))
    }

    @Test("STDIO server emits command and args")
    func stdioServer() {
        let server = MCPServer(
            name: "local-tool",
            transport: .stdio,
            command: "npx",
            arguments: ["-y", "@example/mcp-server"]
        )
        let json = SessionDisk.claudeCodeMCPConfig(servers: [server], fakes: [:])
        #expect(json.contains("npx"))
        #expect(json.contains("@example\\/mcp-server") || json.contains("@example/mcp-server"))
        #expect(!json.contains("\"type\""))
    }

    @Test("Raw JSON server passes through when no fake token")
    func rawJSONPassthrough() {
        let server = MCPServer(
            name: "custom",
            transport: .http,
            url: "https://example.com",
            rawJSON: "{\"type\":\"http\",\"url\":\"https://example.com\",\"custom_field\":true}"
        )
        let json = SessionDisk.claudeCodeMCPConfig(servers: [server], fakes: [:])
        #expect(json.contains("custom_field"))
    }

    @Test("Raw JSON bypassed when fake token available")
    func rawJSONBypassedWithFake() {
        let server = MCPServer(
            name: "custom",
            transport: .http,
            url: "https://example.com",
            bearerTokenEnvVar: "TOKEN",
            rawJSON: "{\"type\":\"http\",\"url\":\"https://example.com\"}"
        )
        let fakes = ["custom": (envVar: "TOKEN", fake: "brm-mcp_fake")]
        let json = SessionDisk.claudeCodeMCPConfig(servers: [server], fakes: fakes)
        #expect(json.contains("bearerTokenEnvVar"))
        #expect(json.contains("brm-mcp_fake"))
    }

    @Test("Codex TOML emits correct format for HTTP server")
    func codexTomlHTTP() {
        let server = MCPServer(
            name: "my-server",
            transport: .http,
            url: "https://api.example.com/mcp",
            bearerTokenEnvVar: "MY_TOKEN",
            bearerToken: "real"
        )
        let fakes = ["my-server": (envVar: "MY_TOKEN", fake: "brm-mcp_fake")]
        let toml = SessionDisk.codexMCPConfig(servers: [server], fakes: fakes)
        #expect(toml.contains("[mcp_servers.\"my-server\"]") || toml.contains("[mcp_servers.my-server]"))
        #expect(toml.contains("url = "))
        #expect(toml.contains("bearer_token_env_var"))
    }

    @Test("Codex TOML omits bearer_token_env_var for OAuth-brokered servers")
    func codexTomlOAuthNoBearerEnvVar() {
        var server = MCPServer(
            name: "fellow",
            transport: .http,
            url: "https://fellow.app/mcp",
            bearerTokenEnvVar: "MCP_OAUTH_FELLOW"
        )
        server.oauthState = MCPOAuthState(
            clientID: "test-client",
            authorizationEndpoint: "https://fellow.app/oauth/authorize",
            tokenEndpoint: "https://fellow.app/oauth/token",
            accessToken: "at_live"
        )
        let toml = SessionDisk.codexMCPConfig(servers: [server], fakes: [:])
        #expect(toml.contains("url = "))
        #expect(!toml.contains("bearer_token_env_var"))
    }

    @Test("Codex TOML generates valid multi-server config")
    func codexTomlMultiServer() {
        let httpServer = MCPServer(
            name: "My API",
            transport: .http,
            url: "https://api.example.com/mcp",
            environment: [
                EnvironmentVariable(name: "REGION", value: "us-east-1")
            ],
            bearerTokenEnvVar: "MY_API_TOKEN"
        )
        let stdioServer = MCPServer(
            name: "memory",
            transport: .stdio,
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-memory"]
        )
        let fakes = ["My API": (envVar: "MY_API_TOKEN", fake: "brm-mcp_fake123")]
        let toml = SessionDisk.codexMCPConfig(
            servers: [httpServer, stdioServer], fakes: fakes)

        // HTTP server section
        #expect(toml.contains("[mcp_servers.my-api]"))
        #expect(toml.contains("url = \"https://api.example.com/mcp\""))
        #expect(toml.contains("bearer_token_env_var = \"MY_API_TOKEN\""))
        #expect(toml.contains("REGION = \"us-east-1\""))
        #expect(toml.contains("MY_API_TOKEN = \"brm-mcp_fake123\""))

        // STDIO server section
        #expect(toml.contains("[mcp_servers.memory]"))
        #expect(toml.contains("command = \"npx\""))
        #expect(toml.contains("args = [\"-y\", \"@modelcontextprotocol/server-memory\"]"))

        // Structure: comment header, no trailing garbage
        #expect(toml.hasPrefix("# Generated by Bromure AC"))
        #expect(toml.hasSuffix("\n"))
    }

    @Test("Codex TOML skips raw JSON servers")
    func codexTomlSkipsRawJSON() {
        let server = MCPServer(
            name: "raw-only",
            transport: .http,
            url: "https://example.com",
            rawJSON: "{\"type\":\"http\"}"
        )
        let toml = SessionDisk.codexMCPConfig(servers: [server], fakes: [:])
        #expect(!toml.contains("raw-only"))
    }
}

// MARK: - MCPServer / MCPOAuthState Codable

@Suite("MCP Codable Compatibility")
struct MCPCodableTests {

    @Test("MCPServer roundtrips through JSON")
    func serverRoundtrip() throws {
        let server = MCPServer(
            name: "test-server",
            transport: .http,
            url: "https://example.com/mcp",
            bearerTokenEnvVar: "TOKEN",
            bearerToken: "secret",
            oauthState: MCPOAuthState(
                clientID: "cid",
                clientSecret: "csec",
                authorizationEndpoint: "https://auth",
                tokenEndpoint: "https://token",
                registrationEndpoint: "https://reg",
                accessToken: "at",
                refreshToken: "rt",
                expiresAt: Date(timeIntervalSince1970: 1700000000)
            )
        )
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(MCPServer.self, from: data)
        #expect(decoded.name == "test-server")
        #expect(decoded.transport == .http)
        #expect(decoded.bearerToken == "secret")
        #expect(decoded.oauthState?.clientID == "cid")
        #expect(decoded.oauthState?.refreshToken == "rt")
        #expect(decoded.oauthState?.expiresAt?.timeIntervalSince1970 == 1700000000)
    }

    @Test("MCPServer without oauthState decodes cleanly")
    func serverWithoutOAuth() throws {
        let json = """
        {"id":"A0000000-0000-0000-0000-000000000001",
         "name":"legacy","transport":"http","command":"",
         "arguments":[],"url":"https://example.com",
         "environment":[],"bearerTokenEnvVar":"","bearerToken":"tok",
         "enabled":true,"rawJSON":""}
        """
        let decoded = try JSONDecoder().decode(MCPServer.self, from: Data(json.utf8))
        #expect(decoded.oauthState == nil)
        #expect(decoded.bearerToken == "tok")
    }

    @Test("Profile with MCP servers roundtrips through JSON")
    func profileWithMCPRoundtrip() throws {
        var profile = Profile(name: "MCP Test", tool: .claude, authMode: .token)
        profile.mcpServers = [
            MCPServer(name: "s1", transport: .http, url: "https://a.com",
                      bearerToken: "t1"),
            MCPServer(name: "s2", transport: .stdio, command: "npx",
                      arguments: ["-y", "pkg"]),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(profile)
        let decoded = try decoder.decode(Profile.self, from: data)
        #expect(decoded.mcpServers.count == 2)
        #expect(decoded.mcpServers[0].name == "s1")
        #expect(decoded.mcpServers[0].bearerToken == "t1")
        #expect(decoded.mcpServers[1].command == "npx")
    }
}

// MARK: - Discovery Path Matching

@Suite("OAuth Discovery Path Blocking")
struct DiscoveryPathTests {

    private func isDiscoveryPath(_ path: String) -> Bool {
        path.hasPrefix("/.well-known/oauth-authorization-server")
            || path.hasPrefix("/.well-known/oauth-protected-resource")
            || path.hasPrefix("/.well-known/openid-configuration")
    }

    @Test("Blocks oauth-authorization-server")
    func blocksAuthServer() {
        #expect(isDiscoveryPath("/.well-known/oauth-authorization-server"))
        #expect(isDiscoveryPath("/.well-known/oauth-authorization-server/mcp"))
    }

    @Test("Blocks oauth-protected-resource")
    func blocksProtectedResource() {
        #expect(isDiscoveryPath("/.well-known/oauth-protected-resource"))
        #expect(isDiscoveryPath("/.well-known/oauth-protected-resource/mcp"))
    }

    @Test("Blocks openid-configuration")
    func blocksOpenID() {
        #expect(isDiscoveryPath("/.well-known/openid-configuration"))
        #expect(isDiscoveryPath("/.well-known/openid-configuration/mcp"))
    }

    @Test("Does not block other .well-known paths")
    func allowsOtherWellKnown() {
        #expect(!isDiscoveryPath("/.well-known/acme-challenge"))
        #expect(!isDiscoveryPath("/.well-known/security.txt"))
        #expect(!isDiscoveryPath("/.well-known/apple-app-site-association"))
    }

    @Test("Does not block regular paths")
    func allowsRegularPaths() {
        #expect(!isDiscoveryPath("/mcp"))
        #expect(!isDiscoveryPath("/api/v1/token"))
        #expect(!isDiscoveryPath("/oauth/authorize"))
    }
}
