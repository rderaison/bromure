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
