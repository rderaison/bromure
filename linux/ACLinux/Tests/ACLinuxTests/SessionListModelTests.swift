import Foundation
import Testing
@testable import ACLinux

/// The session list model the daemon keeps without a window
/// (LinuxSessionHost.refreshSidebar), which the Switchboard and the board's
/// dispatcher read a session's state from.
@Suite("The daemon's session list model", .serialized)
@MainActor
struct SessionListModelTests {
    static func host() async throws -> (LinuxSessionHost, Daemon, String) {
        let (d, _, dir) = try await DaemonRepairGateTests.daemon()
        return (LinuxSessionHost(daemon: d, stateDir: dir), d, dir)
    }

    static func session(_ profileID: UUID, window: Int? = 0) -> AgentSession {
        var s = AgentSession(profileID: profileID, tool: .claude, title: "t", cwd: "~")
        s.windowIndex = window
        return s
    }

    /// A row carries its workspace's Squelch switch and notes (macOS's
    /// sidebar row: the shield's neighbours and the tooltip).
    @Test func rowsCarrySquelchAndNotes() async throws {
        let (h, _, dir) = try await Self.host()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var p = Profile(name: "sq", tool: .claude, authMode: .local)
        p.squelch.enabled = true
        p.comments = "# Release\nShip on Friday"
        let plain = Profile(name: "plain", tool: .claude, authMode: .local)
        h.refreshSidebar(workspaces: [], profiles: [p, plain], machines: [])
        let rows = Dictionary(uniqueKeysWithValues: h.listModel.profileRows.map { ($0.id, $0) })
        #expect(rows[p.id]?.squelch == true && rows[p.id]?.notes == "# Release\nShip on Friday")
        #expect(rows[plain.id]?.squelch == false && rows[plain.id]?.notes == "")
    }

    @Test func rowsCoverEveryWorkspaceAndMachineWithTheirRunState() async throws {
        let (h, d, dir) = try await Self.host()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let up = Profile(name: "up", tool: .claude, authMode: .local), down = Profile(name: "down", tool: .claude, authMode: .local)
        let m = AttachedMachine(id: UUID(), name: "sidecar", makeServer: { _ in nil })   // never connected
        LinuxSessionHost.running.withLockedValue { $0.insert(up.id) }
        defer { LinuxSessionHost.running.withLockedValue { _ = $0.remove(up.id) } }
        h.refreshSidebar(workspaces: [], profiles: [up, down], machines: [m])
        let rows = Dictionary(uniqueKeysWithValues: h.listModel.profileRows.map { ($0.id, $0.state) })
        #expect(rows[up.id] == .running && rows[down.id] == .off && rows[m.id] == .off)
        #expect(h.listModel.machineIDs == [m.id])
        // A machine's session isn't "Machine removed" (it has a row); one of
        // a workspace that's gone is.
        #expect(SessionHome.goneReason(Self.session(m.id), in: h.listModel) == nil)
        #expect(SessionHome.goneReason(Self.session(UUID()), in: h.listModel) != nil)
        // A stopped workspace's session is asleep, not working.
        #expect(SessionHome.bucket(for: Self.session(down.id), in: h.listModel) == .asleep)
        await d.shutdown()
    }

    @Test func anEntryKeepsItsObjectWhileItsRosterDoes() async throws {
        let (h, d, dir) = try await Self.host()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = Profile(name: "w", tool: .claude, authMode: .local)
        let roster = TabsModel()
        h.refreshSidebar(workspaces: [.init(id: p.id, name: "w", accentHex: "#000000", model: roster)], profiles: [p], machines: [])
        let first = try #require(h.listModel.entries.first)
        // The next pass builds a new VMEntry over the same roster: the old one stays.
        h.refreshSidebar(workspaces: [.init(id: p.id, name: "w", accentHex: "#000000", model: roster)], profiles: [p], machines: [])
        #expect(h.listModel.entries.count == 1 && h.listModel.entries.first === first)
        // A new roster (the workspace restarted): a new entry.
        h.refreshSidebar(workspaces: [.init(id: p.id, name: "w", accentHex: "#000000", model: TabsModel())], profiles: [p], machines: [])
        #expect(h.listModel.entries.first !== first)
        // Stopped: gone from the entries.
        h.refreshSidebar(workspaces: [], profiles: [p], machines: [])
        #expect(h.listModel.entries.isEmpty)
        await d.shutdown()
    }

    /// The dispatcher now has a model: a session waiting on the user isn't free.
    @Test func theDispatcherReadsTheModel() async throws {
        let (h, d, dir) = try await Self.host()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(h.sessionListModel === h.listModel)
        await d.shutdown()
    }
}
