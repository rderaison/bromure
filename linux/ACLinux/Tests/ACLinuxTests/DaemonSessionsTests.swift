import Foundation
import Testing
@testable import ACLinux

/// The automation API's sessions on a server: a session is a running
/// workspace (no window); listing, opening, closing and exec as on a Mac.
extension DaemonGlobalSuites {
    @Suite("Automation API: sessions, workspaces, app state", .serialized)
    struct DaemonSessionsTests {
        static func req(_ d: Daemon, _ m: String, _ p: String, _ body: JSONValue = .object([:])) async -> ControlResponse {
            await d.handle(ControlRequest(method: m, path: p, body: body))
        }

        @Test func sessionsAreRunningWorkspaces() async throws {
            try await DaemonGlobalSuites.VMRunTests.withStore { d, _ in
                var p = Profile(name: "sess", tool: .claude, authMode: .token)
                p.closeAction = .shutdown
                p = try ProfileStore().save(p)
                var vm = RepairMarksTests.stopped(p.id.uuidString.lowercased())
                vm.name = "sess"
                try await d.registerForTesting(vm)
                // Stopped: not a session, but a workspace.
                guard case .array(let none)? = await Self.req(d, "GET", "/sessions").body["sessions"] else { Issue.record("no sessions"); return }
                #expect(none.isEmpty)
                #expect(await Self.req(d, "GET", "/sessions/sess").status == 404)
                #expect(await Self.req(d, "DELETE", "/sessions/sess").status == 404, "not running: nothing to close")
                guard case .array(let ws)? = await Self.req(d, "GET", "/workspaces").body["workspaces"] else { Issue.record("no workspaces"); return }
                #expect(ws.contains { $0["id"]?.stringValue?.lowercased() == p.id.uuidString.lowercased() || $0["name"]?.stringValue == "sess" })
                // Open: the boot (here refused by the test hook) fails the call.
                #expect(await Self.req(d, "POST", "/sessions").status == 400, "no profile")
                #expect(await Self.req(d, "POST", "/sessions", ["profile": "nope"]).status == 500)
                #expect(await Self.req(d, "POST", "/sessions", ["profile": "sess"]).status == 500, "its boot failed")
                // Exec in a stopped workspace: the VM's own answer (not running).
                #expect(await Self.req(d, "POST", "/sessions/sess/exec", ["command": "true"]).status == 409)
                #expect(await Self.req(d, "POST", "/sessions/nope/exec", ["command": "true"]).status == 404)
                #expect(await Self.req(d, "PUT", "/sessions/sess").status == 405)
                // App state, headless.
                let s = await Self.req(d, "GET", "/app/state").body
                #expect(s["mainWindowOpen"] == .bool(false) && s["sessionCount"] == .number(0) && s["profileCount"] == .number(1))
            }
        }

        /// macOS's close question: its words, its buttons, Suspend when
        /// nobody answers, Cancel keeps the session.
        @Test func theCloseQuestionIsMacOSs() {
            let (title, message, buttons) = Daemon.closePromptParts(name: "w")
            #expect(title == "Close “w”?")
            #expect(message.hasPrefix("Run in the background keeps the VM running"))
            #expect(buttons == ["Run in the Background", "Suspend", "Shut Down", "Cancel"])
            #expect(Daemon.closeAction(forChoice: 0) == .background && Daemon.closeAction(forChoice: 1) == .suspend)
            #expect(Daemon.closeAction(forChoice: 2) == .shutdown && Daemon.closeAction(forChoice: 3) == nil)
        }
    }
}
