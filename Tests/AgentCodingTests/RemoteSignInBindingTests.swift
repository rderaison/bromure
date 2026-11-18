import Foundation
import Testing
@testable import bromure_ac

/// Finding CWE-345, "Remote sign-in opens another client's prefilled
/// device-code URL after a rejected request": a fat client trusted the
/// provider it ASKED for, before the host answered and for whatever run
/// /state showed next. Now only the run the host accepted for this client
/// -- by its id -- opens its device page unasked.
@Suite("Remote sign-in: bound to the run this client started")
@MainActor
struct RemoteSignInBindingTests {
    private func controller() -> RemoteHostController {
        RemoteHostController(host: RemoteHost(name: "t", address: "127.0.0.1", port: 1, user: "nobody"))
    }
    private let page = URL(string: "https://portal.nousresearch.com/manage-subscription?user_code=84RM-5NER")!
    private func gate(_ c: RemoteHostController, _ reg: [String: Any]) -> GuestURLGate.Disposition {
        GuestURLGate.disposition(for: page, signInFor: c.signInFor(pendingRegistration: reg))
    }

    @Test("an accepted run opens its own device page; another run's asks")
    func accepted() {
        let c = controller()
        c.adoptRegistrationReply(run: "run-1", provider: "hermes")
        #expect(gate(c, ["id": "run-1", "provider": "Nous Portal", "url": page.absoluteString]) == .open)
        #expect(gate(c, ["id": "run-2", "provider": "Nous Portal", "url": page.absoluteString]) == .ask)
        #expect(gate(c, ["provider": "Nous Portal", "url": page.absoluteString]) == .ask, "no id: not ours")
    }

    @Test("a refused request (another client's run in flight) binds nothing")
    func refused() {
        let c = controller()
        c.adoptRegistrationReply(run: nil, provider: "hermes")
        #expect(c.ownRegistration == nil)
        #expect(gate(c, ["id": "theirs", "url": page.absoluteString]) == .ask)
        // A later refusal drops an earlier binding too.
        c.adoptRegistrationReply(run: "run-1", provider: "hermes")
        c.adoptRegistrationReply(run: nil, provider: "hermes")
        #expect(gate(c, ["id": "run-1", "url": page.absoluteString]) == .ask)
    }

    @Test("the binding ends with its run")
    func endsWithRun() {
        let c = controller()
        c.adoptRegistrationReply(run: "run-1", provider: "hermes")
        c.applyRegistrationEnded(["id": "run-2", "success": true])
        #expect(c.ownRegistration?.id == "run-1", "another run's end leaves it")
        c.applyRegistrationEnded(["id": "run-1", "success": false])
        #expect(c.ownRegistration == nil)
        #expect(gate(c, ["id": "run-1", "url": page.absoluteString]) == .ask)
    }

    /// Finding "Early state poll permanently suppresses this client's
    /// device-code page": /state can show this client's run before the
    /// host's reply binds it. That poll must hold the page back, not mark it
    /// opened -- the next poll, after the reply, opens it (once).
    @Test("a page refused before the host's reply opens once the reply binds its run")
    func earlyPoll() {
        let c = controller()
        let reg: [String: Any] = ["id": "run-1", "provider": "Nous Portal", "url": page.absoluteString]
        #expect(c.registrationPage(reg) == .refused, "not bound yet")
        #expect(c.registrationPage(reg) == .refused)
        c.adoptRegistrationReply(run: "run-1", provider: "hermes")
        #expect(c.registrationPage(reg) == .open(page))
        #expect(c.registrationPage(reg) == RemoteHostController.RegistrationPage.none, "opened once")
        #expect(c.registrationPage(["id": "run-1", "provider": "Nous Portal"]) == RemoteHostController.RegistrationPage.none, "no URL")
    }

    @Test("another client's run stays refused, however often /state shows it")
    func othersStayRefused() {
        let c = controller()
        c.adoptRegistrationReply(run: "run-1", provider: "hermes")
        let theirs: [String: Any] = ["id": "run-2", "provider": "Nous Portal", "url": page.absoluteString]
        #expect(c.registrationPage(theirs) == .refused)
        #expect(c.registrationPage(theirs) == .refused)
    }

    @Test("the provider is trusted only after the host's reply, never when the request is sent")
    func notBeforeReply() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let f = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/FatClientController.swift"), encoding: .utf8)
        let fn = try #require(f.range(of: "func beginRemoteRegistration(provider: String, profileID: UUID?,"))
        let body = f[fn.upperBound...].prefix(1400)
        let post = try #require(body.range(of: "\"/subscriptions/register\""))
        let adopt = try #require(body.range(of: "self.adoptRegistrationReply(run:"))
        #expect(post.lowerBound < adopt.lowerBound)
        #expect(!body[..<post.lowerBound].contains("ownRegistration"))
    }
}
