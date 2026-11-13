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

    @Test("Failures after activation still own the input")
    func activatedUnconfirmed() {
        for error in ["Chromium/X focus did not converge", "focus observation deadline exceeded",
                      "CDP page focus failed", "cannot identify sole CDP browser process",
                      "CDP call failed: SystemInfo.getProcessInfo", "X focus observation failed: boom",
                      "Command '['/usr/bin/python3', '/usr/local/bin/shared_windows.py', 'probe-focus']' timed out after 1.5 seconds"] {
            #expect(SharedWindowFocusOutcome(reply: ["ok": false, "error": error]) == .activatedUnconfirmed)
        }
    }

    @Test("Failures before activation leave focus on the previous window")
    func notActivated() {
        for error in ["unknown browser window", "CDP call failed: Target.activateTarget",
                      "CDP control deadline exceeded", "CDP closed",
                      "Chromium/X focus did not converge (and something else)"] {
            #expect(SharedWindowFocusOutcome(reply: ["ok": false, "error": error]) == .notActivated)
        }
        #expect(SharedWindowFocusOutcome(reply: ["ok": false]) == .notActivated)
        #expect(SharedWindowFocusOutcome(reply: [:]) == .notActivated)
        #expect(SharedWindowFocusOutcome(reply: ["ok": "true"]) == .notActivated)
    }

    @Test("A current guest's activation flag decides, whatever the message")
    func activationFlag() {
        #expect(SharedWindowFocusOutcome(reply: ["ok": false, "focusActivated": true,
                                                 "error": "CDP control deadline exceeded"]) == .activatedUnconfirmed)
        #expect(SharedWindowFocusOutcome(reply: ["ok": false, "focusActivated": false,
                                                 "error": "Chromium/X focus did not converge"]) == .notActivated)
        #expect(SharedWindowFocusOutcome(reply: ["ok": true, "focusActivated": false]) == .confirmed)
    }
}
