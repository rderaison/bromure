import Testing
@testable import bromure_ac

// The Stop button sends Esc, which doesn't reliably fire Claude's `Stop` hook —
// so the hook-derived `isWorking()` can stay stuck `true` after an interrupt and
// the "Thinking…" cue springs back. WorkingGate suppresses that until the agent
// truly reports idle or the user sends again.
@Suite("Beautified interrupt gate")
struct WorkingGateTests {

    @Test("A stuck 'working' after interrupt stays suppressed")
    func stuckWorkingSuppressed() {
        var g = WorkingGate()
        #expect(g.effective(true) == true)     // normal: agent working

        g.interrupt()                          // user hits Stop
        #expect(g.effective(true) == false)    // hook still says working → suppressed
        #expect(g.effective(true) == false)    // …and stays suppressed across polls
    }

    @Test("The latch releases when the agent finally reports idle")
    func releasesOnIdle() {
        var g = WorkingGate()
        g.interrupt()
        #expect(g.effective(true) == false)    // still stuck-working → suppressed
        #expect(g.effective(false) == false)   // agent reports idle → releases here
        #expect(g.interrupted == false)
        #expect(g.effective(true) == true)     // a later turn shows normally again
    }

    @Test("Sending a new message supersedes a prior stop")
    func userSendReleases() {
        var g = WorkingGate()
        g.interrupt()
        #expect(g.effective(true) == false)
        g.userSent()                           // fresh send
        #expect(g.effective(true) == true)     // working shows immediately
    }
}
