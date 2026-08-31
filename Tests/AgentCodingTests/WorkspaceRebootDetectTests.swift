import Foundation
import Testing
@testable import bromure_ac

/// The fat client rebuilds a workspace's attached browser when it detects the
/// workspace VM rebooted, inferred from the mirrored `uptimeSeconds` resetting
/// (its derived boot time jumping forward). Guards against false positives —
/// steady running, poll jitter, and clock-offset drift must NOT read as a
/// reboot, or the browser pane would spuriously rebuild.
@Suite("Workspace reboot detection")
struct WorkspaceRebootDetectTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Uptime reset (boot time jumps well forward) = reboot")
    func rebootDetected() {
        // Was up ~1h (boot 3600s ago); now up ~2s (boot ≈ now) → big forward jump.
        let prev = now.addingTimeInterval(-3600)
        let fresh = now.addingTimeInterval(-2)
        #expect(RemoteHostController.uptimeDidReset(prevBoot: prev, newBoot: fresh))
    }

    @Test("Steady running (boot time ~constant) is NOT a reboot")
    func steadyRunning() {
        // Each poll derives ~the same boot time (uptime grows in lockstep with now).
        let prev = now.addingTimeInterval(-3600)
        #expect(!RemoteHostController.uptimeDidReset(prevBoot: prev, newBoot: prev))
        #expect(!RemoteHostController.uptimeDidReset(prevBoot: prev,
                                                     newBoot: prev.addingTimeInterval(1)))
    }

    @Test("Small forward jitter / clock drift under the floor is NOT a reboot")
    func jitterIgnored() {
        let prev = now.addingTimeInterval(-600)
        #expect(!RemoteHostController.uptimeDidReset(prevBoot: prev,
                                                     newBoot: prev.addingTimeInterval(3)))
        #expect(!RemoteHostController.uptimeDidReset(prevBoot: prev,
                                                     newBoot: prev.addingTimeInterval(19)))
        // Just past the floor counts (a real, if short-lived, uptime reset).
        #expect(RemoteHostController.uptimeDidReset(prevBoot: prev,
                                                    newBoot: prev.addingTimeInterval(21)))
    }

    @Test("A backward drift (boot time earlier) is never a reboot")
    func backwardNotReboot() {
        let prev = now
        #expect(!RemoteHostController.uptimeDidReset(prevBoot: prev,
                                                     newBoot: prev.addingTimeInterval(-100)))
    }
}
