import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-807): "Guest-adopted tmux windows are spared from pid-pin
/// eviction, so a guest can still fill every slot". The windows a host tab's
/// agent may evict a pin for were every live session's -- and the store
/// adopts any guest tmux window labelled as an agent, @display and
/// @worktree included. 64 such windows held every slot for good. Only a tab
/// a launch of the host's own opened is spared now, kept on the tab itself
/// (reconcile moves tabs between sessions on guest-settable options).
@Suite("Policy steering: only host-launched tabs are spared")
@MainActor
struct HostLaunchedPinTests {
    private func roster(_ id: UUID, _ tabs: [TabsModel.Tab]) -> SessionListModel.VMEntry {
        let model = TabsModel()
        model.tabs = tabs
        model.rosterLive = true
        return SessionListModel.VMEntry(id: id, name: "ws", accentHex: "#000000", model: model)
    }
    private func launch(_ store: AgentSessionStore, _ ws: UUID) -> AgentSession {
        var s = AgentSession(profileID: ws, tool: .claude, title: "Fix login", cwd: "~/app")
        s.launchingSince = Date(); s.launchBaselineIndex = 0; s.launchDisplay = "Fix login"
        store.upsert(s)
        return s
    }
    private let shell = TabsModel.Tab(label: "bash", index: 0, cwd: "/home/ubuntu")
    private let mine = TabsModel.Tab(label: "claude", index: 1, cwd: "/home/ubuntu/app", display: "Fix login")

    @Test("adopted guest tabs aren't host windows, whatever their options say; the launched one is")
    func adoptedArentSpared() {
        let store = AgentSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(UUID().uuidString).json"))
        let ws = UUID()
        let l = launch(store, ws)
        // Guest-made windows: an agent @label, a @display, a wt/ @worktree.
        let squatters = (2..<70).map { i in
            TabsModel.Tab(label: "claude", index: i, cwd: "/home/ubuntu/w\(i)",
                          worktreeBranch: i.isMultiple(of: 2) ? "wt/x\(i)" : nil,
                          display: i.isMultiple(of: 3) ? "Squat \(i)" : nil)
        }
        store.reconcile(entries: [roster(ws, [shell, mine] + squatters)])
        #expect(store.session(l.id)?.windowIndex == 1)
        #expect(store.sessions.filter { $0.profileID == ws && $0.windowIndex != nil }.count > PolicySteering.pinCap)
        let host = store.hostLaunchedWindows(profileID: ws)
        #expect(host == [1])

        // The guest's windows fill every slot; the host tab's agent still gets one.
        let s = PolicySteering()
        for (n, t) in squatters.prefix(PolicySteering.pinCap).enumerated() {
            s.noteAgent(profileID: ws, pid: 9_000 + n, window: t.index, hostWindows: host)
        }
        s.noteAgent(profileID: ws, pid: 500, window: 1, hostWindows: host)
        #expect(s.agentWindows(profileID: ws).contains(1))
    }

    /// Review: a guest @display edit makes reconcile unbind the launched tab
    /// and adopt it as a new session; a mark kept on the session went with it.
    @Test("the launched tab stays the host's when the guest renames it and reconcile adopts it anew")
    func survivesGuestRename() {
        let store = AgentSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(UUID().uuidString).json"))
        let ws = UUID()
        let l = launch(store, ws)
        store.reconcile(entries: [roster(ws, [shell, mine])])
        // Before the first probe: @display and the name rewritten.
        let renamed = TabsModel.Tab(label: "claude", index: 1, cwd: "/home/ubuntu/app", display: "Not yours")
        store.reconcile(entries: [roster(ws, [shell, renamed])])
        #expect(store.session(l.id)?.windowIndex != 1)
        #expect(store.hostLaunchedWindows(profileID: ws) == [1])
    }

    @Test("sealed by the probe: kept across a restart; another window, a closed tab, or a reboot drop it")
    func sealedByWindowID() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let ws = UUID()
        let l = launch(store, ws)
        store.reconcile(entries: [roster(ws, [shell, mine])])
        _ = store.checkBoot(l.id, bootID: "boot-1")
        _ = store.checkWindow(l.id, windowID: "@4")
        #expect(store.hostLaunchedTabs[ws]?[1] == .some("boot-1|@4"))
        // An app restart keeps a sealed tab.
        let restarted = AgentSessionStore(fileURL: url)
        #expect(restarted.hostLaunchedWindows(profileID: ws) == [1])
        // Any session probed there seeing another window: not the host's.
        var other = AgentSession(profileID: ws, tool: .claude, title: "x", cwd: "~", windowIndex: 1)
        other.bootID = "boot-1"
        restarted.upsert(other)
        _ = restarted.checkWindow(other.id, windowID: "@9")
        #expect(restarted.hostLaunchedWindows(profileID: ws).isEmpty)

        // Missing from one roster (a refresh mid-way, a window moved out and
        // back): kept, as a session's binding is.
        let t0 = Date()
        store.reconcile(entries: [roster(ws, [shell])], now: t0)
        store.reconcile(entries: [roster(ws, [shell, mine])], now: t0.addingTimeInterval(1))
        store.reconcile(entries: [roster(ws, [shell])], now: t0.addingTimeInterval(2))
        #expect(store.hostLaunchedWindows(profileID: ws) == [1])
        // Gone past the grace: the tab closed, dropped.
        store.reconcile(entries: [roster(ws, [shell])], now: t0.addingTimeInterval(2 + AgentSessionStore.missingGrace))
        #expect(store.hostLaunchedWindows(profileID: ws).isEmpty)

        // A reboot drops every one in the workspace.
        let again = AgentSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(UUID().uuidString).json"))
        let l2 = launch(again, ws)
        again.reconcile(entries: [roster(ws, [shell, mine])])
        _ = again.checkBoot(l2.id, bootID: "boot-1")
        #expect(again.hostLaunchedWindows(profileID: ws) == [1])
        _ = again.checkBoot(l2.id, bootID: "boot-2")
        #expect(again.hostLaunchedWindows(profileID: ws).isEmpty)
    }

    @Test("only the launch binding reserves a tab; the delegate reads the store's set")
    func wiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/AgentCoding/AgentSessions.swift"), encoding: .utf8)
        #expect(src.components(separatedBy: "[tab.index] = .some(nil)").count == 2)
        let delivery = try String(contentsOf: root.appendingPathComponent("Sources/AgentCoding/PolicySteeringDelivery.swift"), encoding: .utf8)
        #expect(delivery.contains("agentSessionStore.hostLaunchedWindows(profileID: profileID)"))
    }
}
