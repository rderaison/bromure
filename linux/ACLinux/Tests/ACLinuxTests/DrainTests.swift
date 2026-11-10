import Foundation
import Testing
@testable import ACLinux

/// A stopping daemon ends each running VM as macOS's quit does.
@Suite("Daemon stop: drained by close action")
struct DrainTests {
    static func rec(_ name: String) -> VMRecord {
        VMRecord(id: UUID().uuidString.lowercased(), name: name, machine: "fc", cid: 3, mac: "02:00:00:00:00:01", state: .running,
                 ip: nil, cpus: 1, memoryMiB: 512, createdAt: Date(), bootedAt: nil, statePath: nil)
    }

    @Test func eachVMEndsAsItsCloseActionSays() {
        let suspend = Self.rec("s"), shut = Self.rec("d"), ask = Self.rec("a"), bg = Self.rec("b")
        var node = Self.rec("node"); node.kube = UUID().uuidString
        var signIn = Self.rec("reg"); signIn.registration = true
        var rescue = Self.rec("rescue"); rescue.rescueFor = suspend.id
        let noProfile = Self.rec("gone")
        let actions: [String: Profile.CloseAction] = [suspend.id: .suspend, shut.id: .shutdown, ask.id: .ask, bg.id: .background]
        let plan = Daemon.drainPlan([suspend, shut, ask, bg, node, signIn, rescue, noProfile]) { r in
            actions[r.id].map { a in var p = Profile(name: r.name, tool: .claude, authMode: .token); p.closeAction = a; return p }
        }
        #expect(plan.map { "\($0.0.name)=\($0.1)" } == ["s=suspend", "d=shutdown", "a=suspend", "b=suspend", "node=suspend"],
                "a sign-in, a rescue and a VM without its workspace are killed after")
    }

    @Test func aClusterMachineGetsAMinuteToPowerOff() {
        var node = Self.rec("node"); node.kube = UUID().uuidString
        #expect(Daemon.shutdownGrace(node) == .seconds(60))
        #expect(Daemon.shutdownGrace(Self.rec("w")) == .seconds(20))
    }
}

/// A fat client's forward to an address no VM leases (a MetalLB
/// LoadBalancer IP): relayed through a node of the cluster that owns it.
@Suite("Forwards to LoadBalancer addresses")
struct LoadBalancerRelayTests {
    @Test func theClustersNodeRelaysItsRange() {
        let ws = DrainTests.rec("ws")
        var a = DrainTests.rec("a-1"); a.kube = "AAAA"
        var b = DrainTests.rec("b-1"); b.kube = "bbbb"
        let ranges = [(cluster: "aaaa", range: "192.168.64.200-192.168.64.210"), (cluster: "BBBB", range: "192.168.64.220-192.168.64.230")]
        #expect(Daemon.relayVM(forVMNetIP: "192.168.64.225", running: [ws, a, b], ranges: ranges)?.name == "b-1")
        #expect(Daemon.relayVM(forVMNetIP: "192.168.64.205", running: [ws, a, b], ranges: ranges)?.name == "a-1")
        #expect(Daemon.relayVM(forVMNetIP: "192.168.64.99", running: [ws, a, b], ranges: ranges)?.name == "a-1", "any node")
        #expect(Daemon.relayVM(forVMNetIP: "192.168.64.99", running: [ws], ranges: ranges)?.name == "ws", "any VM")
        #expect(Daemon.relayVM(forVMNetIP: "192.168.64.99", running: [], ranges: ranges) == nil)
        #expect(Daemon.inSubnet("192.168.64.99", cidr: "192.168.64.0/24"))
        #expect(!Daemon.inSubnet("10.0.0.1", cidr: "192.168.64.0/24"))
        #expect(!Daemon.inSubnet("192.168.64.1", cidr: "bogus"))
    }
}
