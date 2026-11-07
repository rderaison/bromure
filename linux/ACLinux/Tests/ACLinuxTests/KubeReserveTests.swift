import Foundation
import Testing
@testable import ACLinux
import SandboxEngine

/// A cluster engine host that does nothing (tests of the engine's
/// host-independent steps).
final class InertKubeHost: KubeEngineHost {
    func makeKubeMachine(_ m: KubeClusterEngine.MachineSpec, runtime: KubeClusterEngine.NodeRuntime,
                         fsFailure: KubeClusterEngine.BootFSFailure, engine: KubeClusterEngine) throws {}
    func startKubeMachine(_ m: KubeClusterEngine.MachineSpec, runtime: KubeClusterEngine.NodeRuntime,
                          repairAttempted: Bool, engine: KubeClusterEngine) async throws {}
    func kubeMachineAnswers(_ nodeID: UUID) -> Bool { false }
    func setKubeMachineIP(_ nodeID: UUID, _ ip: String) {}
    func stopKubeMachineForRepair(_ runtime: KubeClusterEngine.NodeRuntime) async {}
    func repairKubeMachineDisks(_ m: KubeClusterEngine.MachineSpec) async -> Bool { false }
    func deepRepairKubeMachineDisks(_ m: KubeClusterEngine.MachineSpec, engine: KubeClusterEngine) async throws {}
    func stopKubeMachine(_ nodeID: UUID) async {}
    func kubeMachineStopped(_ nodeID: UUID) {}
    func guestExec(profileID: ACLinux.Profile.ID, command: String, timeout: Int) async throws -> String { "" }
    func guestFileOp(profileID: ACLinux.Profile.ID, op: [String: Any], timeout: Int) async throws -> [String: Any] { [:] }
    func openKubeRelay(nodeID: UUID, target: String, completion: @escaping @Sendable (Int32) -> Void) { completion(-1) }
    func refreshKubeAccessForRunningWorkspaces() {}
    func kubeHostIPv4() -> String? { nil }
    var kubeHostDisplayName: String { "test" }
    func parseKubeLANPool(_ text: String) -> [UInt32]? { nil }
    func makeKubeLoadBalancer(engine: KubeClusterEngine, clusterID: UUID, serverNodeID: UUID,
                              serverIP: String, hostIP: String?, pool: [UInt32]) -> (any KubeServicePublisher)? { nil }
    var kubeNodeScriptURL: URL? { nil }
    var kubeProbeScriptURL: URL? { nil }
    var kubeRegistryScriptURL: URL? { nil }
    var connectorScriptURL: URL? { nil }
    var connectorRelayURL: URL? { nil }
}

/// A restarted daemon's clusters: their MetalLB ranges are out of the DHCP
/// as soon as the engine is up, before any cluster starts again.
@Suite("Kube LoadBalancer ranges on restart", .serialized)
@MainActor
struct KubeReserveTests {
    @Test func aKnownClustersRangeIsNeverLeasedAfterARestart() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = KubeClusterStore(fileURL: URL(fileURLWithPath: dir + "/clusters.json"))
        var c = KubeCluster(name: "lb", spec: KubeClusterSpec())
        c.metallbRange = "192.168.64.230-192.168.64.249"
        store.upsert(c)
        let range = InterimDHCP.u32([192, 168, 64, 230])...InterimDHCP.u32([192, 168, 64, 249])
        defer { VMNetSwitch.shared.unreserveIPs(Set(range)) }
        let host = InertKubeHost()
        let engine = KubeClusterEngine(host: host, store: store, rootDirectory: URL(fileURLWithPath: dir, isDirectory: true))
        Daemon.kubeEngineReady(engine)
        // A switch whose first 228 addresses are taken: the next leases
        // would fall in the range if it weren't reserved.
        let sw = InterimSwitch(uplink: SwitchSubnetTests.RecordingUplink())
        defer { sw.stop() }
        var leased: [UInt32] = []
        for i in 0..<240 {
            let mac: [UInt8] = [0x52, 0x54, 0, 0, UInt8(i >> 8), UInt8(i & 0xFF)]
            if let ip = sw.dhcp.lease(for: mac) { leased.append(InterimDHCP.u32(ip)) }
        }
        #expect(leased.count > 228, "the pool past the range was leased: \(leased.count)")
        #expect(!leased.contains { range.contains($0) }, "no lease in the cluster's range")
    }
}
