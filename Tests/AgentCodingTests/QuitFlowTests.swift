import Testing
@testable import bromure_ac

/// QH-2: AppKit refuses to terminate while any window has a sheet attached,
/// and it does so silently. The delegate is never asked and the quit Apple
/// Event fails with -128. These tests pin the decisions that keep every quit
/// request answered.
@Suite("QuitFlow: quit request state machine")
struct QuitFlowTests {
    @Test("Idle with no sheet: plain terminate (applicationShouldTerminate confirms)")
    func idleNoSheet() {
        #expect(QuitFlow.request(phase: .idle, attachedSheets: 0) == .terminate)
    }

    @Test("Idle with a sheet attached: confirm first, then dismiss the sheets")
    func idleWithSheet() {
        #expect(QuitFlow.request(phase: .idle, attachedSheets: 1) == .confirmThenDismissSheets)
        #expect(QuitFlow.request(phase: .idle, attachedSheets: 3) == .confirmThenDismissSheets)
    }

    @Test("A Quit while the confirmation is up brings it forward instead of stacking")
    func repeatWhileConfirming() {
        #expect(QuitFlow.request(phase: .confirming, attachedSheets: 0) == .refrontConfirmation)
        #expect(QuitFlow.request(phase: .confirming, attachedSheets: 2) == .refrontConfirmation)
    }

    @Test("A Quit while draining waits for the pending quit (never cancels it)")
    func repeatWhileDraining() {
        #expect(QuitFlow.request(phase: .draining, attachedSheets: 0) == .awaitDrain)
        #expect(QuitFlow.request(phase: .draining, attachedSheets: 1) == .awaitDrain)
    }

    @Test("applicationShouldTerminate: confirmed + work running → terminateLater")
    func confirmedWithWork() {
        #expect(QuitFlow.shouldTerminate(phase: .idle, confirmed: true, workRunning: true) == .later)
    }

    @Test("applicationShouldTerminate: confirmed + nothing running → terminateNow")
    func confirmedIdle() {
        #expect(QuitFlow.shouldTerminate(phase: .idle, confirmed: true, workRunning: false) == .now)
    }

    @Test("applicationShouldTerminate: Cancel → terminateCancel")
    func userCancelled() {
        #expect(QuitFlow.shouldTerminate(phase: .idle, confirmed: false, workRunning: true) == .cancel)
        #expect(QuitFlow.shouldTerminate(phase: .idle, confirmed: false, workRunning: false) == .cancel)
    }

    @Test("A terminate asked while one is in progress never starts a second quit")
    func reentrantTerminate() {
        for phase in [QuitFlow.Phase.confirming, .draining] {
            #expect(QuitFlow.shouldTerminate(phase: phase, confirmed: true, workRunning: true) == .cancel)
            #expect(QuitFlow.shouldTerminate(phase: phase, confirmed: true, workRunning: false) == .cancel)
        }
    }

    /// Walk the whole menu-Quit sequence with a sheet up and a VM running,
    /// the way the delegate drives it: confirm, dismiss sheets, terminate
    /// pre-confirmed, drain, then a second Quit during the drain.
    @Test("Sheet up + VM running: one confirmation, then drain; a repeat Quit waits")
    func fullSequence() {
        var phase = QuitFlow.Phase.idle
        #expect(QuitFlow.request(phase: phase, attachedSheets: 1) == .confirmThenDismissSheets)
        phase = .confirming
        #expect(QuitFlow.request(phase: phase, attachedSheets: 1) == .refrontConfirmation)
        phase = .idle   // the user clicked Quit, the sheets are dismissed
        // terminate → applicationShouldTerminate, pre-confirmed
        #expect(QuitFlow.shouldTerminate(phase: phase, confirmed: true, workRunning: true) == .later)
        phase = .draining
        #expect(QuitFlow.request(phase: phase, attachedSheets: 0) == .awaitDrain)
    }
}
