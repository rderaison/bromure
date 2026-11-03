import Foundation
import Testing
@testable import bromure_ac

/// Non-modal consent prompts: per-workspace queueing, the no-answer-means-no
/// deadline, grant lifetimes measured from the answer, and guardrail
/// approvals scoped to the exact operation. Drives the presenter with a stub
/// UI (no windows). Serialized: the presenter is a process-wide singleton.
@Suite("Consent prompts", .serialized)
@MainActor
struct ConsentPromptTests {

    final class StubUI: ConsentPanelUI {
        func dismiss() {}
    }

    /// Install a stub that records each shown prompt and (optionally) answers
    /// it after `delay` seconds with `choice(request)`.
    private func install(delay: Double? = nil, choice: @escaping (ConsentPanelPresenter.Request) -> Int? = { _ in nil },
                         shown: @escaping (ConsentPanelPresenter.Request) -> Void = { _ in }) {
        ConsentPanelPresenter.shared.makeUI = { req, answer in
            shown(req)
            if let delay {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    answer(choice(req))
                }
            }
            return StubUI()
        }
    }

    @Test("One prompt per workspace on screen; the next shows once it's answered; workspaces don't wait on each other")
    func queueing() async throws {
        install()
        let a = UUID(), b = UUID()
        let p = ConsentPanelPresenter.shared
        async let r1 = p.present(profileID: a, title: "a1", message: "", choices: ["Yes", "No"], denyIndex: 1,
                                 style: .informational, detailText: nil, timeout: 30)
        async let r2 = p.present(profileID: a, title: "a2", message: "", choices: ["Yes", "No"], denyIndex: 1,
                                 style: .informational, detailText: nil, timeout: 30)
        async let r3 = p.present(profileID: b, title: "b1", message: "", choices: ["Yes", "No"], denyIndex: 1,
                                 style: .informational, detailText: nil, timeout: 30)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(Set(p.shownTitles) == ["a1", "b1"])
        #expect(p.openCount == 3)
        #expect(p.answer(profileID: a, choice: 0))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(Set(p.shownTitles) == ["a2", "b1"])
        #expect(p.answer(profileID: a, choice: 1))
        #expect(p.answer(profileID: b, choice: 0))
        let (x, y, z) = await (r1, r2, r3)
        #expect(x == 0 && y == 1 && z == 0)
        #expect(p.openCount == 0)
    }

    @Test("No answer means no: the prompt times out to its deny choice")
    func timeout() async {
        install()
        let t0 = Date()
        let r = await ConsentPanelPresenter.shared.present(
            profileID: UUID(), title: "t", message: "", choices: ["Allow", "Deny"], denyIndex: 1,
            style: .warning, detailText: nil, timeout: 1)
        #expect(r == 1)
        #expect(Date().timeIntervalSince(t0) >= 0.9)
        #expect(ConsentPanelPresenter.shared.openCount == 0)
    }

    @Test("Credential consent: the grant's lifetime starts when the user answers")
    func grantStartsAtAnswer() async {
        install(delay: 1.5, choice: { _ in 1 })   // "Allow for 5 minutes", after 1.5 s
        let broker = ConsentBroker()
        let pid = UUID()
        let opened = Date()
        let ok = await broker.consent(profileID: pid, credentialID: "token:test",
                                      credentialDisplayName: "Test token", scopeHint: "")
        #expect(ok)
        let grant = await broker.snapshot().first { $0.profileID == pid }
        #expect(grant != nil)
        if let g = grant {
            #expect(g.expiration.timeIntervalSince(opened) >= 5 * 60 + 1.4)
        }
    }

    @Test("Guardrail approval covers the exact operation only")
    func exactOperationScope() async {
        var prompts = 0
        install(delay: 0.05, choice: { _ in 0 }, shown: { _ in prompts += 1 })   // "Allow this request for 15 minutes"
        let broker = GuardrailsConsentBroker()
        let pid = UUID()
        func ask(_ method: String, _ path: String, sql: String? = nil) async -> Bool {
            await broker.consent(profileID: pid,
                                 scope: GuardrailsConfig.exactScope("digitalocean", method: method, path: path,
                                                                    amzTarget: nil, formAction: nil, dbQuery: sql),
                                 scopeDisplayName: "DigitalOcean",
                                 operation: GuardrailsConfig.operationDescription(method: method, path: path,
                                                                                  amzTarget: nil, formAction: nil,
                                                                                  dbQuery: sql))
        }
        #expect(await ask("DELETE", "/v2/droplets/1"))
        #expect(prompts == 1)
        #expect(await ask("DELETE", "/v2/droplets/1"))          // same request: the grant covers it
        #expect(prompts == 1)
        #expect(await ask("DELETE", "/v2/droplets/2"))          // a different droplet asks again
        #expect(prompts == 2)
        _ = await ask("POST", "/", sql: "DROP TABLE users")
        _ = await ask("POST", "/", sql: "DROP   TABLE\n users")   // same statement, other whitespace
        #expect(prompts == 3)
        _ = await ask("POST", "/", sql: "DROP TABLE orders")
        #expect(prompts == 4)
    }

    /// Finding (CWE-285): a Guardrails deny made while the agent's prompt was
    /// up was undone by that prompt — "Don't allow" shrank a session deny to
    /// 5 minutes, "Allow" (Return) let the in-flight request through.
    /// Finding (CWE-670): the overtaken panel stayed up holding the key —
    /// after a revoke ("ask next time") its Allow was ignored, and every new
    /// request parked on it and was refused until it timed out.
    @Test("A Guardrails decision overtakes an open prompt: withdrawn, its waiters get the decision, the key is free")
    func guardrailsOvertakesOpenPrompt() async throws {
        install()
        let p = ConsentPanelPresenter.shared
        let broker = ConsentBroker()
        let profile = UUID()
        async let first = broker.consent(profileID: profile, credentialID: "aws",
                                         credentialDisplayName: "AWS", scopeHint: "")
        try await Task.sleep(nanoseconds: 100_000_000)
        async let waiter = broker.consent(profileID: profile, credentialID: "aws",
                                          credentialDisplayName: "AWS", scopeHint: "")
        try await Task.sleep(nanoseconds: 50_000_000)
        await broker.deny(profileID: profile, credentialID: "aws", for: nil, credentialDisplayName: "AWS")
        #expect(await waiter == false)          // answered by the deny, not the prompt
        #expect(await first == false)           // the prompt withdrawn: the deny stands
        #expect(!p.answer(profileID: profile, choice: 0))   // nothing left on screen to Allow
        let deny = await broker.snapshot().first { $0.profileID == profile }
        #expect(deny?.kind == .deny && deny?.isSessionScoped == true)

        // Revoked — "ask next time": the next request asks, and its Allow counts.
        await broker.revoke(profileID: profile, credentialID: "aws")
        async let again = broker.consent(profileID: profile, credentialID: "aws",
                                         credentialDisplayName: "AWS", scopeHint: "")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(p.answer(profileID: profile, choice: 0))   // a fresh prompt, Allow for 1 hour
        #expect(await again == true)
        #expect(await broker.snapshot().first { $0.profileID == profile }?.kind == .allow)

        // A grant made while the prompt is up stands; the prompt goes.
        let other = UUID()
        async let asked = broker.consent(profileID: other, credentialID: "gh",
                                         credentialDisplayName: "GitHub", scopeHint: "")
        try await Task.sleep(nanoseconds: 100_000_000)
        await broker.grant(profileID: other, credentialID: "gh", .allowSession, credentialDisplayName: "GitHub")
        #expect(await asked == true)
        #expect(!p.answer(profileID: other, choice: 3))
        #expect(await broker.snapshot().first { $0.profileID == other }?.kind == .allow)

        // Session teardown with a prompt up: withdrawn and refused; the next
        // session's request asks afresh instead of parking on it.
        let torn = UUID()
        async let pending = broker.consent(profileID: torn, credentialID: "ssh",
                                           credentialDisplayName: "SSH", scopeHint: "")
        try await Task.sleep(nanoseconds: 100_000_000)
        await broker.revokeAll(profileID: torn)
        #expect(await pending == false)
        async let next = broker.consent(profileID: torn, credentialID: "ssh",
                                        credentialDisplayName: "SSH", scopeHint: "")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(p.answer(profileID: torn, choice: 1))       // Allow for 5 minutes
        #expect(await next == true)
        #expect(p.openCount == 0)
    }

    /// Issue #43: a `uv sync` held six unverified packages; when the first
    /// prompt timed out the rest showed at once, all at "0 s", and never
    /// closed. They had been asked together, so they shared a deadline: each
    /// was pumped the instant the one before expired, answered itself from
    /// its first tick before the presenter held it, and was never dismissed.
    @Test("prompts that share a deadline time out without piling up panels")
    func sharedDeadlineNoPileUp() async throws {
        var built = 0
        install(shown: { _ in built += 1 })
        let a = UUID()
        let p = ConsentPanelPresenter.shared
        async let r1 = p.present(profileID: a, title: "1", message: "", choices: ["Allow", "Deny"], denyIndex: 1,
                                 style: .warning, detailText: nil, timeout: 1)
        async let r2 = p.present(profileID: a, title: "2", message: "", choices: ["Allow", "Deny"], denyIndex: 1,
                                 style: .warning, detailText: nil, timeout: 1)
        async let r3 = p.present(profileID: a, title: "3", message: "", choices: ["Allow", "Deny"], denyIndex: 1,
                                 style: .warning, detailText: nil, timeout: 1)
        let (x, y, z) = await (r1, r2, r3)
        #expect(x == 1 && y == 1 && z == 1)
        #expect(built == 1, "\(built) panels built for one that could be answered")
        #expect(p.openCount == 0)
    }

    @Test("a panel answered while it's being built is closed")
    func answeredWhileBuilt() async {
        final class Counting: ConsentPanelUI {
            var dismissed = 0
            func dismiss() { dismissed += 1 }
        }
        let ui = Counting()
        ConsentPanelPresenter.shared.makeUI = { _, answer in
            answer(1)
            return ui
        }
        let r = await ConsentPanelPresenter.shared.present(
            profileID: UUID(), title: "t", message: "", choices: ["Allow", "Deny"], denyIndex: 1,
            style: .warning, detailText: nil, timeout: 30)
        #expect(r == 1)
        #expect(ui.dismissed == 1)
        #expect(ConsentPanelPresenter.shared.openCount == 0)
    }

    /// Issue #43: the unverified-package question — one at a time per
    /// workspace; "this package" covers that version for the session, the
    /// "all" answers settle the packages still waiting without a panel.
    @Test("unverified packages: one question at a time, and an answer for all settles the rest")
    func unverifiedPackages() async throws {
        var shown: [String] = []
        install(shown: { shown.append($0.title) })
        let broker = SupplyChainConsentBroker()
        let ws = UUID()
        await broker.setProfileName("NIST", for: ws)
        let p = ConsentPanelPresenter.shared
        func ask(_ name: String) async -> Bool {
            await broker.consentUnverified(profileID: ws, ecosystem: "pypi", name: name, version: "1.0",
                                           why: "socket.dev hasn't finished analysing this version yet.")
        }
        async let six = ask("six")
        async let werkzeug = ask("werkzeug")
        async let mistune = ask("mistune")
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(shown.count == 1, "\(shown)")
        #expect(p.shownTitles.count == 1)
        // "Allow <first>": only that one; the next question shows.
        #expect(p.answer(profileID: ws, choice: SupplyChainConsentBroker.UnverifiedChoice.allowPackage.rawValue))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(shown.count == 2)
        // "Allow all unverified packages for 15 minutes": the third never asks.
        #expect(p.answer(profileID: ws, choice: SupplyChainConsentBroker.UnverifiedChoice.allowAll15min.rawValue))
        let (a, b, c) = await (six, werkzeug, mistune)
        #expect(a && b && c)
        #expect(shown.count == 2)
        #expect(await ask("pandas"))                      // within the 15 minutes
        #expect(shown.count == 2)

        // "Don't allow unverified packages for the rest of the session".
        let other = UUID()
        func askOther(_ name: String) async -> Bool {
            await broker.consentUnverified(profileID: other, ecosystem: "npm", name: name, version: "2.0", why: "")
        }
        async let first = askOther("left-pad")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(p.answer(profileID: other, choice: SupplyChainConsentBroker.UnverifiedChoice.denyAllSession.rawValue))
        #expect(await first == false)
        #expect(await askOther("is-odd") == false)
        #expect(shown.count == 3)
        // "Allow <package>" is remembered for that package and version only.
        await broker.revokeEverything()
        async let one = askOther("left-pad")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(p.answer(profileID: other, choice: SupplyChainConsentBroker.UnverifiedChoice.allowPackage.rawValue))
        #expect(await one)
        #expect(await askOther("left-pad"))
        #expect(shown.count == 4)
        async let two = askOther("is-even")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(shown.count == 5)
        #expect(p.answer(profileID: other, choice: nil))   // no answer / Esc: refused
        #expect(await two == false)
        #expect(p.openCount == 0)
    }
}
