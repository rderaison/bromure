import Foundation
import Testing
@testable import bromure_ac

/// Coverage for SessionTokenPlan's pure mapping logic: per-purpose host
/// scoping (exercised through the public `tokenMap()`, since `hostScope` is
/// private), the deterministic subscription bogus-key derivation and its
/// exclusion from the swap map, body-scan scoping, and the fake-token
/// accessors.
@Suite("SessionTokenPlan host scoping")
struct SessionTokenPlanScopingTests {

    /// First mapped entry's host for a single-purpose plan.
    private func host(_ purpose: SessionTokenPlan.Purpose) -> String? {
        SessionTokenPlan(entries: [
            .init(realValue: "REAL", fakeValue: "FAKE", purpose: purpose)
        ]).tokenMap().entries.first?.host
    }

    @Test("anthropic API key → anthropic.com") func anthropic() {
        #expect(host(.anthropicAPIKey) == "anthropic.com")
    }
    @Test("openai API key → openai.com") func openai() {
        #expect(host(.openaiAPIKey) == "openai.com")
    }
    @Test("xai API key → x.ai") func xai() {
        #expect(host(.xaiAPIKey) == "x.ai")
    }
    @Test("git HTTPS → its host") func git() {
        #expect(host(.gitHTTPS(host: "github.com", username: "u")) == "github.com")
    }
    @Test("digitalOcean → digitalocean.com") func digitalOcean() {
        #expect(host(.digitalOcean) == "digitalocean.com")
    }
    @Test("linear → linear.app") func linear() {
        #expect(host(.linear) == "linear.app")
    }
    @Test("docker registry → registry host") func docker() {
        #expect(host(.dockerRegistry(host: "registry.example.io", username: "u")) == "registry.example.io")
    }

    @Test("manual with empty host filter → unscoped (nil)") func manualEmpty() {
        #expect(host(.manual(name: "n", envVarName: "E", hostFilter: "")) == nil)
    }
    @Test("manual with host filter → that host") func manualScoped() {
        #expect(host(.manual(name: "n", envVarName: "E", hostFilter: "internal.corp")) == "internal.corp")
    }
    @Test("mcp bearer empty host → unscoped (nil)") func mcpEmpty() {
        #expect(host(.mcpBearer(serverName: "s", envVarName: "E", host: "")) == nil)
    }
    @Test("mcp bearer with host → that host") func mcpScoped() {
        #expect(host(.mcpBearer(serverName: "s", envVarName: "E", host: "mcp.example.com")) == "mcp.example.com")
    }
    @Test("httpDatabase empty host → unscoped (nil)") func dbEmpty() {
        #expect(host(.httpDatabase(host: "", endpointID: "e", envVars: [], isPrimary: true)) == nil)
    }
    @Test("httpDatabase with host → that host") func dbScoped() {
        #expect(host(.httpDatabase(host: "db.example.com", endpointID: "e", envVars: ["X"], isPrimary: true)) == "db.example.com")
    }
}

@Suite("SessionTokenPlan tokenMap shape")
struct SessionTokenPlanMapTests {

    @Test("tokenMap preserves fake/real verbatim") func preservesValues() {
        let map = SessionTokenPlan(entries: [
            .init(realValue: "REALTOK", fakeValue: "FAKETOK", purpose: .anthropicAPIKey)
        ]).tokenMap()
        #expect(map.entries.first?.fake == "FAKETOK")
        #expect(map.entries.first?.real == "REALTOK")
    }

    @Test("Only httpDatabase entries enable the body scan") func bodyScan() {
        let db = SessionTokenPlan(entries: [
            .init(realValue: "r", fakeValue: "f",
                  purpose: .httpDatabase(host: "h", endpointID: "e", envVars: [], isPrimary: true))
        ]).tokenMap()
        #expect(db.entries.first?.body == true)

        let key = SessionTokenPlan(entries: [
            .init(realValue: "r", fakeValue: "f", purpose: .anthropicAPIKey)
        ]).tokenMap()
        #expect(key.entries.first?.body == false)
    }

    @Test("consentDisplayName carried only when a consent ID is set") func consentDisplay() {
        let gated = SessionTokenPlan(entries: [
            .init(realValue: "r", fakeValue: "f", purpose: .anthropicAPIKey,
                  consentCredentialID: "cred-1", consentDisplayName: "Claude API key")
        ]).tokenMap()
        #expect(gated.entries.first?.consentCredentialID == "cred-1")
        #expect(gated.entries.first?.consentDisplayName == "Claude API key")

        // Display name without an ID is dropped (ungated → never prompts).
        let ungated = SessionTokenPlan(entries: [
            .init(realValue: "r", fakeValue: "f", purpose: .anthropicAPIKey,
                  consentCredentialID: nil, consentDisplayName: "ignored")
        ]).tokenMap()
        #expect(ungated.entries.first?.consentDisplayName == nil)
    }

    @Test("Subscription bogus key is kept OUT of the token map") func bogusKeyExcluded() {
        let plan = SessionTokenPlan(entries: [],
                                    claudeSubscriptionBogusKey: "sk-ant-api03-brm-xyz")
        #expect(plan.tokenMap().entries.isEmpty)
        #expect(plan.claudeSubscriptionBogusKey == "sk-ant-api03-brm-xyz")
    }
}

@Suite("SessionTokenPlan bogus key + accessors")
struct SessionTokenPlanBogusKeyTests {

    private let salt = Data("a-stable-salt".utf8)

    @Test("Bogus key is deterministic in (salt, profileID)") func deterministic() {
        let pid = UUID()
        let a = SessionTokenPlan.claudeSubscriptionBogusKey(salt: salt, profileID: pid)
        let b = SessionTokenPlan.claudeSubscriptionBogusKey(salt: salt, profileID: pid)
        #expect(a == b)
        #expect(a.hasPrefix("sk-ant-api03-brm-"))
    }

    @Test("Distinct profileIDs yield distinct bogus keys") func perProfile() {
        let a = SessionTokenPlan.claudeSubscriptionBogusKey(salt: salt, profileID: UUID())
        let b = SessionTokenPlan.claudeSubscriptionBogusKey(salt: salt, profileID: UUID())
        #expect(a != b)
    }

    @Test("A different salt rotates the bogus key") func saltRotates() {
        let pid = UUID()
        let a = SessionTokenPlan.claudeSubscriptionBogusKey(salt: salt, profileID: pid)
        let b = SessionTokenPlan.claudeSubscriptionBogusKey(salt: Data("other".utf8), profileID: pid)
        #expect(a != b)
    }

    @Test("fakeFor accessors return the matching entry's fake") func fakeAccessors() {
        let plan = SessionTokenPlan(entries: [
            .init(realValue: "ra", fakeValue: "fa", purpose: .anthropicAPIKey),
            .init(realValue: "ro", fakeValue: "fo", purpose: .openaiAPIKey),
            .init(realValue: "rx", fakeValue: "fx", purpose: .xaiAPIKey),
            .init(realValue: "rg", fakeValue: "fg",
                  purpose: .gitHTTPS(host: "github.com", username: "bob")),
        ])
        #expect(plan.fakeForAnthropic() == "fa")
        #expect(plan.fakeForOpenAI() == "fo")
        #expect(plan.fakeForXAI() == "fx")
        #expect(plan.fakeForGitHTTPS(host: "github.com", username: "bob") == "fg")
        // Non-matching git lookup → nil.
        #expect(plan.fakeForGitHTTPS(host: "gitlab.com", username: "bob") == nil)
    }

    @Test("Empty plan returns nil accessors") func emptyAccessors() {
        let plan = SessionTokenPlan()
        #expect(plan.fakeForAnthropic() == nil)
        #expect(plan.fakeForOpenAI() == nil)
        #expect(plan.fakeForDigitalOcean() == nil)
        #expect(plan.fakeForLinear() == nil)
        #expect(plan.tokenMap().entries.isEmpty)
    }

    @Test("Linear token plans a lin_api_ fake matching the real key shape") func linearPlan() {
        var p = Profile(name: "ws", tool: .claude, authMode: .subscription)
        p.linearToken = "lin_api_realREALrealREALrealREALrealREALreal"
        let plan = p.makeTokenPlan(salt: salt)

        let fake = plan.fakeForLinear()
        #expect(fake != nil)
        #expect(fake?.hasPrefix("lin_api_") == true)
        #expect(fake?.count == 48)   // real Linear keys: lin_api_ + 40
        #expect(fake != p.linearToken)
        // Swap entry scoped to linear.app; ungated by default.
        let entry = plan.tokenMap().entries.first { $0.fake == fake }
        #expect(entry?.host == "linear.app")
        #expect(entry?.real == p.linearToken)
        #expect(entry?.consentCredentialID == nil)
        // Deterministic in (real, salt) so the fake never rotates mid-profile.
        #expect(p.makeTokenPlan(salt: salt).fakeForLinear() == fake)
    }

    @Test("Gated Linear token carries the linear consent ID") func linearConsent() {
        var p = Profile(name: "ws", tool: .claude, authMode: .subscription)
        p.linearToken = "lin_api_x"
        p.linearTokenRequiresApproval = true
        let plan = p.makeTokenPlan(salt: salt)
        let entry = plan.tokenMap().entries.first { $0.fake == plan.fakeForLinear() }
        #expect(entry?.consentCredentialID == ConsentCredentialID.linear())
    }

    @Test("Whitespace-only Linear token plans nothing") func linearBlank() {
        var p = Profile(name: "ws", tool: .claude, authMode: .subscription)
        p.linearToken = "  \n"
        #expect(p.makeTokenPlan(salt: salt).fakeForLinear() == nil)
    }
}

@Suite("SessionTokenPlan helpers")
struct SessionTokenPlanHelperTests {

    @Test("dockerAuthRealms maps known multi-host registries") func realms() {
        #expect(SessionTokenPlan.dockerAuthRealms(for: "registry.digitalocean.com") == ["api.digitalocean.com"])
        #expect(SessionTokenPlan.dockerAuthRealms(for: "docker.io") == ["auth.docker.io"])
        #expect(SessionTokenPlan.dockerAuthRealms(for: "index.docker.io") == ["auth.docker.io"])
        #expect(SessionTokenPlan.dockerAuthRealms(for: "public.ecr.aws") == ["public.ecr.aws"])
        #expect(SessionTokenPlan.dockerAuthRealms(for: "registry.example.io").isEmpty)
    }

    @Test("dockerAuthRealms is case-insensitive + trims") func realmsNormalize() {
        #expect(SessionTokenPlan.dockerAuthRealms(for: "  Docker.IO ") == ["auth.docker.io"])
    }

    @Test("deriveFake is stable for (prefix, real, salt) and honors targetLength") func deriveFake() {
        let salt = Data("s".utf8)
        let a = SessionTokenPlan.deriveFake(prefix: "ghp_", real: "secret", salt: salt, targetLength: 40)
        let b = SessionTokenPlan.deriveFake(prefix: "ghp_", real: "secret", salt: salt, targetLength: 40)
        #expect(a == b)
        #expect(a.count == 40)
        #expect(a.hasPrefix("ghp_"))
        // Different real → different fake.
        let c = SessionTokenPlan.deriveFake(prefix: "ghp_", real: "other", salt: salt, targetLength: 40)
        #expect(a != c)
    }

    @Test("manual/mcp/httpDatabase env-export accessors collect named vars") func envExports() {
        let plan = SessionTokenPlan(entries: [
            .init(realValue: "r1", fakeValue: "f1",
                  purpose: .manual(name: "Tok", envVarName: "MY_TOK", hostFilter: "")),
            .init(realValue: "r2", fakeValue: "f2",
                  purpose: .manual(name: "NoEnv", envVarName: "", hostFilter: "")),
            .init(realValue: "r3", fakeValue: "f3",
                  purpose: .mcpBearer(serverName: "srv", envVarName: "MCP_TOK", host: "h")),
            .init(realValue: "r4", fakeValue: "f4",
                  purpose: .httpDatabase(host: "h", endpointID: "e", envVars: ["DB_URL"], isPrimary: true)),
        ])
        // Manual exports only include entries with a non-empty env var name.
        let manual = Dictionary(uniqueKeysWithValues: plan.manualEnvExports.map { ($0.0, $0.1) })
        #expect(manual["MY_TOK"] == "f1")
        #expect(manual["NoEnv"] == nil)
        // MCP bearer fakes carry server + env var.
        #expect(plan.mcpBearerFakes.contains { $0.serverName == "srv" && $0.envVarName == "MCP_TOK" && $0.fake == "f3" })
        // httpDatabase primary env exports.
        #expect(plan.httpDatabaseEnvExports.contains { $0.0 == "DB_URL" && $0.1 == "f4" })
    }
}
