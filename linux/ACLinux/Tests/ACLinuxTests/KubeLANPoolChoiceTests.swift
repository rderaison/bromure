import Foundation
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
}
