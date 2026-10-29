import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-667): "A reboot's lease pin never lapses if the clock steps
/// backward". The pin's deadline was a wall-clock Date, judged after a
/// monotonic sleep: set the clock back past the sleep's 1 s of slack and the
/// wake found the pin "live", did nothing, and nothing ran again -- the lease
/// stayed until the process quit, and the other Bromure process refused the
/// workspace. Deadline and sleep now share ContinuousClock.
@Suite("Reboot lease pins lapse on the clock they sleep on")
struct LeasePinClockTests {
    @Test("live until its deadline, lapsed after; the wake clears only its own pin")
    func lifecycle() {
        var pins = LeasePins()
        let id = UUID(), t0 = ContinuousClock.now
        let d1 = pins.pin(id, for: 600, now: t0)
        #expect(pins.isLive(id, now: t0))
        #expect(pins.isLive(id, now: t0.advanced(by: .seconds(599))))
        #expect(!pins.isLive(id, now: t0.advanced(by: .seconds(600))))
        // The wake at its deadline: the pin is still this one, so it goes.
        let firstWake = pins.lapse(id, deadline: d1)
        #expect(firstWake)
        #expect(!pins.isLive(id, now: t0))
        // A re-pin (a second reboot) outlives the first wake.
        let d2 = pins.pin(id, for: 600, now: t0.advanced(by: .seconds(10)))
        let staleWake = pins.lapse(id, deadline: d1)
        #expect(!staleWake)
        #expect(pins.isLive(id, now: t0.advanced(by: .seconds(11))))
        // A boot's acquire takes it over: its wake does nothing.
        pins.clear(id)
        let takenOverWake = pins.lapse(id, deadline: d2)
        #expect(!takenOverWake)
        #expect(!pins.isLive(id))
    }

    @Test("no wall clock left in the pin: the deadline and the wake's sleep are one clock")
    func oneClock() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        let start = try #require(src.range(of: "    func releaseLeaseIfIdle(_ id: Profile.ID) {"))
        let end = try #require(src.range(of: "    func unpinLease(_ id: Profile.ID) {", range: start.upperBound..<src.endIndex))
        let pinCode = src[start.lowerBound..<end.lowerBound]
        #expect(!pinCode.contains("Date()"))
        #expect(pinCode.contains("Task.sleep(until: until, clock: .continuous)"))
        #expect(pinCode.contains("leasePins.lapse(id, deadline: until)"))
    }
}

/// Finding (CWE-667): "Reboot pin drops the workspace lease while a local
/// prompt is still up". The pin lapsed on a 600 s timer whatever the reboot's
/// launch was doing; a local wipe or base-image alert has no timeout, so the
/// lease went with the alert on screen and the other Bromure process booted
/// its stale copy. Now the wake keeps the pin while a launch question is up
/// for the workspace, or its disk is held, and looks again later.
@Suite("A reboot's pin outlives the launch's questions")
struct LeasePinWaitTests {
    @Test("kept while asking or holding the disk; lapses once the launch gave up")
    func decision() {
        #expect(ACAppDelegate.pinOutlivesWait(questionUp: true, diskInUse: false))
        #expect(ACAppDelegate.pinOutlivesWait(questionUp: false, diskInUse: true))
        #expect(!ACAppDelegate.pinOutlivesWait(questionUp: false, diskInUse: false))
    }

    @Test("the wake re-arms instead of releasing while the launch waits")
    func wiring() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        let start = try #require(src.range(of: "    func pinLease(_ id: Profile.ID) {"))
        let body = src[start.upperBound...].prefix(2000)
        let check = try #require(body.range(of: "Self.pinOutlivesWait(questionUp: self.launchQuestions.isUp(id)"))
        let release = try #require(body.range(of: "self.releaseLeaseIfIdle(id)"))
        let rearm = try #require(body.range(of: "until = self.leasePins.pin(id, for: Self.pinRecheckSeconds)"))
        #expect(check.lowerBound < release.lowerBound && release.lowerBound < rearm.lowerBound)
        #expect(body.contains("while true {"))
        // Every launch prompt before the lease is taken back sits in the gate.
        let launch = try #require(src.range(of: "    func launch(_ profile: Profile, detached: Bool = false,"))
        let toAcquire = src[launch.upperBound...]
        let acquire = try #require(toAcquire.range(of: "WorkspaceLease.acquire(profile.id"))
        let gated = toAcquire[..<acquire.lowerBound]
        #expect(gated.contains("guard launchQuestions.begin(profile.id) else { return }\n            let wipe = confirmWipeAndProceed"))
        #expect(gated.contains("guard launchQuestions.begin(profile.id) else { return }\n                let (title, message) = Self.driftPromptParts"))
    }
}
