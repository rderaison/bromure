import Foundation
import Testing
@testable import bromure_ac

/// A fat client's "Test Connection" sends its redacted copy of the key; the
/// host substitutes the key it stores — only for that exact server, so a
/// client can't send a stored key to a URL of its choosing.
@Suite("custom-server probe key lookup")
struct EngineProbeKeyTests {
    private func base(_ s: String) -> URL { Profile.normalizedEngineBase(s)! }

    @Test("the stored key for the same server, however its URL is spelled")
    func sameServer() {
        let c: [(url: String?, key: String?)] = [("http://10.0.0.5:8000/v1/", "sk-real")]
        #expect(ACAppDelegate.engineKey(for: base("10.0.0.5:8000"), among: c) == "sk-real")
        #expect(ACAppDelegate.engineKey(for: base("http://10.0.0.5:8000/v1"), among: c) == "sk-real")
    }

    @Test("never a key stored for another server")
    func otherServer() {
        let c: [(url: String?, key: String?)] = [("http://10.0.0.5:8000", "sk-real")]
        #expect(ACAppDelegate.engineKey(for: base("http://evil.example:8000"), among: c) == nil)
        #expect(ACAppDelegate.engineKey(for: base("http://10.0.0.5:8001"), among: c) == nil)
    }

    @Test("blank or redacted stored keys are skipped")
    func skipsBlank() {
        let c: [(url: String?, key: String?)] = [("http://h:1", nil), ("http://h:1", ""),
                                                  ("http://h:1", ModelSettings.redactedSecret), ("http://h:1", "sk-2")]
        #expect(ACAppDelegate.engineKey(for: base("http://h:1"), among: c) == "sk-2")
    }

    // Regression: the lookup took the first key for the URL anywhere, global
    // settings first, so a workspace using the same server with its own key
    // (a tenant key) was tested with the global one, and workspaces with
    // each other's, by list order.

    private static let url = "http://10.0.0.5:8000/v1"
    private func workspace(_ key: String?, override: ModelOverride? = nil, engine: Bool = false) -> Profile {
        var p = Profile(name: "w", tool: .claude, authMode: .subscription)
        if engine { p.localEngineURL = Self.url; p.localEngineAPIKey = key }
        else { p.modelOverride = override ?? ModelOverride(settings: ModelSettings(localServer: LocalServer(baseURL: Self.url, apiKey: key))) }
        return p
    }
    private func key(_ scope: EngineProbeScope, global: String?, _ profiles: [Profile],
                     template: Profile = Profile(name: "t", tool: .claude, authMode: .subscription)) -> String? {
        let c = ACAppDelegate.engineKeyCandidates(scope: scope, global: global.map { LocalServer(baseURL: Self.url, apiKey: $0) },
                                                  profiles: profiles, template: template)
        return ACAppDelegate.engineKey(for: base(Self.url), among: c)
    }

    @Test("each configuration on a shared server URL tests its own key")
    func ownKeyPerScope() {
        let a = workspace("sk-a"), b = workspace("sk-b"), e = workspace("sk-e", engine: true)
        let all = [a, b, e]
        #expect(key(.global, global: "sk-global", all) == "sk-global")
        #expect(key(.workspace(a.id), global: "sk-global", all) == "sk-a")
        #expect(key(.workspace(b.id), global: "sk-global", all) == "sk-b")
        #expect(key(.workspace(e.id), global: "sk-global", all) == "sk-e")
        // Global settings never use a workspace's key.
        #expect(key(.global, global: nil, all) == nil)
    }

    @Test("a workspace without its own key uses the global one only if it inherits it")
    func inheritedGlobal() {
        let plain = Profile(name: "w", tool: .claude, authMode: .subscription)
        let layered = workspace(nil)
        let excluded = workspace(nil, override: ModelOverride(excludedProviders: [.custom]))
        let standalone = workspace(nil, override: .standalone(ModelSettings()))
        let all = [plain, layered, excluded, standalone]
        #expect(key(.workspace(plain.id), global: "sk-global", all) == "sk-global")
        #expect(key(.workspace(layered.id), global: "sk-global", all) == "sk-global")
        #expect(key(.workspace(excluded.id), global: "sk-global", all) == nil)
        #expect(key(.workspace(standalone.id), global: "sk-global", all) == nil)
    }

    @Test("a workspace not saved yet is the template's copy")
    func unsavedWorkspace() {
        let template = workspace("sk-template")
        #expect(key(.workspace(UUID()), global: "sk-global", [workspace("sk-a")], template: template) == "sk-template")
        #expect(key(.workspace(nil), global: "sk-global", [], template: template) == "sk-template")
    }

    @Test("the request names its scope; a client without one gets the old lookup")
    func wire() {
        let id = UUID()
        for s in [EngineProbeScope.global, .workspace(id), .workspace(nil), .unspecified] {
            #expect(EngineProbeScope(wire: s.wire) == s)
        }
        let a = workspace("sk-a")
        #expect(key(.unspecified, global: "sk-global", [a]) == "sk-global")
        #expect(key(.unspecified, global: nil, [a]) == "sk-a")
    }
}
