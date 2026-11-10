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

extension DaemonGlobalSuites {
    /// A guest that can't be reached is named by its VM's state (macOS:
    /// guestUnavailableError): the file explorer says "The VM is off".
    @Suite("Guest unavailable wording", .serialized)
    struct GuestUnavailableTests {
        @Test func theErrorNamesTheVMsState() async throws {
            let (d, rec, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let pid = try #require(UUID(uuidString: rec.id))
            do { _ = try await d.guestExec(profileID: pid, command: "true"); Issue.record("ran") }
            catch { #expect("\(error)".contains("The VM is off")) }
            var s = rec; s.state = .suspended
            try await d.registerForTesting(s)
            do { _ = try await d.guestExec(profileID: pid, command: "true"); Issue.record("ran") }
            catch { #expect("\(error)".contains("The VM is suspended")) }
            await d.shutdown()
        }
    }
}

extension DaemonGlobalSuites {
    /// The default SSH key (macOS: made at launch): in the daemon's state
    /// directory, once, and the template carries its public key.
    @Suite("Default SSH key", .serialized)
    struct DefaultSSHKeyTests {
        @Test func theKeyIsMadeOnceAndTheTemplateCarriesIt() throws {
            let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
            let before = DefaultSSHKey.directoryOverride
            defer { DefaultSSHKey.directoryOverride = before }
            let store = ProfileStore(rootDir: URL(fileURLWithPath: dir + "/profiles", isDirectory: true))
            Daemon.bootstrapDefaultSSHKey(stateDir: dir, store: store)
            #expect(DefaultSSHKey.directoryURL.path == dir + "/default-ssh")
            let pub = try DefaultSSHKey.publicKeyText()
            #expect(pub.hasPrefix("ssh-ed25519 "))
            #expect(store.loadTemplate().sshPublicKey == pub)
            var st = stat()
            #expect(stat(dir + "/default-ssh", &st) == 0 && st.st_mode & 0o077 == 0, "owner-only")
            Daemon.bootstrapDefaultSSHKey(stateDir: dir, store: store)
            #expect(try DefaultSSHKey.publicKeyText() == pub, "made once")
        }
    }
}
