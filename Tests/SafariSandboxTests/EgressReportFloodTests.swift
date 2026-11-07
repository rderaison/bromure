import Foundation
import Testing
@testable import SandboxEngine

/// The switch reports each new destination once a minute. A guest that opens
/// connections to endless fresh destinations can't grow that bookkeeping
/// without bound, and a repeat within the minute is still folded.
@Suite("Egress reports under a flood of fresh destinations")
struct EgressReportFloodTests {
    @Test("the dedupe table stays capped, and a repeat is still folded")
    func capped() {
        let sw = VMNetSwitch()          // never attaches, so vmnet never starts
        let reports = LockedCounter()
        sw.setEgressObserver { _ in reports.add() }
        let total = VMNetSwitch.egressSeenCap + 5_000
        for i in 0..<total {
            sw.fireEgress(portID: 1, profileID: nil, dstIP: 0x0A00_0000 | UInt32(i), hostnames: [],
                          proto: 6, port: 443, denied: true, policy: nil)
        }
        #expect(sw.egressSeenCount <= VMNetSwitch.egressSeenCap)
        #expect(reports.value == total)
        sw.fireEgress(portID: 1, profileID: nil, dstIP: 0x0A00_0000 | UInt32(total - 1), hostnames: [],
                      proto: 6, port: 443, denied: true, policy: nil)
        #expect(reports.value == total)   // the same flow again within the minute: folded
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
