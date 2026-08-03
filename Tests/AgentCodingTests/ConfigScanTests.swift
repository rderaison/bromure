import Foundation
import Testing
@testable import bromure_ac

// The onboarding scan. Each detector is exercised against the real file shape
// it claims to read — a detector that silently matches nothing is worse than
// no detector, because the wizard then tells the user they have no credentials.
@Suite("Config scan")
struct ConfigScanTests {

    @Test("gitconfig: identity and an embedded token")
    func gitconfig() throws {
        let r = try GitConfigParse.parse("""
        [user]
            name = Ada Lovelace
            email = ada@example.com
        [url "https://ghp_abc@github.com/"]
            insteadOf = https://github.com/
        """)
        #expect(r.identity.name == "Ada Lovelace")
        #expect(r.identity.email == "ada@example.com")
        #expect(r.creds.first?.token == "ghp_abc")
        #expect(r.creds.first?.host == "github.com")
    }

    @Test("classic github basic-auth puts the token in the USER half")
    func classicGitHub() throws {
        // Reading this the obvious way imports the dummy password and loses the
        // real token.
        let c = try #require(GitConfigParse.credential(
            fromURL: "https://ghp_real:x-oauth-basic@github.com/"))
        #expect(c.token == "ghp_real")
        #expect(c.username == "x-access-token")
    }

    @Test("percent-encoded userinfo is decoded")
    func percentEncoded() throws {
        let c = try #require(GitConfigParse.credential(
            fromURL: "https://me%40corp.com:tok%2Fslash@git.example.com/"))
        #expect(c.username == "me@corp.com")
        #expect(c.token == "tok/slash")
    }

    @Test("a URL with no userinfo yields nothing to swap")
    func noUserinfo() {
        #expect(GitConfigParse.credential(fromURL: "https://github.com/acme/repo") == nil)
    }

    @Test("netrc: machine/login/password across lines")
    func netrc() {
        let creds = ConfigScan.parseNetrc("""
        machine github.com
          login ada
          password ghp_fromnetrc
        machine gitlab.com login bob password glpat-xyz
        default login anon password nope
        """)
        #expect(creds.count == 2)
        #expect(creds.first { $0.host == "github.com" }?.token == "ghp_fromnetrc")
        #expect(creds.first { $0.host == "gitlab.com" }?.username == "bob")
        // `default` has no host to scope a swap to, so it must not be imported.
        #expect(!creds.contains { $0.host == "default" })
    }

    @Test("INI: aws credentials, including [profile x] headers")
    func ini() {
        let s = INI.parse("""
        [default]
        aws_access_key_id = AKIAEXAMPLE
        aws_secret_access_key = secret/value+here
        ; a comment
        [profile work]
        region = eu-west-1
        """)
        #expect(s.count == 2)
        #expect(s[0].values["aws_access_key_id"] == "AKIAEXAMPLE")
        #expect(s[0].values["aws_secret_access_key"] == "secret/value+here")
        #expect(s[1].name == "work")          // "profile " prefix stripped
        #expect(s[1].values["region"] == "eu-west-1")
    }

    @Test("YAMLLite: gh hosts.yml host->token map")
    func ghHosts() {
        let creds = YAMLLite.hostTokens("""
        github.com:
            user: ada
            oauth_token: gho_abc123
            git_protocol: https
        ghe.corp.example:
            user: ada2
            oauth_token: gho_corp
        """, tokenKeys: ["oauth_token"], userKeys: ["user"])
        #expect(creds.count == 2)
        #expect(creds.first { $0.host == "github.com" }?.token == "gho_abc123")
        #expect(creds.first { $0.host == "github.com" }?.username == "ada")
        #expect(creds.first { $0.host == "ghe.corp.example" }?.token == "gho_corp")
    }

    @Test("apply: findings fold into a draft and count once")
    func applyIntoDraft() {
        var p = Profile(name: "w", tool: .claude, authMode: .token)
        let findings = [
            ConfigScan.Finding(
                id: "a", kind: .gitconfig, path: URL(fileURLWithPath: "/tmp/.gitconfig"),
                title: "Git config", detail: "", credentialCount: 1,
                symbol: "x", include: true,
                payload: .git(identity: (name: "Ada", email: "ada@example.com"),
                              creds: [.init(host: "github.com", username: "ada", token: "ghp_1")])),
            ConfigScan.Finding(
                id: "b", kind: .doctl, path: URL(fileURLWithPath: "/tmp/doctl"),
                title: "DO", detail: "", credentialCount: 1, symbol: "x", include: true,
                payload: .digitalOcean("dop_v1_abc")),
            // Unticked rows must not be imported.
            ConfigScan.Finding(
                id: "c", kind: .npm, path: URL(fileURLWithPath: "/tmp/.npmrc"),
                title: "npm", detail: "", credentialCount: 1, symbol: "x", include: false,
                payload: .manual(name: "npm", value: "npm_tok", envVar: "NPM_TOKEN", hosts: ["r"])),
        ]
        let s = ConfigScan.apply(findings, to: &p)
        #expect(p.gitUserName == "Ada")
        #expect(p.gitUserEmail == "ada@example.com")
        #expect(p.gitHTTPSCredentials.count == 1)
        #expect(p.digitalOceanToken == "dop_v1_abc")
        #expect(p.manualTokens.isEmpty, "an unticked finding must not be imported")
        #expect(s.total == 2)
    }

    @Test("apply: SSH keys and subscriptions are deferred, not written to the draft")
    func deferredKinds() {
        var p = Profile(name: "w", tool: .claude, authMode: .token)
        let findings = [
            ConfigScan.Finding(id: "k", kind: .sshKey,
                               path: URL(fileURLWithPath: "/tmp/id_ed25519"),
                               title: "key", detail: "", credentialCount: 1, symbol: "x",
                               include: true, payload: .sshKey(label: "id_ed25519")),
            ConfigScan.Finding(id: "s", kind: .claudeSubscription,
                               path: URL(fileURLWithPath: "/tmp/creds.json"),
                               title: "sub", detail: "", credentialCount: 1, symbol: "x",
                               include: true,
                               payload: .subscription(provider: "claude",
                                                      access: "a", refresh: "r")),
        ]
        let s = ConfigScan.apply(findings, to: &p)
        // Both need a saved profile / the MITM stores, so they ride the summary.
        #expect(s.deferredSSHKeys.count == 1)
        #expect(s.subscriptions.count == 1)
        #expect(s.subscriptions.first?.provider == "claude")
        #expect(s.total == 2)
    }

    @Test("scanning this Mac doesn't crash and reports plausible rows")
    func scanRealMachine() {
        // Not asserting specific findings — the point is that every detector
        // survives whatever is actually on disk here.
        let found = ConfigScan.scan()
        for f in found {
            #expect(!f.title.isEmpty)
            #expect(f.credentialCount >= 0)
            #expect(f.displayPath.hasPrefix("~") || f.displayPath.hasPrefix("/"))
        }
        print("scan found \(found.count) row(s): "
              + found.map { "\($0.kind.rawValue)(\($0.credentialCount))" }.joined(separator: ", "))
    }
}

// The agent credentials specifically: all four tools must be routable, and
// each must land in the right place — API keys on the profile, subscription
// logins deferred to the MITM stores (a draft can't hold them).
@Suite("Config scan — agent credentials")
struct ConfigScanAgentTests {

    @Test("api keys land on the right tool")
    func agentKeys() {
        var p = Profile(name: "w", tool: .claude, authMode: .subscription)
        let f = ConfigScan.Finding(
            id: "k", kind: .agentAPIKey, path: URL(fileURLWithPath: "/tmp/settings.json"),
            title: "keys", detail: "", credentialCount: 2, symbol: "x", include: true,
            payload: .agentKeys([(tool: .claude, value: "sk-ant-key"),
                                 (tool: .grok, value: "xai-key")]))
        let s = ConfigScan.apply([f], to: &p)
        // Primary tool gets the profile's own key and flips to token auth.
        #expect(p.apiKey == "sk-ant-key")
        #expect(p.authMode == .token)
        // A non-primary tool becomes an additionalTools entry.
        let grok = p.additionalTools.first { $0.tool == .grok }
        #expect(grok?.apiKey == "xai-key")
        #expect(grok?.authMode == .token)
        #expect(s.total == 2)
    }

    @Test("all four subscription providers are carried, not dropped")
    func subscriptionsForEveryAgent() {
        var p = Profile(name: "w", tool: .claude, authMode: .subscription)
        let providers = ["claude", "codex", "grok", "kimi"]
        let findings = providers.map { name in
            ConfigScan.Finding(
                id: name, kind: .claudeSubscription,
                path: URL(fileURLWithPath: "/tmp/\(name).json"),
                title: name, detail: "", credentialCount: 1, symbol: "x", include: true,
                payload: .subscription(provider: name, access: "a-\(name)", refresh: "r-\(name)"))
        }
        let s = ConfigScan.apply(findings, to: &p)
        #expect(s.subscriptions.count == 4)
        #expect(Set(s.subscriptions.map(\.provider)) == Set(providers))
        // They belong to the credential stores, so nothing should have been
        // written onto the profile itself.
        #expect(p.apiKey == nil || p.apiKey?.isEmpty == true)
        #expect(s.total == 4)
    }
}

// Claude Code on macOS stores its OAuth tokens in the LOGIN KEYCHAIN, not in
// ~/.claude/.credentials.json (that path is the Linux/guest one). Reading the
// wrong place is why Claude never showed up in the wizard.
@Suite("Keychain-backed agent logins")
struct KeychainCredentialTests {

    @Test("the claude keychain shape parses to an OAuth pair")
    func claudeShape() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-x","refreshToken":"sk-ant-ort01-y",
        "expiresAt":1785788541082,"scopes":["user:inference"],"subscriptionType":"max"}}
        """
        let pair = try #require(ConfigScan.oauthPair(fromJSON: json, provider: "claude"))
        #expect(pair.0 == "sk-ant-oat01-x")
        #expect(pair.1 == "sk-ant-ort01-y")
    }

    @Test("codex shape parses too, and junk is refused")
    func codexAndJunk() throws {
        let ok = try #require(ConfigScan.oauthPair(
            fromJSON: #"{"tokens":{"access_token":"a","refresh_token":"r","id_token":"i"}}"#,
            provider: "codex"))
        #expect(ok.0 == "a")
        // Wrong provider for the shape, empty tokens, and non-JSON all yield nil
        // rather than a half-built credential.
        #expect(ConfigScan.oauthPair(fromJSON: #"{"tokens":{}}"#, provider: "codex") == nil)
        #expect(ConfigScan.oauthPair(fromJSON: "not json", provider: "claude") == nil)
        #expect(ConfigScan.oauthPair(
            fromJSON: #"{"claudeAiOauth":{"accessToken":"","refreshToken":"r"}}"#,
            provider: "claude") == nil)
    }

    @Test("existence probe is safe on a service that isn't there")
    func missingService() {
        #expect(!ConfigScan.keychainItemExists(service: "definitely-not-a-real-service-\(UUID())"))
    }
}
