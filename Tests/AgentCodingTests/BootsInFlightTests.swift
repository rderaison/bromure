import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-362): Delete workspace (and reset / revert) checked only
/// `runningSessions`, which a boot enters at `registerSession` — after the
/// disk is cloned, prepared and opened. A delete in that window removed the
/// images under the booting VM.
@Suite("A booting workspace's disk is in use")
@MainActor struct BootsInFlightTests {
    @Test("from launch until the boot registers or fails, the disk is in use and a second boot is refused")
    func bootWindow() {
        let boots = BootsInFlight()
        let id = UUID(), other = UUID()
        #expect(!boots.diskInUse(id, running: false))
        #expect(boots.begin(id))
        // Not yet in runningSessions, but booting: delete/reset/revert refuse.
        #expect(boots.diskInUse(id, running: false))
        #expect(boots.contains(id))
        #expect(!boots.begin(id))
        #expect(!boots.diskInUse(other, running: false))
        // Registered (or failed): the boot's mark goes; a running VM still holds it.
        boots.end(id)
        #expect(boots.diskInUse(id, running: true))
        #expect(!boots.diskInUse(id, running: false))
        #expect(boots.begin(id))
    }

    /// Finding (CWE-362): the base-image upgrade and compromise-wipe prompts
    /// are modals, and a boot (an automation's timer) can begin inside one.
    /// "Yes, upgrade" then deleted the disk that boot had just opened.
    @Test("an upgrade or wipe answered after a boot began: no disk touched, harmless answers kept")
    func promptAnsweredAfterBootBegan() {
        // A fresh id: the store's paths for it don't exist, so nothing real
        // is touched either way.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("boots-\(UUID().uuidString)", isDirectory: true)
        let delegate = ACAppDelegate(
            imageManager: UbuntuImageManager(storageDir: tmp, setupDir: tmp), headless: true)
        var p = Profile(name: "w", tool: .claude, authMode: .token)
        #expect(delegate.bootsInFlight.begin(p.id))
        // "Yes" doesn't reset the disk that boot has open — and says so.
        let yes = delegate.applyBaseImageUpgradeAnswer(0, profile: &p, current: "999")
        #expect(yes == .diskInUse(upgradeSkipped: true))
        // Review: "No" / "Remind me later" touch no disk — still recorded,
        // while this launch still stops (the other boot owns it).
        let no = delegate.applyBaseImageUpgradeAnswer(1, profile: &p, current: "999")
        #expect(no == .diskInUse(upgradeSkipped: false))
        #expect(p.baseImageUpgradeDeclinedFor == "999")
        let later = delegate.applyBaseImageUpgradeAnswer(2, profile: &p, current: "999")
        #expect(later == .diskInUse(upgradeSkipped: false))
        #expect(p.baseImageUpgradeRemindAfter != nil && p.baseImageUpgradeDeclinedFor == nil)
        #expect(delegate.wipeCompromised(profile: p) != .wiped)   // unmarked here: nothing erased
        // Once that boot is over, the answer applies.
        delegate.bootsInFlight.end(p.id)
        let after = delegate.applyBaseImageUpgradeAnswer(1, profile: &p, current: "999")
        #expect(after == .applied)
        #expect(p.baseImageUpgradeDeclinedFor == "999")
    }

    /// Finding (CWE-362): a reboot drops the old session from runningSessions
    /// and awaits (boot remedy, settle, prepare/start) before the new one
    /// registers — with no in-use mark, Delete / reset / revert went through
    /// and removed the disk the fresh VM was opening.
    @Test("a reboot's gap holds the disk in use, and its release leaves another boot's mark")
    func relaunchGapHoldsDisk() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("boots-\(UUID().uuidString)", isDirectory: true)
        let delegate = ACAppDelegate(
            imageManager: UbuntuImageManager(storageDir: tmp, setupDir: tmp), headless: true)
        let id = UUID()
        #expect(!delegate.diskInUse(id))
        let release = delegate.holdDiskForRelaunch(id)
        #expect(delegate.diskInUse(id))
        #expect(delegate.bootsInFlight.contains(id))   // runState reads .booting
        // A launch during the gap is refused (one boot per disk).
        #expect(!delegate.bootsInFlight.begin(id))
        release()
        #expect(!delegate.diskInUse(id))
        // Held by a launch already: the reboot's release doesn't end it.
        #expect(delegate.bootsInFlight.begin(id))
        let second = delegate.holdDiskForRelaunch(id)
        second()
        #expect(delegate.diskInUse(id))
    }

    /// Finding (CWE-362): a failed clone-first run deletes its workspace
    /// after a shutdown — but a stop during the boot found no session and
    /// did nothing, so the VM that registered afterwards stayed up for good.
    @Test("a stop asked for during a boot is kept for its registration, and dropped with the boot")
    func stopDuringBootIsDeferred() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("boots-\(UUID().uuidString)", isDirectory: true)
        let delegate = ACAppDelegate(
            imageManager: UbuntuImageManager(storageDir: tmp, setupDir: tmp), headless: true)
        let id = UUID()
        // No boot: nothing to remember.
        await delegate.stopSession(id, action: .shutdown)
        #expect(delegate.bootsInFlight.takeStop(id) == nil)
        // Booting: the stop waits for the registration.
        #expect(delegate.bootsInFlight.begin(id))
        await delegate.stopSession(id, action: .shutdown)
        #expect(delegate.bootsInFlight.takeStop(id) == .shutdown)
        #expect(delegate.bootsInFlight.takeStop(id) == nil)
        // A boot that fails takes its pending stop with it (the next one
        // must not be stopped on arrival).
        await delegate.stopSession(id, action: .suspend)
        delegate.bootsInFlight.end(id)
        #expect(delegate.bootsInFlight.takeStop(id) == nil)
    }

    /// Finding (CWE-362): a detached reboot dropped its mark and called
    /// launch, which then awaited Kimi provisioning (up to 30 s) before
    /// claiming the disk — Delete / reset / revert went through meanwhile.
    @Test("an await before launch claims the disk runs with the disk held")
    func provisioningHoldsDisk() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("boots-\(UUID().uuidString)", isDirectory: true)
        let delegate = ACAppDelegate(
            imageManager: UbuntuImageManager(storageDir: tmp, setupDir: tmp), headless: true)
        let id = UUID()
        var inUseDuring = false
        await delegate.whileHoldingDisk(id) {
            try? await Task.sleep(nanoseconds: 10_000_000)
            inUseDuring = delegate.diskInUse(id)
        }
        #expect(inUseDuring)
        #expect(!delegate.diskInUse(id))
        // Released before the re-entered launch, which claims it again.
        #expect(delegate.bootsInFlight.begin(id))
        delegate.bootsInFlight.end(id)

        // Review: a Shutdown during the hold was kept for a registration
        // that never came — ending the hold dropped it and the boot stayed
        // up. It comes back to the caller, which then doesn't boot.
        let stop = await delegate.whileHoldingDisk(id) {
            await delegate.stopSession(id, action: .shutdown)
        }
        #expect(stop == .shutdown)
        #expect(delegate.bootsInFlight.takeStop(id) == nil)
        #expect(!delegate.diskInUse(id))
        // Held by another boot: its stop isn't taken from it.
        #expect(delegate.bootsInFlight.begin(id))
        _ = delegate.bootsInFlight.deferStop(id, action: .suspend)
        let none = await delegate.whileHoldingDisk(id) {}
        #expect(none == nil)
        #expect(delegate.bootsInFlight.takeStop(id) == .suspend)
    }
}

/// Finding (CWE-362): "Confirmed compromise wipe is dropped with no notice
/// when the disk is already open". "Wipe and Launch" with a boot that began
/// while the question was up: the wipe is (rightly) refused, but it came
/// back as Cancel, so the dialog just closed and the launch looked done.
@Suite("Compromise wipe: confirmed but refused is not Cancel")
@MainActor
struct CompromiseWipeOutcomeTests {
    @Test("cancel, wiped, and confirmed-but-the-disk-is-open are three different answers")
    func outcomes() {
        final class Calls: @unchecked Sendable { var n = 0 }
        let calls = Calls()
        #expect(ACAppDelegate.compromiseWipe(confirmed: false, wiped: { calls.n += 1; return .wiped }) == .cancelled)
        #expect(calls.n == 0)                                   // Cancel never wipes
        #expect(ACAppDelegate.compromiseWipe(confirmed: true, wiped: { .wiped }) == .wiped)
        #expect(ACAppDelegate.compromiseWipe(confirmed: true, wiped: { .diskInUse }) == .diskInUse)
    }

    @Test("the notice says nothing was wiped and how to retry")
    func notice() {
        let (title, message) = ACAppDelegate.wipeSkippedParts("api")
        #expect(title.contains("api") && title.contains("wasn't wiped"))
        #expect(message.contains("still marked compromised") && message.contains("start it again"))
    }
}
