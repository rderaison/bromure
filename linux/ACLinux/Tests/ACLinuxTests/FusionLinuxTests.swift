import Foundation
import Testing
@testable import ACLinux

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

        @Test("the collected reply is what Fusion wrote, in order")
        func collectedReply() throws {
            let c = CollectedReply()
            try c.write(Data("HTTP/1.1 200 OK\r\n".utf8))
            try c.write(Data("\r\n".utf8))
            #expect(String(decoding: c.data, as: UTF8.self) == "HTTP/1.1 200 OK\r\n\r\n")
        }
    }
}
