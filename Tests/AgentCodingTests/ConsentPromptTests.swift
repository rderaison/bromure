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
}
