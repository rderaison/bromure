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
    /// A defaults suite of the test's own, removed by `done`.
    static func defaults() throws -> (UserDefaults, done: () -> Void) {
        let name = "acl-subnet-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        return (d, { d.removePersistentDomain(forName: name) })
    }
    static func base(_ gateway: String) -> UInt32 {
        let p = gateway.split(separator: ".").compactMap { UInt32($0) }
        return p[0] << 24 | p[1] << 16 | p[2] << 8
    }

    @Test func aNewInstallGetsAPrivateSubnetItKeeps() throws {
        let (d, done) = try Self.defaults()
        defer { done() }
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
        let (d, done) = try Self.defaults()
        defer { done() }
        #expect(Daemon.chooseWorkspaceGateway(hasVMs: true, defaults: d, hostUsed: []) == "192.168.64.1")
        #expect(d.object(forKey: Daemon.useRandom172DefaultsKey) as? Bool == false, "written once")
        // Its VMs gone later: still the choice it made.
        #expect(Daemon.chooseWorkspaceGateway(hasVMs: false, defaults: d, hostUsed: []) == "192.168.64.1")
        #expect(Daemon.subnetCIDR(gateway: "192.168.64.1") == "192.168.64.0/24")
    }

    @Test func anOptInMovesIt() throws {
        let (d, done) = try Self.defaults()
        defer { done() }
        d.set(false, forKey: Daemon.useRandom172DefaultsKey)
        #expect(Daemon.chooseWorkspaceGateway(hasVMs: true, defaults: d, hostUsed: []) == "192.168.64.1")
        d.set(true, forKey: Daemon.useRandom172DefaultsKey)
        #expect(Daemon.chooseWorkspaceGateway(hasVMs: true, defaults: d, hostUsed: []).hasPrefix("172."))
    }
}

/// While VMs run on a subnet (an adopted passt, running records), the daemon
/// starts on it: a changed choice waits for a start with none running.
@Suite("Workspace subnet in use")
struct WorkspaceSubnetInUseTests {
    @Test func aRunningSubnetWins() throws {
        #expect(Daemon.gatewayToUse(chosen: "172.23.5.1", inUse: "192.168.64.1") == "192.168.64.1", "deferred")
        #expect(Daemon.gatewayToUse(chosen: "172.23.5.1", inUse: nil) == "172.23.5.1")
        #expect(Daemon.gatewayToUse(chosen: "172.23.5.1", inUse: "172.23.5.1") == "172.23.5.1")
        #expect(Daemon.gatewayToUse(chosen: "172.23.5.1", inUse: "192.168.64.1", vmsRunning: false) == "192.168.64.1",
                "a taken-back passt keeps its -a/-g")
    }

    @Test func thePasstsOwnGateway() {
        let argv = ["/usr/bin/passt", "--vhost-user", "-a", "172.23.5.2", "-n", "24", "-g", "172.23.5.1", "-M", "9a:55:9a:55:9a:55"]
        #expect(Daemon.passtGateway(argv: argv) == "172.23.5.1")
        #expect(Daemon.passtGateway(argv: ["/usr/bin/passt"]) == nil)
    }

    @Test func runningRecordsLeases() throws {
        let dir = try shortTempDir()
        let path = dir + "/vms.json"
        var reg = VMRegistry(path: path, isAlive: { _ in true })
        var stopped = RepairMarksTests.stopped(UUID().uuidString.lowercased())
        stopped.ip = "10.9.9.9"
        try reg.upsert(stopped)
        #expect(VMRegistry.runningGateway(path: path, isAlive: { _ in true }) == nil, "a stopped VM's old lease doesn't hold the subnet")
        var running = RepairMarksTests.stopped(UUID().uuidString.lowercased())
        running.state = .running
        running.ip = "192.168.64.7"
        try reg.upsert(running)
        #expect(VMRegistry.runningGateway(path: path, isAlive: { _ in true }) == "192.168.64.1")
        // After a host reboot or a crash with no fd store: the record says
        // running, but its Firecracker is gone.
        #expect(VMRegistry.runningGateway(path: path, isAlive: { _ in false }) == nil, "a dead VM's record pins nothing")
        #expect(VMRegistry.runningGateway(path: path, isAlive: Daemon.isOurVM) == nil, "no pid: not alive")
    }

    @Test func aTestDaemonWithTheUsersConfigHomeIsWarned() {
        let home = "/home/someone"
        #expect(Daemon.configHomeWarning(stateDir: "/var/tmp/w/state/bromure-ac",
                                         env: ["HOME": home, "XDG_STATE_HOME": "/var/tmp/w/state"]) != nil)
        #expect(Daemon.configHomeWarning(stateDir: "/var/tmp/w/state/bromure-ac",
                                         env: ["HOME": home, "XDG_STATE_HOME": "/var/tmp/w/state", "XDG_CONFIG_HOME": "/var/tmp/w/config"]) == nil)
        #expect(Daemon.configHomeWarning(stateDir: home + "/.local/state/bromure-ac", env: ["HOME": home]) == nil, "the default")
        // A single-user install with its state outside $HOME: no test's.
        #expect(Daemon.configHomeWarning(stateDir: "/srv/bromure/state/bromure-ac",
                                         env: ["HOME": home, "XDG_STATE_HOME": "/srv/bromure/state"]) == nil)
        #expect(Daemon.configHomeWarning(stateDir: "/scratch/t/state/bromure-ac",
                                         env: ["HOME": home, "XDG_STATE_HOME": "/scratch/t/state", "TMPDIR": "/scratch"]) != nil, "under TMPDIR")
        #expect(Daemon.configHomeWarning(stateDir: "/srv/bromure/state/bromure-ac",
                                         env: ["HOME": home, "XDG_STATE_HOME": "/srv/bromure/state", "TMPDIR": ""]) == nil,
                "an empty TMPDIR is unset, not /")
        // A multi-user daemon: its HOME is its state dir's parent.
        #expect(Daemon.configHomeWarning(stateDir: "/var/lib/bromure-ac/u/bromure-ac",
                                         env: ["HOME": "/var/lib/bromure-ac/u", "XDG_STATE_HOME": "/var/lib/bromure-ac/u"]) == nil)
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
