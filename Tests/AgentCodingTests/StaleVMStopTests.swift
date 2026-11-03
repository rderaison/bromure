import Foundation
import Testing
@testable import bromure_ac

/// Board report: resuming a suspended workspace on Ark came back "off",
/// the next start shut down too, the third stayed up. A failed restore's
/// VM, and each VM torn down after it, reported its stop late — and the
/// stop handler ended whatever session the workspace had by then, keyed by
/// the workspace, not by the VM that stopped. Each one killed the next boot.
@Suite("A VM's stop ends only its own session")
struct StaleVMStopTests {
    private final class Box {}

    @Test("an earlier sandbox's late stop leaves the running one alone")
    func earlierStopIgnored() {
        let first = Box(), second = Box()
        // The boot that's running stops: its session ends.
        #expect(ACAppDelegate.stopEndsSession(of: second, current: second))
        // The one it replaced stops late: the running boot stays.
        #expect(!ACAppDelegate.stopEndsSession(of: first, current: second))
        // A boot still on its way (no session yet) stopping: it ends.
        #expect(ACAppDelegate.stopEndsSession(of: first, current: nil))
    }
}
