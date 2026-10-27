import Foundation
import Testing
@testable import bromure_ac

/// Board task "Mark unread messages in the list of sessions": a session whose
/// agent finished a turn or stopped to ask shows an unread mark until someone
/// looks -- counted on the server, read from any client, the mark gone on
/// every other one; not shown while the agent works.
@Suite("Session unread marks")
@MainActor
struct SessionUnreadTests {
    static func tempStore() -> AgentSessionStore {
        AgentSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(UUID().uuidString).json"))
    }

    static func roster(_ id: UUID, _ tabs: [TabsModel.Tab]) -> SessionListModel.VMEntry {
        let m = TabsModel(); m.tabs = tabs; m.rosterLive = true
        return SessionListModel.VMEntry(id: id, name: "ws", accentHex: "#000000", model: m)
    }

    @Test("what counts as a reply: a turn that ended, or a question -- for every agent's hooks")
    func replies() {
        let r = ACAppDelegate.isReply(from:to:)
        #expect(r(.working, .done))
        #expect(r(.working, .needsInput))
        #expect(r(.done, .needsInput))
        #expect(r(nil, .needsInput))
        #expect(!r(.needsInput, .needsInput))        // the same question again
        #expect(!r(.done, .done))                    // a settle re-reported
        #expect(!r(nil, .done))                      // a replayed status at launch
        #expect(!r(.done, .working))
        #expect(!r(.needsInput, .done))              // answered, not a new reply
    }

    @Test("the count goes up per reply; a read catches up to what was seen, never back, never past")
    func counting() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString).json")
        let store = AgentSessionStore(fileURL: url)
        let s = AgentSession(profileID: UUID(), tool: .codex, title: "t", cwd: "~")
        store.upsert(s)
        #expect(store.session(s.id)?.isUnread == false)
        #expect(!store.markRead(s.id))                         // nothing to read
        store.noteReply(s.id); store.noteReply(s.id)
        #expect(store.session(s.id)?.replies == 2)
        #expect(store.session(s.id)?.isUnread == true)
        // A client saw 1 of them; a reply landed in between: still unread.
        #expect(store.markRead(s.id, upTo: 1))
        #expect(store.session(s.id)?.isUnread == true)
        #expect(!store.markRead(s.id, upTo: 0))                // never back
        #expect(store.markRead(s.id, upTo: 9))                 // never past the count
        #expect(store.session(s.id)?.readReplies == 2)
        #expect(store.session(s.id)?.isUnread == false)
        // The app hears each reply (to read it at once if it's on screen).
        var heard: [UUID] = []
        store.onReply = { heard.append($0) }
        store.noteReply(s.id)
        #expect(store.session(s.id)?.isUnread == true && heard == [s.id])
        // A dialog is no reply by itself (its hook counted the question):
        // flagging it after a client read the question must not bring the
        // mark back. The pane counts it only for a dialog inside a turn.
        store.markRead(s.id)
        #expect(store.setAwaitingAnswer(s.id, true))
        #expect(!store.setAwaitingAnswer(s.id, true))          // no change
        #expect(store.session(s.id)?.isUnread == false && store.session(s.id)?.replies == 3)
        // Persisted with the session; an old file without them reads as read.
        let relaunched = AgentSessionStore(fileURL: url)
        #expect(relaunched.session(s.id)?.replies == 3 && relaunched.session(s.id)?.readReplies == 3)
        let old = try? JSONDecoder().decode(AgentSession.self, from: Data(
            #"{"id":"\#(UUID().uuidString)","profileID":"\#(UUID().uuidString)","tool":"claude","title":"t","cwd":"~","createdAt":0}"#.utf8))
        #expect(old?.isUnread == false)
    }

    @Test("a mirror never counts on its own: only the server does")
    func mirrorDoesntCount() {
        let mirror = AgentSessionStore(mirror: true)
        let s = AgentSession(profileID: UUID(), tool: .grok, title: "t", cwd: "~")
        mirror.applyMirror([s])
        mirror.noteReply(s.id)
        #expect(mirror.session(s.id)?.replies == nil)
    }

    @Test("the mark shows when the agent is done or asking, not while it works, not archived")
    func shownOnlyWhenNotWorking() {
        let store = Self.tempStore()
        let ws = UUID()
        var s = AgentSession(profileID: ws, tool: .omp, title: "t", cwd: "~/w", windowIndex: 1)
        s.agentAlive = true
        s.replies = 1
        store.upsert(s)
        let tab = TabsModel.Tab(label: "omp", index: 1, cwd: "/home/ubuntu/w")
        let model = SessionListModel()
        model.headlessEntries = [Self.roster(ws, [TabsModel.Tab(label: "bash", index: 0, cwd: "/home/ubuntu"), tab])]
        model.profileRows = [SessionListModel.ProfileRow(id: ws, name: "QA", accentHex: "#000000",
                                                         state: .running, compromised: false)]
        tab.agentStatus = .done
        #expect(SessionHome.showsUnread(store.session(s.id)!, in: model))
        tab.agentStatus = .needsInput
        #expect(SessionHome.showsUnread(store.session(s.id)!, in: model))
        tab.agentStatus = .working
        #expect(!SessionHome.showsUnread(store.session(s.id)!, in: model))
        tab.agentStatus = .done
        store.mutate(s.id) { $0.archivedAt = Date() }
        #expect(!SessionHome.showsUnread(store.session(s.id)!, in: model))
        store.mutate(s.id) { $0.archivedAt = nil }
        store.markRead(s.id)
        #expect(!SessionHome.showsUnread(store.session(s.id)!, in: model))
    }

    /// A /state as a server sends it (with its workspace list: one without is
    /// skipped as degenerate).
    static func snapshot(_ s: AgentSession) -> [String: Any] {
        ["workspaces": [] as [[String: Any]], "vms": [] as [[String: Any]], "workspacesListed": true,
         "agentSessions": [wire(s)]]
    }

    static func wire(_ s: AgentSession) -> [String: Any] {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        return (try? JSONSerialization.jsonObject(with: enc.encode(s))) as? [String: Any] ?? [:]
    }

    @Test("a client's read shows at once and isn't undone by a snapshot that predates it; another client sees the server's")
    func clientRead() {
        let a = RemoteHostController(host: RemoteHost(name: "a", address: "127.0.0.1", port: 1, user: "nobody"))
        let b = RemoteHostController(host: RemoteHost(name: "b", address: "127.0.0.1", port: 1, user: "nobody"))
        var s = AgentSession(profileID: UUID(), tool: .claude, title: "t", cwd: "~")
        s.replies = 2
        for c in [a, b] { c.applyPushedSnapshot(Self.snapshot(s)) }
        #expect(a.sessionStore.session(s.id)?.isUnread == true)
        a.markRead(s.id)
        #expect(a.sessionStore.session(s.id)?.isUnread == false)
        // The server hasn't caught up yet: the read holds.
        a.applyPushedSnapshot(Self.snapshot(s))
        #expect(a.sessionStore.session(s.id)?.isUnread == false)
        // The server took it: every client's next snapshot has it read.
        s.readReplies = 2
        for c in [a, b] { c.applyPushedSnapshot(Self.snapshot(s)) }
        #expect(b.sessionStore.session(s.id)?.isUnread == false)
        // A new reply: unread again everywhere.
        s.replies = 3
        a.applyPushedSnapshot(Self.snapshot(s))
        #expect(a.sessionStore.session(s.id)?.isUnread == true)
        // The session on screen is read as the reply arrives.
        a.watching = { [s.id] }
        s.replies = 4
        a.applyPushedSnapshot(Self.snapshot(s))
        #expect(a.sessionStore.session(s.id)?.isUnread == false)
    }

    @Test("wiring: the hook choke point counts, the server route reads, viewing reads on every client")
    func wiring() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func src(_ p: String) throws -> String { try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8) }
        let ac = try src("Sources/AgentCoding/BromureAC.swift")
        let set = try #require(ac.range(of: "func setTabAgentStatus(_ id: Profile.ID, index: Int, _ status: AgentStatus) {"))
        #expect(ac[set.upperBound...].prefix(1200).contains("agentSessionStore.noteReply(s.id)"))
        #expect(ac.contains("case (let sid?, \"read\"):"))
        #expect(ac.contains("self.markSessionRead(sid, upTo: body[\"seen\"] as? Int)"))
        #expect(ac.contains("if self.sessionsOnScreen.contains(id) { self.agentSessionStore.markRead(id) }"))
        // An attached machine's session on stage: read when its snapshot brings a reply.
        let refresh = try #require(ac.range(of: "func refreshHomeSessions() {"))
        #expect(ac[refresh.upperBound...].prefix(900).contains("markSessionRead(id)"))
        // ...shown read here at once, forwarded to the machine that counts.
        let mark = try #require(ac.range(of: "func markSessionRead(_ id: UUID, upTo: Int? = nil) {"))
        let machineBranch = ac[mark.upperBound...].prefix(600)
        #expect(machineBranch.contains("m.markRead(id, upTo: min(upTo ?? n, n))\n            homeSessionStore.applyMirror(allSessionRecords)"))
        // A dialog counts only inside a turn (hooks still working).
        let pane = try src("Sources/AgentCoding/SessionPane.swift")
        let dialog = try #require(pane.range(of: "m.dialogPromptChanged = {"))
        let body = pane[dialog.upperBound...].prefix(1100)
        #expect(body.contains("if delegate.agentSessionStore.setAwaitingAnswer(s.id, waiting), waiting,"))
        #expect(body.contains("?.agentStatus == .working {"))
        // A room's chats on screen are read: on show, and per page or zoom.
        let room = try src("Sources/AgentCoding/RoomStage.swift")
        #expect(room.contains("var page = 0 { didSet { if page != oldValue { shownChanged() } } }"))
        #expect(room.contains("var zoomedID: UUID? { didSet { if zoomedID != oldValue { shownChanged() } } }"))
        let host = try src("Sources/AgentCoding/UnifiedSessionWindow.swift")
        #expect(host.components(separatedBy: "delegate.markSessionRead(id)").count == 3)   // both select paths
        #expect(host.contains("for id in sessionsOnStage { acDelegate?.markSessionRead(id) }"))   // becomeKey
        #expect(host.contains("if let rc = roomController { return rc.onScreenIDs }"))
        let fc = try src("Sources/AgentCoding/FatClientController.swift")
        #expect(fc.components(separatedBy: "controller.markRead(id)").count >= 4)           // selects + becomeKey
        #expect(fc.contains("controller.watching = { [weak self] in self?.sessionsOnScreen ?? [] }"))
        let ios = try src("ios/BromureRemote/Sources/BromureRemote/SessionScreens.swift")
        #expect(ios.contains(".onChange(of: session?.replies) { _, _ in markRead() }"))
        #expect(ios.contains("if scenePhase == .active { controller.markRead(sessionID) }"))
        let iosRoom = try src("ios/BromureRemote/Sources/BromureRemote/RoomScreens.swift")
        #expect(iosRoom.contains("for s in onScreen where s.isUnread { controller.markRead(s.id) }"))
    }

    /// Finding (CWE-670): "A reply while watching an attached-machine session
    /// stays unread". The Mac only forwarded the read; its copy of the
    /// machine's sessions kept the orb until the machine's next poll -- and a
    /// read sent once per count was never sent again if it got lost.
    @Test("a machine session read here shows read at once, until the machine's count catches up or the read is lost")
    func machineReadHeld() {
        var s = AgentSession(profileID: UUID(), tool: .claude, title: "t", cwd: "~")
        s.replies = 3; s.readReplies = 1
        let t0 = Date()
        var pending: [UUID: (seen: Int, at: Date)] = [s.id: (3, t0)]
        // The machine hasn't caught up: held read.
        var out = AttachedMachine.holdingReads([s], &pending, now: t0.addingTimeInterval(1))
        #expect(out[0].isUnread == false && pending[s.id] != nil)
        // It caught up: let go.
        var caught = s; caught.readReplies = 3
        out = AttachedMachine.holdingReads([caught], &pending, now: t0.addingTimeInterval(2))
        #expect(out[0].isUnread == false && pending[s.id] == nil)
        // Lost: after 10 s unread again (and sent again by the next refresh).
        pending[s.id] = (3, t0)
        out = AttachedMachine.holdingReads([s], &pending, now: t0.addingTimeInterval(11))
        #expect(out[0].isUnread == true && pending[s.id] == nil)
        // A newer reply than the read: still unread.
        var newer = s; newer.replies = 4
        pending[s.id] = (3, t0)
        out = AttachedMachine.holdingReads([newer], &pending, now: t0.addingTimeInterval(1))
        #expect(out[0].isUnread == true)
    }

    /// Finding (CWE-670): "Attached-machine read is latched before the
    /// command finishes". A read the machine refused (or never answered) is
    /// held 2 s, not 10, then the session shows unread and is read again.
    @Test("a refused machine read is let go after 2 s; what counts as refused")
    func machineReadRefused() {
        let failed = AttachedMachine.readFailed
        #expect(failed(nil))
        #expect(failed((404, ["error": "unknown action"])))
        #expect(failed((200, ["error": "unknown session"])))
        #expect(failed((500, [:])))
        #expect(!failed((200, ["ok": true])))

        var s = AgentSession(profileID: UUID(), tool: .claude, title: "t", cwd: "~")
        s.replies = 2
        let t0 = Date()
        // markRead's failure path: the hold restamped to end 2 s from now.
        var pending: [UUID: (seen: Int, at: Date)] = [s.id: (2, t0.addingTimeInterval(2 - AttachedMachine.readHold))]
        #expect(AttachedMachine.holdingReads([s], &pending, now: t0.addingTimeInterval(1))[0].isUnread == false)
        #expect(AttachedMachine.holdingReads([s], &pending, now: t0.addingTimeInterval(2.5))[0].isUnread == true)
        #expect(pending.isEmpty)

        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ml = (try? String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/MachineLinks.swift"), encoding: .utf8)) ?? ""
        let mark = ml.range(of: "func markRead(_ sid: UUID, upTo seen: Int) {")
        #expect(mark != nil)
        if let mark {
            let body = ml[mark.upperBound...].prefix(1800)
            #expect(body.contains("guard Self.readFailed(r), let p = pendingReads[sid], p.seen == seen, p.at == sent else { return }"))
            #expect(body.contains("pendingReads[sid] = (seen, Date().addingTimeInterval(2 - Self.readHold))"))
        }
    }

    /// Finding (CWE-670): "A failed attached-machine read stays marked read
    /// until /state succeeds". With the link down, the read and every poll
    /// fail; the hold must still run out and show the session unread, and
    /// the machine's own count -- not the read shown here -- decides whether
    /// another read goes.
    @Test("a read to a machine that can't be reached shows unread again in about 2 s")
    func machineReadOnDeadLink() async throws {
        let m = AttachedMachine(id: UUID(), name: "gone", makeServer: { _ in nil })   // no such link: every request fails
        defer { m.stop() }
        var s = AgentSession(profileID: m.id, tool: .claude, title: "t", cwd: "~")
        s.replies = 2; s.readReplies = 1
        m.machineSessions = [s]
        m.sessionStore.applyMirror([s])   // as a poll leaves it
        m.reapplyReads()
        #expect(m.sessionStore.session(s.id)?.isUnread == true)
        var changed = 0
        m.onChange = { changed += 1 }
        m.markRead(s.id, upTo: 2)
        #expect(m.sessionStore.session(s.id)?.isUnread == false)   // shown read at once
        #expect(m.unreadOnMachine(s.id))                            // but the machine hasn't said so
        for _ in 0..<60 where m.sessionStore.session(s.id)?.isUnread != true {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(m.sessionStore.session(s.id)?.isUnread == true)    // the failed read let go
        #expect(changed >= 1)                                       // and the host was told
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ac = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        #expect(ac.contains("guard m.unreadOnMachine(id), let n = m.machineSessions.first(where: { $0.id == id })?.replies else { return }"))
    }

    /// Finding (CWE-670): "Attached-machine read hold drops room membership
    /// and review drafts". The hold rebuilt the shown sessions from the last
    /// snapshot, undoing a room move or a review draft made here and not yet
    /// echoed; a smaller read moved the cursor back.
    @Test("a read held on a machine session keeps its room and review drafts, and never goes backward")
    func machineReadKeepsMirrorEdits() async throws {
        let m = AttachedMachine(id: UUID(), name: "gone", makeServer: { _ in nil })
        defer { m.stop() }
        var s = AgentSession(profileID: m.id, tool: .claude, title: "t", cwd: "~")
        s.replies = 5; s.readReplies = 1
        m.machineSessions = [s]
        m.sessionStore.applyMirror([s])
        // Made here, not yet in any snapshot.
        let room = UUID()
        let draft = ReviewComment(text: "rename this")
        m.sessionStore.mutate(s.id) {
            $0.roomID = room
            $0.reviewComments = [draft]
            $0.reviewViewed = ["a.swift": "f1"]
        }
        m.markRead(s.id, upTo: 4)
        var shown = try #require(m.sessionStore.session(s.id))
        #expect(shown.readReplies == 4)
        #expect(shown.roomID == room)
        #expect(shown.reviewComments == [draft])
        #expect(shown.reviewViewed == ["a.swift": "f1"])
        m.markRead(s.id, upTo: 3)                                   // another client's older read
        #expect(m.sessionStore.session(s.id)?.readReplies == 4)
        m.reapplyReads()                                            // a failed poll
        shown = try #require(m.sessionStore.session(s.id))
        #expect(shown.roomID == room && shown.reviewComments == [draft] && shown.readReplies == 4)
        // The failed read lets go (2 s): the cursor is the machine's again, the edits stay.
        for _ in 0..<60 where m.sessionStore.session(s.id)?.readReplies != 1 {
            try await Task.sleep(for: .milliseconds(100))
        }
        shown = try #require(m.sessionStore.session(s.id))
        #expect(shown.readReplies == 1)
        #expect(shown.roomID == room && shown.reviewComments == [draft])
    }

    /// Finding (CWE-670): "Opening a room in the focused window never marks
    /// the chats on screen". The view's appear fired during the overlay's
    /// layout, before showRoom wired the callback; a window already key got
    /// no becomeKey. Wire first, mark at once, call once after opening.
    @Test("a room marks what it opens on: wired before the view, called after, marked at once")
    func roomOpensMarked() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func src(_ p: String) throws -> String { try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8) }
        for (file, cb, view) in [("Sources/AgentCoding/UnifiedSessionWindow.swift", "controller.onShownChanged",
                                  "showSessionOverlay(RoomStageView(controller: controller))"),
                                 ("Sources/AgentCoding/FatClientController.swift", "rc.onShownChanged",
                                  "showSessionOverlay(RoomStageView(controller: rc))")] {
            let text = try src(file)
            let wire = try #require(text.range(of: cb + " = { [weak self"), "\(file)")
            let show = try #require(text.range(of: view), "\(file)")
            let call = try #require(text[show.upperBound...].range(of: cb + "?()"), "\(file)")
            #expect(wire.lowerBound < show.lowerBound, "\(file): wired after the view went in")
            #expect(text[show.upperBound..<call.lowerBound].count < 80, "\(file): not called right after opening")
            // The set is captured when it changes (not re-read a turn later).
            let body = text[wire.upperBound..<show.lowerBound]
            let capture = try #require(body.range(of: "?.onScreenIDs, !ids.isEmpty else { return }"), "\(file)")
            let hop = try #require(body.range(of: "DispatchQueue.main.async"), "\(file)")
            #expect(capture.lowerBound < hop.lowerBound, "\(file): the set is read after the hop")
        }
    }
}
