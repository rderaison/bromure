import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-670): "A refused remote sign-in ends without telling the fat
/// client". The host ended a fat client's sign-in (a refused local/private
/// page, a timeout, a CLI that never started) with its reason in a notice on
/// its own window; `/state` just dropped the run. The Register button's
/// client saw a normal end, and a session card stayed on "Sign-in started —
/// your browser will open shortly…" for good, Sign in disabled.
@MainActor
@Suite("A remote sign-in's end reaches the fat client")
struct RemoteSignInEndTests {
    private static func src(_ p: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8)
    }

    @Test("the host keeps how a run ended, under its id, for a while after it left /state")
    func brokerKeepsTheEnd() throws {
        let b = RemoteRegistrationBroker()
        let t0 = Date()
        let id = b.begin(provider: "Claude")
        #expect(b.stateDict()?["id"] as? String == id.uuidString)
        #expect(b.endedDict(now: t0) == nil)
        b.finish(success: false, message: "refused", now: t0)
        #expect(b.stateDict() == nil)
        let ended = try #require(b.endedDict(now: t0.addingTimeInterval(5)))
        #expect(ended["id"] as? String == id.uuidString)
        #expect(ended["success"] as? Bool == false)
        #expect(ended["message"] as? String == "refused")
        #expect(b.endedDict(now: t0.addingTimeInterval(RemoteRegistrationBroker.endedKeptFor + 1)) == nil)
        // A local run (no pending) leaves the last remote end alone.
        b.finish(success: true, now: t0)
        #expect(b.ended?.id == id && b.ended?.message == "refused")
        // The next run is told apart.
        let next = b.begin(provider: "Claude")
        #expect(next != id)
        b.finish(success: true, now: t0)
        #expect(b.endedDict(now: t0)?["id"] as? String == next.uuidString)
        #expect(b.endedDict(now: t0)?["success"] as? Bool == true)
    }

    @Test("the client tells the run's starter how it ended, once, even when the end came first")
    func clientHearsTheEnd() {
        let c = RemoteHostController(host: RemoteHost(name: "t", address: "127.0.0.1", port: 1, user: "nobody"))
        var heard: [(Bool, String?)] = []
        c.awaitRegistration("A") { heard.append(($0, $1)) }
        c.applyRegistrationEnded(["id": "B", "success": true])   // another client's run
        #expect(heard.isEmpty)
        c.applyRegistrationEnded(["id": "A", "success": false, "message": "refused"])
        c.applyRegistrationEnded(["id": "A", "success": false, "message": "refused"])   // the next poll
        #expect(heard.count == 1 && heard.first?.0 == false && heard.first?.1 == "refused")
        // The reply naming the run came after the poll that ended it.
        c.applyRegistrationEnded(["id": "C", "success": false, "message": "late"])
        var late: String?
        c.awaitRegistration("C") { _, m in late = m }
        #expect(late == "late")
    }

    @Test("every remote failure carries its reason into the end")
    func hostFailuresSayWhy() throws {
        let r = try Self.src("Sources/AgentCoding/ClaudeRegistrationCoordinator.swift")
        let fail = try #require(r.range(of: "func failClaudeRegistration(_ message: String) {"))
        let failBody = r[fail.upperBound...].prefix(500)
        #expect(failBody.contains("teardownClaudeRegistration(reason: .failure, message: message)"))
        #expect(r.contains("RemoteRegistrationBroker.shared.finish(success: reason == .success, message: message)"))
        // VM start, CLI launch and timeout failures too.
        #expect(r.contains("self.teardownClaudeRegistration(reason: .failure, message: message)\n                return"))
        #expect(r.contains("teardownClaudeRegistration(reason: .failure, message: message)\n            return"))
        #expect(r.contains("self.teardownClaudeRegistration(reason: .timeout, message: late)"))
        let server = try Self.src("Sources/AgentCoding/AutomationServer.swift")
        #expect(server.contains("d[\"registrationEnded\"] = ended"))
        #expect(server.contains("reply[\"registration\"] = run"))
    }

    @Test("a fat client's session card and Register button hear the end")
    func clientWiring() throws {
        let ac = try Self.src("Sources/AgentCoding/BromureAC.swift")
        let signin = try #require(ac.range(of: "case (let sid?, \"signin\"):"))
        let route = ac[signin.upperBound...].prefix(2600)
        #expect(route.contains("guard case .finished(let ok, let message) = event else { return }"))
        #expect(route.contains("return [\"ok\": true, \"registration\": run.uuidString]"))
        let fc = try Self.src("Sources/AgentCoding/FatClientController.swift")
        #expect(fc.contains("applyRegistrationEnded(snapshot[\"registrationEnded\"] as? [String: Any])"))
        let card = try #require(fc.range(of: "events(.status(NSLocalizedString(\"Sign-in started — your browser will open shortly…\""))
        let after = fc[card.upperBound...].prefix(1200)
        #expect(after.contains("self?.controller.sessionRequest(s.id, \"signin\")"))
        #expect(after.contains("events(.finished(success: ok, message: message))"))
        #expect(!fc.contains("self.controller.sessionCommand(s.id, \"signin\")"))
        let button = try #require(fc.range(of: "guard a.runModal() == .alertFirstButtonReturn else { return }"))
        #expect(fc[button.upperBound...].prefix(1000).contains("failed.beginSheetModal(for: self)"))
    }
}
