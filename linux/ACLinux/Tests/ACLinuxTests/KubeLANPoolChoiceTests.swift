import Foundation
import Glibc
import Testing
@testable import ACLinux

/// Which LAN addresses a cluster's load balancer may publish through the
/// LAN helper: a shared server's grant (the cluster's lanPool narrowing
/// it); a single-user server's lanPool within its grant, once the helper
/// runs; none otherwise (its pool Services pending, as macOS's without an
/// announcer).
@Suite("Kube LAN pool choice")
struct KubeLANPoolChoiceTests {
    @Test func theGrantTheHelperAndTheClustersPool() {
        let grant: Set<UInt32> = [10, 11, 12]
        // Shared server: the grant, narrowed by the cluster's pool.
        #expect(LinuxKubeHost.lanPool(cluster: [], grant: grant, multiUser: true, helperRunning: true) == [10, 11, 12])
        #expect(LinuxKubeHost.lanPool(cluster: [11, 99], grant: grant, multiUser: true, helperRunning: true) == [11])
        #expect(LinuxKubeHost.lanPool(cluster: [99], grant: grant, multiUser: true, helperRunning: true) == nil)
        #expect(LinuxKubeHost.lanPool(cluster: [], grant: [], multiUser: true, helperRunning: true) == nil)
        // Single-user: the cluster's pool, inside the grant, with the helper.
        #expect(LinuxKubeHost.lanPool(cluster: [12, 11, 99], grant: grant, multiUser: false, helperRunning: true) == [12, 11])
        #expect(LinuxKubeHost.lanPool(cluster: [12], grant: grant, multiUser: false, helperRunning: false) == nil, "no helper")
        #expect(LinuxKubeHost.lanPool(cluster: [99], grant: grant, multiUser: false, helperRunning: true) == nil, "outside the grant")
        #expect(LinuxKubeHost.lanPool(cluster: [], grant: grant, multiUser: false, helperRunning: true) == nil,
                "no lanPool: host listeners, as macOS's")
    }

    /// A single-user server's VMs: another account's pool addresses are
    /// refused (its switch and proxy), this account's own aren't.
    @Test func anotherAccountsPoolIsRefusedOurOwnIsnt() throws {
        let d = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: d) }
        let p = d + "/lan-pools.json"
        let me = try #require(getpwuid(getuid()).map { String(cString: $0.pointee.pw_name) })
        try LANPoolsAdmin.write(LANPoolsFile(grants: [me: ["10.250.0.10"], "root": ["10.250.0.20"]]), to: p)
        let pools = LANPools(path: p)
        let mine = UInt32(10) << 24 | 250 << 16 | 10, theirs = UInt32(10) << 24 | 250 << 16 | 20
        #expect(pools.contains(mine) && pools.contains(theirs), "a shared server's daemons refuse both")
        #expect(pools.containsOther(theirs), "another account's: refused")
        #expect(!pools.containsOther(mine), "this account's own cluster: reachable")
        #expect(!pools.containsOther(UInt32(10) << 24 | 250 << 16 | 30), "no grant: not a pool address")
        // The proxy takes the same rule on a single-user server.
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: d + "/mitm", isDirectory: true))
        #expect(!proxy.blocksHostAddresses)
        #expect(!proxy.refusedDestination(.v4(UInt32(10) << 24 | 250 << 16 | 30)))
    }

    /// An address moved from another account's grant to ours stays refused
    /// the grace (that account's publication may outlive the change).
    @Test func aReassignedAddressStaysRefusedTheGrace() throws {
        let d = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: d) }
        let p = d + "/lan-pools.json"
        let me = try #require(getpwuid(getuid()).map { String(cString: $0.pointee.pw_name) })
        let ip = UInt32(10) << 24 | 250 << 16 | 40
        try LANPoolsAdmin.write(LANPoolsFile(grants: ["root": ["10.250.0.40"]]), to: p)
        let pools = LANPools(path: p)
        #expect(pools.containsOther(ip))
        try LANPoolsAdmin.write(LANPoolsFile(grants: [me: ["10.250.0.40"]]), to: p)
        Thread.sleep(forTimeInterval: 0.6)
        #expect(pools.containsOther(ip), "just moved to us: still refused")
        Thread.sleep(forTimeInterval: 3.1)
        #expect(!pools.containsOther(ip), "ours after the grace")
    }
}
