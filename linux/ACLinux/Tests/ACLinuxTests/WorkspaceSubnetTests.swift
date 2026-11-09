import Foundation
import SandboxEngine
import Testing
@testable import ACLinux

/// The workspaces' subnet (macOS AC's launch rule; DaemonSubnet.swift): a
/// persisted random /24 in 172.16/12 for an install that never chose, the
/// historical 192.168.64 for one that has VMs already or opted out. Each
/// case on a defaults suite of its own (nothing persisted for this user).
@Suite("Workspace subnet")
struct WorkspaceSubnetTests {
    static func defaults() throws -> UserDefaults { try #require(UserDefaults(suiteName: "acl-subnet-\(UUID().uuidString)")) }
    static func base(_ gateway: String) -> UInt32 {
        let p = gateway.split(separator: ".").compactMap { UInt32($0) }
        return p[0] << 24 | p[1] << 16 | p[2] << 8
    }

    @Test func aNewInstallGetsAPrivateSubnetItKeeps() throws {
        let d = try Self.defaults()
        let gw = Daemon.chooseWorkspaceGateway(hasVMs: false, defaults: d, hostUsed: [])
        #expect(d.bool(forKey: Daemon.useRandom172DefaultsKey))
        #expect(gw.hasPrefix("172.") && gw.hasSuffix(".1"), "\(gw)")
        let second = (Self.base(gw) >> 16) & 0xFF
        #expect(([16] + Array(21...31)).contains(second), "172.16/12, not Docker's 172.17–20: \(gw)")
        #expect(Daemon.chooseWorkspaceGateway(hasVMs: true, defaults: d, hostUsed: []) == gw, "kept across starts")
        #expect(Daemon.subnetCIDR(gateway: gw) == VMNetSwitch.ipString(Self.base(gw)) + "/24")
        // The host joined that /24 since: another one.
        let moved = Daemon.chooseWorkspaceGateway(hasVMs: true, defaults: d, hostUsed: [Self.base(gw)])
        #expect(moved != gw && moved.hasPrefix("172."))
    }

    @Test func anInstallWithVMsStaysAndSaysSo() throws {
        let d = try Self.defaults()
        #expect(Daemon.chooseWorkspaceGateway(hasVMs: true, defaults: d, hostUsed: []) == "192.168.64.1")
        #expect(d.object(forKey: Daemon.useRandom172DefaultsKey) as? Bool == false, "written once")
        // Its VMs gone later: still the choice it made.
        #expect(Daemon.chooseWorkspaceGateway(hasVMs: false, defaults: d, hostUsed: []) == "192.168.64.1")
        #expect(Daemon.subnetCIDR(gateway: "192.168.64.1") == "192.168.64.0/24")
    }

    @Test func anOptInMovesIt() throws {
        let d = try Self.defaults()
        d.set(false, forKey: Daemon.useRandom172DefaultsKey)
        #expect(Daemon.chooseWorkspaceGateway(hasVMs: true, defaults: d, hostUsed: []) == "192.168.64.1")
        d.set(true, forKey: Daemon.useRandom172DefaultsKey)
        #expect(Daemon.chooseWorkspaceGateway(hasVMs: true, defaults: d, hostUsed: []).hasPrefix("172."))
    }
}

/// Asking whether an install has VMs (the subnet rule) reads the registry
/// and changes nothing: loading one settles running records (stopped, pid
/// gone), which would leave the daemon nothing to re-adopt or end.
@Suite("Registry peek")
struct RegistryPeekTests {
    @Test func hasRecordsLeavesARunningRecordAsItIs() throws {
        let dir = try shortTempDir()
        let path = dir + "/vms.json"
        #expect(!VMRegistry.hasRecords(path: path), "no file: none")
        var rec = RepairMarksTests.stopped(UUID().uuidString.lowercased())
        rec.state = .running
        rec.pid = 4242
        rec.pidStart = 99
        var reg = VMRegistry(path: path, isAlive: { _ in true })
        try reg.upsert(rec)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(VMRegistry.hasRecords(path: path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before, "the file untouched")
    }
}
