import AppKit
import SwiftUI
import Testing
@testable import bromure_ac

/// Board report: ⇧⌥Space from another app (Safari) only offered this Mac's
/// sessions, while most of the work runs on a host through the fat client.
/// Summoned from another app, the panel now lists every machine's @nicknames,
/// each saying which machine it's on, and files the task on that machine's
/// board.
@Suite("Quick task from another app: every machine's sessions", .serialized)
@MainActor
struct QuickTaskMachinesTests {
    typealias T = QuickTaskPanel.Target
    private func target(_ key: String, _ machine: String, sessions: [TaskAssigneeChoices.Session],
                        rooms: [TaskAssigneeChoices.Room] = []) -> T {
        T(key: key, machine: machine, profiles: [],
          choices: TaskAssigneeChoices(sessions: sessions, rooms: rooms), current: nil,
          label: { $0.title }, save: { _ in }, assign: { _, _ in }, plan: { _ in })
    }
    private func session(_ label: String, _ ws: String) -> TaskAssigneeChoices.Session {
        .init(id: UUID(), label: label, workspace: ws, busy: false, profileID: UUID())
    }

    @Test("the machines' lists in one, taken in turns, each row naming its machine")
    func merged() {
        let a = session("@notes", "Personal"), b = session("@web", "Personal")
        let lux = session("@lux", "Storefront"), api = session("@api", "Backend")
        let room = TaskAssigneeChoices.Room(id: UUID(), name: "release")
        let local = target("local", "This Mac", sessions: [a, b])
        let studio = target("host-1", "Mac Studio", sessions: [lux, api], rooms: [room])
        let all = QuickTaskPanel.merged([local, studio])
        #expect(all.sessions.map(\.label) == ["@notes", "@lux", "@web", "@api"])
        #expect(all.sessions.map(\.machine) == ["This Mac", "Mac Studio", "This Mac", "Mac Studio"])
        #expect(all.rooms.map(\.machine) == ["Mac Studio"])
        // One machine: its list as it is, no machine named.
        #expect(QuickTaskPanel.merged([local]).sessions.allSatisfy { $0.machine == nil })
        #expect(QuickTaskView.onMachine("Mac Studio") == "Mac Studio · " && QuickTaskView.onMachine(nil).isEmpty)
    }

    @Test("a task goes to the board of the machine its session or room is on")
    func routed() {
        let lux = session("@lux", "Storefront"), mine = session("@notes", "Personal")
        let room = TaskAssigneeChoices.Room(id: UUID(), name: "release")
        let local = target("local", "This Mac", sessions: [mine])
        let studio = target("host-1", "Mac Studio", sessions: [lux], rooms: [room])
        let all = [local, studio]
        func owner(_ a: TaskAssignment?) -> String { QuickTaskPanel.owner(of: a, in: all, else: local).key }
        #expect(owner(TaskAssignment(kind: .session, id: lux.id, label: "@lux")) == "host-1")
        #expect(owner(TaskAssignment(kind: .room, id: room.id, label: "#release")) == "host-1")
        #expect(owner(TaskAssignment(kind: .session, id: mine.id, label: "@notes")) == "local")
        #expect(owner(nil) == "local")
        #expect(owner(.newAgent) == "local")
        #expect(owner(TaskAssignment(kind: .session, id: UUID(), label: "@gone")) == "local")
    }

    /// The finding: the full editor was offered only the opening board's
    /// workspaces; a session picked on another host set the draft's workspace
    /// to that host's, the editor found none selected, and Add Task stayed off.
    @Test("the full editor offers every machine's workspaces, so a host's session can be saved")
    func editorKnowsEveryWorkspace() {
        let mine = Profile(name: "Personal", tool: .claude, authMode: .token)
        var theirs = Profile(name: "Storefront", tool: .codex, authMode: .token)
        theirs.tool = .codex
        let lux = TaskAssigneeChoices.Session(id: UUID(), label: "@lux", workspace: "Storefront",
                                              busy: false, profileID: theirs.id)
        func target(_ key: String, _ machine: String, _ p: Profile, _ s: [TaskAssigneeChoices.Session]) -> T {
            T(key: key, machine: machine, profiles: [p],
              toolSpecs: { _ in [Profile.ToolSpec(tool: key == "local" ? .claude : .codex)] },
              choices: TaskAssigneeChoices(sessions: s, rooms: []), current: nil,
              label: { $0.title }, save: { _ in }, assign: { _, _ in }, plan: { _ in })
        }
        let local = target("local", "This Mac", mine, [])
        let studio = target("host-1", "Mac Studio", theirs, [lux])
        let all = [local, studio]
        // The editor's workspaces: both machines', named with their machine.
        let offered = QuickTaskPanel.editorProfiles(all)
        #expect(offered.map(\.id) == [mine.id, theirs.id])
        #expect(offered.map(\.name) == ["This Mac · Personal", "Mac Studio · Storefront"])
        // The workspace a host session's task gets is among them (Save on).
        let merged = QuickTaskPanel.merged(all)
        let chosen = merged.workspace(for: TaskAssignment(kind: .session, id: lux.id, label: "@lux"))
        #expect(chosen == theirs.id && offered.contains { $0.id == chosen })
        // One machine: its workspaces as they are.
        #expect(QuickTaskPanel.editorProfiles([local]).map(\.name) == ["Personal"])
        // Each workspace's agents come from its own machine.
        #expect(QuickTaskPanel.editorToolSpecs(all)(offered[1]).map(\.tool) == [.codex])
        #expect(QuickTaskPanel.editorToolSpecs(all)(offered[0]).map(\.tool) == [.claude])
        // A host workspace picked with no assignee files on that host.
        #expect(QuickTaskPanel.owner(of: nil, profileID: theirs.id, in: all, else: local).key == "host-1")
        #expect(QuickTaskPanel.owner(of: nil, profileID: mine.id, in: all, else: local).key == "local")
        #expect(QuickTaskPanel.owner(of: .newAgent, profileID: theirs.id, in: all, else: local).key == "host-1")
        // The assignee still wins where it says.
        #expect(QuickTaskPanel.owner(of: TaskAssignment(kind: .session, id: lux.id, label: "@lux"),
                                     profileID: mine.id, in: all, else: local).key == "host-1")
    }

    @Test("from another app the panel takes every connected host; from a window, that window's board")
    func wiring() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/QuickTask.swift"), encoding: .utf8)
        #expect(src.contains("targets = [local] + delegate.connectedRemoteHostWindows().map(Target.remote)"))
        #expect(src.contains("let choices = Self.merged(targets)"))
        #expect(src.contains("let target = Self.owner(of: assignment, in: targets, else: main)"))
        #expect(src.contains("let target = Self.owner(of: task.assignment, profileID: task.profileID, in: targets, else: main)"))
        #expect(src.contains("profiles: Self.editorProfiles(targets),"))
    }
}
