import Foundation
import Testing

/// A stop that ends with the VM still running (a suspend refused, or one
/// whose snapshot ran out of disk and resumed the VM) must leave the
/// workspace's Cloudflare quick tunnels up: re-exposing them would mint new
/// random URLs and break the published ones. So `stopSession` tears them
/// down only on the way out of a stop that happened, after every early
/// return that keeps the VM running.
@Suite("Stopping a workspace: tunnels")
struct StopSessionTunnelTests {
    private static func src(_ p: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8)
    }

    @Test("tunnels are torn down after the keep-running returns, just before the teardown")
    func unexposeAfterKeepRunningReturns() throws {
        let ac = try Self.src("Sources/AgentCoding/BromureAC.swift")
        let fn = try #require(ac.range(of: "func stopSession(_ profileID: Profile.ID, action: Profile.CloseAction) async -> String? {"))
        let end = try #require(ac.range(of: "\n    }\n", range: fn.upperBound..<ac.endIndex))
        let body = String(ac[fn.upperBound..<end.lowerBound])
        let unexpose = "CloudflareTunnelSupervisor.shared.unexposeAll(prefix:"
        // Once, in the stop path.
        #expect(body.components(separatedBy: unexpose).count - 1 == 1)
        let at = try #require(body.range(of: unexpose))
        // Every return that leaves the VM running comes before it…
        let keepRunning = ["return error.localizedDescription", "return why"]
        for r in keepRunning {
            let ret = try #require(body.range(of: r), "\(r) not found")
            #expect(ret.lowerBound < at.lowerBound, "\(r) must return before the tunnels go")
        }
        // …and only the stopped VM's teardown follows it.
        let after = body[at.upperBound...]
        #expect(after.contains("handleSessionStopped(profileID: profileID)"))
        #expect(!after.contains("await "))
    }
}
