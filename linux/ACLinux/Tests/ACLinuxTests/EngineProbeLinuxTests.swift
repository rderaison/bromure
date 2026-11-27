import Foundation
import Testing
@testable import ACLinux

/// A fat client's "Test Connection" for a custom inference server, run by
/// the server (`POST /models/probe-server`): the client's copy of a stored
/// key is redacted, and the server substitutes the key it stores, only for
/// that exact server and from the configuration being edited. The lookup's
/// rules are macOS's (Tests/AgentCodingTests/EngineProbeKeyTests.swift).
@Suite("custom-server probe")
struct EngineProbeLinuxTests {
    private func base(_ s: String) -> URL { Profile.normalizedEngineBase(s)! }

    @Test("the stored key for the same server, however its URL is spelled")
    func sameServer() {
        let c: [(url: String?, key: String?)] = [("http://10.0.0.5:8000/v1/", "sk-real")]
        #expect(Daemon.engineKey(for: base("10.0.0.5:8000"), among: c) == "sk-real")
        #expect(Daemon.engineKey(for: base("http://10.0.0.5:8000/v1"), among: c) == "sk-real")
    }

    @Test("never a key stored for another server")
    func otherServer() {
        let c: [(url: String?, key: String?)] = [("http://10.0.0.5:8000", "sk-real")]
        #expect(Daemon.engineKey(for: base("http://evil.example:8000"), among: c) == nil)
        #expect(Daemon.engineKey(for: base("http://10.0.0.5:8001"), among: c) == nil)
    }

    @Test("blank or redacted stored keys are skipped")
    func skipsBlank() {
        let c: [(url: String?, key: String?)] = [("http://h:1", nil), ("http://h:1", ""),
                                                  ("http://h:1", ModelSettings.redactedSecret), ("http://h:1", "sk-2")]
        #expect(Daemon.engineKey(for: base("http://h:1"), among: c) == "sk-2")
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
        let c = Daemon.engineKeyCandidates(scope: scope, global: global.map { LocalServer(baseURL: Self.url, apiKey: $0) },
                                                  profiles: profiles, template: template)
        return Daemon.engineKey(for: base(Self.url), among: c)
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

    // MARK: The route, against a stand-in server

    @MainActor
    @Test("the probe runs from the server, with the key the client typed", .enabled(if: HTTPStub.available))
    func probes() async throws {
        let stub = try #require(try await HTTPStub(), "the stand-in server didn't start")
        defer { stub.stop() }
        let ok = await Daemon.probeEngine(base: stub.base, apiKey: "sk-typed", scope: .global)
        #expect(ok["ok"] as? Bool == true)
        #expect(ok["models"] as? [String] == ["alpha", "zeta"])
        #expect(stub.events.last?.hasPrefix("GET /v1/models auth=Bearer sk-typed ") == true, "\(stub.events)")
        // The server's refusal comes back as the answer, not as a failed request.
        let refused = await Daemon.probeEngine(base: stub.base + "/v1", apiKey: "wrong", scope: .global)
        #expect(refused["ok"] as? Bool == false)
        #expect((refused["error"] as? String)?.contains("401") == true, "\(refused)")
    }

    @MainActor
    @Test("what isn't an http(s) server URL is refused without a request")
    func badURL() async {
        for raw in ["", "   ", "ftp://10.0.0.5/models", "file:///etc/passwd"] {
            let r = await Daemon.probeEngine(base: raw, apiKey: nil)
            #expect(r["ok"] as? Bool == false, "\(raw): \(r)")
        }
    }

    @Test("the route needs a server URL; a failed probe is still an answer", .enabled(if: HTTPStub.available))
    func route() async throws {
        let (d, _, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(await d.handle(ControlRequest(method: "POST", path: "/models/probe-server", body: .object([:]))).status == 400)
        let stub = try #require(try await HTTPStub(), "the stand-in server didn't start")
        defer { stub.stop() }
        let good = await d.handle(ControlRequest(method: "POST", path: "/models/probe-server",
                                                 body: ["baseURL": .string(stub.base), "apiKey": "sk-typed", "scope": "global"]))
        #expect(good.status == 200 && good.body["ok"] == .bool(true), "\(good.body)")
        #expect(good.body["models"] == .array(["alpha", "zeta"]))
        let bad = await d.handle(ControlRequest(method: "POST", path: "/models/probe-server",
                                                body: ["baseURL": .string(stub.base), "apiKey": "wrong"]))
        #expect(bad.status == 200 && bad.body["ok"] == .bool(false), "\(bad.body)")
        // The built-in engine's verbs are still their own route.
        #expect(await d.handle(ControlRequest(method: "POST", path: "/models/download", body: ["repo": "x/y"])).status == 400)
        await d.shutdown()
    }
}
