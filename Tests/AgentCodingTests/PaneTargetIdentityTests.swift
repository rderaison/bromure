import Foundation
import Testing
@testable import bromure_ac

/// Finding: the typing guard accepted the session's title as its tab's
/// identity on VMs — another tab wearing that title took the notice,
/// resume text or relaunch line.
@Suite("Typing target: whose tab it is")
@MainActor
struct PaneTargetIdentityTests {

    private func session(title: String, launch: String, windowID: String?) -> AgentSession {
        var s = AgentSession(profileID: UUID(), tool: .claude, title: title, cwd: "/tmp/w")
        s.windowIndex = 3
        s.launchDisplay = launch
        s.windowID = windowID
        return s
    }

    @Test("a VM session's tab is known by its launch name only, whatever its title")
    func vmLaunchNameOnly() throws {
        for id in ["@7", nil] as [String?] {
            let t = try #require(AgentSessionEngine.paneTarget(
                session(title: "Refactor the parser", launch: "claude-1", windowID: id), onMachine: false))
            #expect(t.expectDisplay == "claude-1")
            #expect(t.expectDisplayAlt == nil)
            #expect(!PaneTypeGuard.guardFunction(t).contains("Refactor the parser"))
        }
    }

    @Test("a renamed Sidecar session's tab may carry its title, but only in the window the probe stamped")
    func sidecarTitlePinned() throws {
        let pinned = try #require(AgentSessionEngine.paneTarget(
            session(title: "Renamed", launch: "claude-1", windowID: "@7"), onMachine: true))
        #expect(pinned.expectDisplayAlt == "Renamed")
        #expect(pinned.expectWindowID == "@7")
        // Just rebound (no id yet): by index, the title is no identity.
        let byIndex = try #require(AgentSessionEngine.paneTarget(
            session(title: "Renamed", launch: "claude-1", windowID: nil), onMachine: true))
        #expect(byIndex.expectDisplayAlt == nil)
        #expect(byIndex.expectDisplay == "claude-1")
    }
}
