import Foundation
import Testing
@testable import bromure_ac

/// "Nous login (possibly all of them) can't be cancelled": closing a fat
/// client's sign-in machine window left the run going on the host, holding
/// its one sign-in slot -- the next workspace's sign-in was refused as
/// "already in progress" until the credential wait ran out.
@Suite("Remote sign-in: cancel")
@MainActor
struct RemoteSignInCancelTests {
    private static func src(_ path: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(path), encoding: .utf8)
    }
    private func controller() -> RemoteHostController {
        RemoteHostController(host: RemoteHost(name: "t", address: "127.0.0.1", port: 1, user: "nobody"))
    }

    @Test("a client cancels only the run it started")
    func ownRunOnly() {
        let c = controller()
        c.cancelOwnRegistration()
        #expect(c.cancelledRegistrations.isEmpty, "no run of its own: nothing to cancel")
        c.adoptRegistrationReply(run: "run-1", provider: "hermes", request: 1)
        c.cancelOwnRegistration()
        #expect(c.cancelledRegistrations == ["run-1"])
    }

    @Test("closing the sign-in window cancels; the flow closing it doesn't")
    func windowClose() throws {
        let fc = try Self.src("Sources/AgentCoding/FatClientController.swift")
        let reap = try #require(fc.range(of: "private func reapRegistrationTerminal() {"))
        let body = String(fc[reap.upperBound...].prefix(400))
        #expect(body.contains("if !registrationTerminalClosedByFlow { controller.cancelOwnRegistration() }"))
        #expect(fc.contains("registrationTerminalClosedByFlow = true\n        registrationTerminalWindow?.close()"))
        // A cancelled run's end raises no "didn't complete" alert.
        #expect(fc.contains("if !ok, self?.cancelledRegistrations.remove(run) != nil { return }"))
    }

    @Test("the host ends the named run, and only that one")
    func host() throws {
        let server = try Self.src("Sources/AgentCoding/AutomationServer.swift")
        #expect(server.contains("case (\"POST\", \"/subscriptions/cancel\"):"))
        let app = try Self.src("Sources/AgentCoding/BromureAC.swift")
        let hook = try #require(app.range(of: "server.onCancelRegistration = { [weak self] run in"))
        let body = String(app[hook.upperBound...].prefix(500))
        #expect(body.contains("RemoteRegistrationBroker.shared.pending?.id.uuidString == run"))
        #expect(body.contains("self.teardownClaudeRegistration(reason: .cancelled)"))
    }
}
