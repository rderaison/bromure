import Foundation
import Testing
@testable import bromure_ac

/// Fix, Switchboard and Ask-a-session report how a hand-over came back: the
/// hub flashes success only once it went, and a host's refusal over a flag
/// the user hadn't OK'd asks them before a confirmed retry.
@Suite("Finding hand-over replies")
@MainActor
struct HandOverReplyTests {

    @Test("A host reply maps to done, a flag to confirm, or the host's error")
    func fromServer() {
        #expect(HandOverReply.fromServer(status: 200, json: ["ok": true]) == .done)
        #expect(HandOverReply.fromServer(status: 400, json: [
            "error": "its text was flagged…", "flagged": true, "warning": "meta-instruction",
        ]) == .flagged(warning: "meta-instruction"))
        #expect(HandOverReply.fromServer(status: 400, json: ["error": "couldn't start the fix"])
                == .failed("couldn't start the fix"))
        guard case .failed = HandOverReply.fromServer(status: nil, json: [:]) else {
            Issue.record("no answer must read as a failure"); return
        }
        #expect(HandOverReply.fromServer(status: 404, json: ["error": "not found"], olderServer: "update it")
                == .failed("update it"))
    }

    @Test("The hub flashes success only when it went, and asks before retrying a flagged one")
    func hubReport() {
        let hub = AutomationHubModel()
        var retried = false
        let failure: (String) -> String = { "Couldn't start the fix: \($0)" }

        hub.report(.flagged(warning: "meta-instruction"), success: "Fix started", failure: failure,
                   retry: { retried = true })
        #expect(hub.flash == nil)
        #expect(hub.pendingFlagged?.warning == "meta-instruction")
        #expect(!retried)
        hub.pendingFlagged?.go()   // the user's OK
        #expect(retried)

        hub.pendingFlagged = nil
        hub.report(.failed("no Switchboard"), success: "Fix started", failure: failure, retry: {})
        #expect(hub.flash == "Couldn't start the fix: no Switchboard")
        #expect(hub.flashIsError)

        hub.report(.done, success: "Fix started", failure: failure, retry: {})
        #expect(hub.flash == "Fix started")
        #expect(!hub.flashIsError)
    }
}
