import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import ACLinux
import SandboxEngine

/// Fusion on the Linux proxy: its toggle and config per workspace, the
/// step's gates (live legs reach real providers, so the run itself isn't
/// exercised here), the route and /vms's fields.
extension DaemonGlobalSuites {
    @Suite("Fusion (Linux wiring)", .serialized)
    struct FusionLinuxTests {
        static let config = Fusion.Config(legs: [.claude, .codex], judgeProvider: .claude, judgeModel: "judge",
                                          authModes: [.claude: .token, .codex: .token], legModels: [:],
                                          localLegModel: nil, judgeLocal: false, localEngineBase: nil,
                                          localEngineKey: nil, ompProvider: .default)

        @Test func theToggleAndConfigArePerWorkspaceAndTheStepIsGated() async throws {
            let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
            let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
            let a = UUID(), b = UUID()
            #expect(!proxy.fusionEngaged(for: a) && proxy.fusionConfig(for: a) == nil)
            proxy.setFusionConfig(Self.config, for: a)
            proxy.setFusionEngaged(true, for: a)
            #expect(proxy.fusionEngaged(for: a) && proxy.fusionConfig(for: a) != nil)
            #expect(!proxy.fusionEngaged(for: b) && proxy.fusionConfig(for: b) == nil, "another workspace's are its own")
            let turn = Data(#"POST /v1/messages HTTP/1.1\#r\#nHost: api.anthropic.com\#r\#nContent-Length: 2\#r\#n\#r\#n{}"#.utf8)
            // Not engaged: the turn goes on as usual.
            #expect(await RequestReader.fusionAnswer(turn, proxy: proxy, profileID: b, host: "api.anthropic.com", port: 443, trace: nil) == nil)
            // Engaged, but this proxy dials no real upstream (e2e): never run.
            proxy.refusesRealUpstreams = true
            #expect(await RequestReader.fusionAnswer(turn, proxy: proxy, profileID: a, host: "api.anthropic.com", port: 443, trace: nil) == nil)
            proxy.clearFusionEngaged(for: a)
            #expect(!proxy.fusionEngaged(for: a) && proxy.fusionConfig(for: a) != nil, "a stop clears the toggle, not the config")
            proxy.clearFusionConfig(for: a)
            #expect(proxy.fusionConfig(for: a) == nil)
        }

        @Test func theRouteNeedsARunningConfigurableWorkspace() async throws {
            let (d, rec, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let r = await d.fusionRoute(rec, .object(["engaged": .bool(true)]))
            #expect(r.status == 409, "not running: \(r.body)")
            await d.shutdown()
        }

        @Test func theLegHostsFollowTheConfig() {
            var c = Self.config
            #expect(Set(RequestReader.fusionLegHosts(c)) == ["api.anthropic.com", "api.openai.com"])
            c.legs = [.codex, .grok, .kimi]
            c.authModes = [.codex: .subscription, .grok: .subscription, .kimi: .token]
            c.judgeProvider = .grok
            #expect(Set(RequestReader.fusionLegHosts(c)) == ["chatgpt.com", "cli-chat-proxy.grok.com", "api.moonshot.ai"])
            c.judgeLocal = true
            c.localEngineBase = "https://engine.example.test:8443"
            #expect(RequestReader.fusionLegHosts(c).contains("engine.example.test"), "a user's external engine is checked too")
            c.localEngineBase = nil
            #expect(!RequestReader.fusionLegHosts(c).contains(InferenceService.engineHost), "not the on-host engine")
        }

        @Test func aRefusedLegMakesFusionStepAside() async throws {
            let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
            let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
            let pid = UUID()
            proxy.setFusionConfig(Self.config, for: pid)
            proxy.setFusionEngaged(true, for: pid)
            // The firewall denies every leg (no name is even looked up).
            proxy.setGuardrailsConfig(GuardrailsConfig(kubernetes: .off, kubeHosts: [],
                                                       egressPolicy: try EgressPolicy.parse("default deny")), for: pid)
            if case .success = await proxy.checkFusionLeg("api.openai.com", profileID: pid) { Issue.record("a denied leg passed") }
            let turn = Data(#"POST /v1/messages HTTP/1.1\#r\#nHost: api.anthropic.com\#r\#nContent-Length: 2\#r\#n\#r\#n{}"#.utf8)
            #expect(await RequestReader.fusionAnswer(turn, proxy: proxy, profileID: pid, host: "api.anthropic.com", port: 443, trace: nil) == nil,
                    "the turn goes the normal way")
        }

        @Test func thePinnedProtocolDialsOnlyCheckedAddresses() async throws {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [FusionPinnedProtocol.self]
            let session = URLSession(configuration: cfg)
            defer { session.finishTasksAndInvalidate() }
            var req = URLRequest(url: URL(string: "https://unchecked.example.test/v1/x")!)
            req.timeoutInterval = 5
            do {
                _ = try await session.data(for: req)
                Issue.record("an unchecked host was dialled")
            } catch {
                #expect((error as? URLError)?.code == .cannotConnectToHost, "refused before any lookup: \(error)")
            }
            // Two runs checked the same host: only the addresses both passed.
            let a = UUID(), b = UUID()
            let x = OpenShellPolicy.IPAddress.v4(0xCB007101), y = OpenShellPolicy.IPAddress.v4(0xCB007102)
            FusionPinnedProtocol.add(a, ["h.example.test": [x, y]])
            FusionPinnedProtocol.add(b, ["h.example.test": [y]])
            #expect(FusionPinnedProtocol.addresses(for: "h.example.test") == [y])
            FusionPinnedProtocol.remove(b)
            #expect(FusionPinnedProtocol.addresses(for: "h.example.test") == [x, y])
            FusionPinnedProtocol.remove(a)
            #expect(FusionPinnedProtocol.addresses(for: "h.example.test").isEmpty)
        }

        @Test("the collected reply is what Fusion wrote, in order")
        func collectedReply() throws {
            let c = CollectedReply()
            try c.write(Data("HTTP/1.1 200 OK\r\n".utf8))
            try c.write(Data("\r\n".utf8))
            #expect(String(decoding: c.data, as: UTF8.self) == "HTTP/1.1 200 OK\r\n\r\n")
        }
    }
}
