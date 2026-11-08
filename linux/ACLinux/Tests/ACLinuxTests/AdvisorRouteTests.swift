import Foundation
import Testing
import struct SandboxEngine.EgressPolicy
import struct SandboxEngine.OpenShellPolicy
@testable import ACLinux

extension DaemonGlobalSuites {
    /// The OpenShell advisor on a Linux server (macOS: wireOpenShellAdvisor
    /// and the /profiles/<id>/proposals, openshell-allow and sandbox-path
    /// routes): the Sandbox drawer's decisions from a fat client land in the
    /// workspace's policy through the editor's save path, with a revision.
    @Suite("Advisor routes", .serialized)
    struct AdvisorRouteTests {
        static let policy = """
        version: 1
        network_policies:
          web:
            endpoints:
              - { host: allowed.example, port: 443 }
        filesystem_policy:
          read_only: [/usr]
        """

        @Test func theDrawersDecisionsLandInThePolicy() async throws {
            let prior = ProfileStore.defaultRootDir
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            let priorHost = await MainActor.run { LinuxSessionHost.shared }
            defer {
                ProfileStore.defaultRootDir = prior
                try? FileManager.default.removeItem(atPath: dir)
            }
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            await MainActor.run { LinuxSessionHost.shared = LinuxSessionHost(daemon: d, stateDir: dir) }
            await d.wireOpenShellAdvisor()
            var p = Profile(name: "adv", tool: .claude, authMode: .token)
            p.networkPolicy = Self.policy
            p = try ProfileStore().save(p)
            let base = "/profiles/\(p.id.uuidString)"
            func saved() -> Profile? { ProfileStore().loadAll().first { $0.id == p.id } }

            let list = await d.workspaceRoute("GET", base + "/proposals", .null)
            #expect(list?.status == 200, "\(String(describing: list?.body))")
            if case .array = list?.body["proposals"] ?? .null {} else { Issue.record("no proposals list") }

            let path = await d.workspaceRoute("POST", base + "/sandbox-path", ["path": "/opt/tool", "readWrite": true])
            #expect(path?.status == 200, "\(String(describing: path?.body))")
            #expect(saved()?.networkPolicy.contains("/opt/tool") == true)
            let revs = PolicyHistory.shared.revisions(in: ProfileStore().profileDirectory(for: p))
            #expect(revs.last?.source == "drawer", "\(revs.map(\.source))")

            // Running: the proxy holds its guardrails (the advisor reads the
            // effective policy there, as macOS's from the engine).
            let mitm = try #require(await d.mitm)
            mitm.setGuardrailsConfig(GuardrailsConfig(kubernetes: .off, kubeHosts: [],
                                                      egressPolicy: SandboxEngine.EgressPolicy(openShell: try SandboxEngine.OpenShellPolicy.parse(saved()!.networkPolicy))),
                                     for: p.id)
            defer { mitm.clearGuardrailsConfig(for: p.id) }
            let allow = await d.workspaceRoute("POST", base + "/openshell-allow", ["host": "api.newhost.example", "port": 443])
            #expect(allow?.status == 200, "\(String(describing: allow?.body))")
            #expect(saved()?.networkPolicy.contains("api.newhost.example") == true)

            #expect(await d.workspaceRoute("POST", base + "/sandbox-path", ["path": "relative"])?.status == 400)
            #expect(await d.workspaceRoute("POST", base + "/openshell-allow", ["host": "h", "port": 0])?.status == 400)
            #expect(await d.workspaceRoute("GET", base + "/sandbox-path", .null)?.status == 405)
            await MainActor.run { LinuxSessionHost.shared = priorHost }
            await d.shutdown()
        }
    }
}
