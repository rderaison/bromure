import Foundation
import Testing
@testable import bromure_ac

/// Finding: deleting the last workspace from a fat client left it in the
/// mirror for good — every later /state listed no workspaces, and the
/// client skipped any empty list as a truncated read, so the row stayed
/// (and the snapshot's sessions, tasks and grid were never applied).
@Suite("Fat client: deleting the last workspace")
@MainActor
struct FatClientLastWorkspaceTests {
    private func controller(with id: UUID) -> RemoteHostController {
        let c = RemoteHostController(host: RemoteHost(name: "t", address: "127.0.0.1", port: 1, user: "nobody"))
        c.applyPushedSnapshot(["workspaces": [["id": id.uuidString, "name": "only", "tool": "claude",
                                               "authMode": "token", "state": "off"]],
                               "vms": [], "workspacesListed": true])
        return c
    }

    @Test("a listed, empty workspaces array removes the last row")
    func emptyListIsReal() {
        let id = UUID()
        let c = controller(with: id)
        #expect(c.profile(for: id) != nil)
        c.applyPushedSnapshot(["workspaces": [] as [[String: Any]], "vms": [], "workspacesListed": true])
        #expect(c.profile(for: id) == nil)
        #expect(c.listModel.profileRows.isEmpty)
        // An older host (no workspacesListed): a present, empty array is real too.
        let d = controller(with: id)
        d.applyPushedSnapshot(["workspaces": [] as [[String: Any]], "vms": []])
        #expect(d.profile(for: id) == nil)
    }

    @Test("a truncated snapshot, or a host that didn't list, keeps the rows")
    func truncatedKeepsRows() {
        let id = UUID()
        let c = controller(with: id)
        c.applyPushedSnapshot(["vms": []])
        #expect(c.profile(for: id) != nil)
        c.applyPushedSnapshot(["workspaces": [] as [[String: Any]], "vms": [], "workspacesListed": false])
        #expect(c.profile(for: id) != nil)
        #expect(c.listModel.profileRows.count == 1)
    }

    /// Finding (CWE-754): with no workspace left, the guard was disarmed —
    /// a truncated poll (`[:]`) wiped the board, the grid and the sessions
    /// stage, and cancelled a sign-in in progress.
    @Test("with no workspace left, a truncated snapshot still keeps the mirror")
    func truncatedKeepsEmptyMirror() {
        let c = controller(with: UUID())
        c.applyPushedSnapshot(["workspaces": [] as [[String: Any]], "vms": [], "workspacesListed": true,
                               "agentSessions": [] as [[String: Any]]])
        #expect(c.listModel.profileRows.isEmpty)
        #expect(c.supportsSessions)
        let rev = c.revision
        c.applyPushedSnapshot([:])
        c.applyPushedSnapshot(["vms": []])
        c.applyPushedSnapshot(["workspaces": [] as [[String: Any]], "workspacesListed": false])
        #expect(c.supportsSessions)
        #expect(c.revision == rev)
    }

    @Test("a successful delete drops the row at once")
    func deleteDropsRow() {
        let id = UUID()
        let c = controller(with: id)
        c.workspaceDeleted(id)
        #expect(c.profile(for: id) == nil)
        #expect(c.listModel.profileRows.isEmpty)
    }

    /// Finding (CWE-672): the deleted workspace's dashboard stayed on stage
    /// (a missing row reads as `.off`), and its Start button POSTed /vms with
    /// the deleted id — which the host took as a new workspace to mint and boot.
    @Test("a deleted workspace is gone: Start sends nothing, and the host refuses its id")
    func deletedCannotStart() {
        let id = UUID(), other = UUID()
        let c = controller(with: id)
        #expect(!c.isGone(id))
        c.workspaceDeleted(id)
        #expect(c.isGone(id))
        #expect(!c.startWorkspace(id))
        // Nothing is "gone" before the first snapshot (still connecting).
        let fresh = RemoteHostController(host: RemoteHost(name: "t", address: "127.0.0.1", port: 1, user: "nobody"))
        #expect(!fresh.isGone(other))
        // The host: an unknown workspace id is a refusal, a name still mints.
        #expect(ACAppDelegate.unknownWorkspaceRefusal(id.uuidString)?["notFound"] as? Bool == true)
        #expect(ACAppDelegate.unknownWorkspaceRefusal("my-new-workspace") == nil)
        #expect(ACAppDelegate.unknownWorkspaceRefusal(nil) == nil)
    }

    /// Finding (CWE-772): deleting a workspace left its browser pane open
    /// (the globe had no id left to close it), its local browser VM booted,
    /// and its browser-MCP relay dialing the deleted id forever. The window
    /// now releases everything a gone workspace still holds.
    @Test("what a deleted workspace still holds is found: its browser, relay and terminals")
    func goneWorkspaceResourcesFound() {
        let gone = UUID(), alive = UUID()
        let c = controller(with: alive)
        c.workspaceDeleted(gone)   // never listed: gone once a snapshot is in
        #expect(RemoteHostWindow.goneIDs(in: [gone, alive], isGone: c.isGone) == [gone])
        #expect(RemoteHostWindow.goneIDs(in: [alive], isGone: c.isGone).isEmpty)
    }
}
