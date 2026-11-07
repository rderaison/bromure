import Foundation
import Testing
@testable import bromure_ac

/// Every cluster shares the one LoadBalancer range: deleting a cluster frees
/// it only when no other cluster still holds it.
@Suite("MetalLB range: freed with the last cluster that holds it")
struct MetalLBRangeRefcountTests {
    private let range = "192.168.64.230-192.168.64.249"

    private func cluster(_ range: String?) -> KubeCluster {
        KubeCluster(name: "c", spec: KubeClusterSpec(), metallbRange: range)
    }

    @Test("another cluster holding the range keeps it reserved")
    func heldByAnother() {
        let a = cluster(range), b = cluster(range)
        #expect(KubeClusterEngine.rangeStillHeld(range, byOtherThan: a.id, in: [a, b]))
    }

    @Test("the last holder frees it; a cluster without a range doesn't count")
    func lastHolder() {
        let a = cluster(range), none = cluster(nil)
        #expect(!KubeClusterEngine.rangeStillHeld(range, byOtherThan: a.id, in: [a, none]))
        #expect(!KubeClusterEngine.rangeStillHeld(range, byOtherThan: a.id, in: [a]))
    }
}
