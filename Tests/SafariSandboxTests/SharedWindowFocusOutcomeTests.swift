import Foundation
import Testing
@testable import SandboxEngine

/// Keyboard input to a shared browser window may only follow a focus reply
/// that shows the guest activated that window.
@Suite("Shared-window focus outcome")
struct SharedWindowFocusOutcomeTests {
    @Test("A confirmed reply is confirmed")
    func confirmed() {
        #expect(SharedWindowFocusOutcome(reply: ["ok": true, "windowId": 7]) == .confirmed)
    }

    @Test("Deadline failures after activation still own the input")
    func activatedUnconfirmed() {
        for error in ["Chromium/X focus did not converge", "focus observation deadline exceeded"] {
            #expect(SharedWindowFocusOutcome(reply: ["ok": false, "error": error]) == .activatedUnconfirmed)
        }
    }

    @Test("Failures before activation leave focus on the previous window")
    func notActivated() {
        for error in ["unknown browser window", "CDP page focus failed",
                      "cannot identify sole CDP browser process", "X focus observation failed: boom",
                      "Chromium/X focus did not converge (and something else)"] {
            #expect(SharedWindowFocusOutcome(reply: ["ok": false, "error": error]) == .notActivated)
        }
        #expect(SharedWindowFocusOutcome(reply: ["ok": false]) == .notActivated)
        #expect(SharedWindowFocusOutcome(reply: [:]) == .notActivated)
        #expect(SharedWindowFocusOutcome(reply: ["ok": "true"]) == .notActivated)
    }
}
