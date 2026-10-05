import Foundation
import Testing
@testable import bromure_ac

/// A workspace restored from saved state keeps its sessions bound: the
/// guest resyncs its clock after the restore, which moves every agent's
/// wall-clock start forward by the suspend's length — the same processes,
/// not new runs. And a roster adoption that turns out to be an unbound
/// session's own tab folds back into it instead of living on as a twin.

@MainActor private func liveRoster(_ id: UUID, _ tabs: [TabsModel.Tab]) -> SessionListModel.VMEntry {
    let model = TabsModel()
    model.tabs = tabs
    model.rosterLive = true
    return SessionListModel.VMEntry(id: id, name: "ws", accentHex: "#000000", model: model)
}

@Suite("Restore from saved state keeps sessions bound")
@MainActor
struct RestoreSessionBindingTests {
    private func tempStore() -> AgentSessionStore {
        AgentSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(UUID().uuidString).json"))
    }

    /// A Kimi session bound to tab 1, made long ago (past the launch grace),
    /// never resumed by us — exactly what a restore finds.
    private func boundKimi(_ ws: UUID, store: AgentSessionStore) -> AgentSession {
        var s = AgentSession(profileID: ws, tool: .kimi, title: "Explain hash tables", cwd: "~/hash",
                             createdAt: Date().addingTimeInterval(-3600), windowIndex: 1)
        s.agentTranscriptID = "session_0b7f2c1e-4d5a-4c3b-9e8f-1a2b3c4d5e6f"
        store.upsert(s)
        return s
    }

    @Test("the same pid whose wall-clock start moved +120 s after a restore stays bound")
    func shiftedStartSamePID() {
        let store = tempStore()
        let ws = UUID()
        let s = boundKimi(ws, store: store)
        #expect(store.checkAgentProcess(s.id, start: 1_759_600_000, pid: 4242, uptime: 300))
        // Suspended ~116 s; after the restore the guest's btime jumped.
        #expect(store.checkAgentProcess(s.id, start: 1_759_600_120, pid: 4242, uptime: 300))
        let after = store.session(s.id)!
        #expect(after.windowIndex == 1)
        #expect(after.releasedWindowIndex == nil)
        #expect(after.endedAt == nil)
        #expect(after.agentProcessStart == 1_759_600_120)   // re-stamped
        #expect(after.agentTranscriptID == s.agentTranscriptID)
    }

    @Test("another pid in the tab is still a new run")
    func differentPIDIsNewRun() {
        let store = tempStore()
        let ws = UUID()
        let s = boundKimi(ws, store: store)
        #expect(store.checkAgentProcess(s.id, start: 1_759_600_000, pid: 4242, uptime: 300))
        #expect(!store.checkAgentProcess(s.id, start: 1_759_600_500, pid: 5151, uptime: 800))
        #expect(store.session(s.id)?.releasedWindowIndex == 1)
    }

    @Test("a reused pid with another start since boot is a different process")
    func reusedPID() {
        let s = AgentSession(profileID: UUID(), tool: .kimi, title: "t", windowIndex: 1)
        var stamped = s
        stamped.agentProcessStart = 1000; stamped.agentProcessPID = 7; stamped.agentProcessUptime = 50
        #expect(AgentSessionStore.sameAgentProcess(stamped, start: 1000, pid: 7, uptime: 51, restoredAt: nil) == .same)
        #expect(AgentSessionStore.sameAgentProcess(stamped, start: 2000, pid: 7, uptime: 950, restoredAt: nil) == .different)
        #expect(AgentSessionStore.sameAgentProcess(stamped, start: 2000, pid: 8, uptime: 50, restoredAt: Date()) == .different)
    }

    @Test("a stamp without a pid (older build) forgives a shifted start right after a restore only")
    func legacyStampAfterRestore() {
        let store = tempStore()
        let ws = UUID()
        let s = boundKimi(ws, store: store)
        #expect(store.checkAgentProcess(s.id, start: 1_759_600_000))   // legacy stamp: no pid
        store.noteRestored(profileID: ws)
        #expect(store.checkAgentProcess(s.id, start: 1_759_600_120, pid: 4242, uptime: 300))
        #expect(store.session(s.id)?.windowIndex == 1)
        #expect(store.session(s.id)?.agentProcessPID == 4242)        // learned now
        // Without a restore the same shift still reads as a new run.
        let other = tempStore()
        let s2 = boundKimi(ws, store: other)
        #expect(other.checkAgentProcess(s2.id, start: 1_759_600_000))
        #expect(!other.checkAgentProcess(s2.id, start: 1_759_600_120, pid: 4242, uptime: 300))
        // A restore long ago doesn't count either.
        let third = tempStore()
        let s3 = boundKimi(ws, store: third)
        #expect(third.checkAgentProcess(s3.id, start: 1_759_600_000))
        third.noteRestored(profileID: ws, at: Date().addingTimeInterval(-3600))
        #expect(!third.checkAgentProcess(s3.id, start: 1_759_600_120))
    }

    @Test("the probe's proc lines carry the pid and the start since boot")
    func parseAgentProcs() {
        let out = "boot\tabc\nwin\t1\t@3\nproc\t1\t1759600000\t4242\t300\nproc\t2\t1759600010\nproc\t3\tx\t1\t1\n"
        let procs = AgentSessionEngine.parseAgentProcs(out)
        #expect(procs[1] == AgentSessionEngine.AgentProc(start: 1_759_600_000, pid: 4242, uptime: 300))
        #expect(procs[2] == AgentSessionEngine.AgentProc(start: 1_759_600_010))
        #expect(procs[3] == nil)
        // The older reader still reads the new lines.
        #expect(AgentSessionEngine.parseAgentStarts(out) == [1: 1_759_600_000, 2: 1_759_600_010])
        // The probe asks for both.
        #expect(AgentSessionEngine.probeCommand(window: "").contains("$(( st / hz ))"))
    }

    @Test("an adoptee that names an unbound session's conversation folds back into it")
    func twinAdoptionFolds() {
        let store = tempStore()
        let ws = UUID()
        let s = boundKimi(ws, store: store)
        var followed: [(UUID, UUID)] = []
        store.onSucceeded = { followed.append(($0, $1)) }
        var removed: [UUID] = []
        store.onRemove = { removed.append($0) }
        // The split as it used to happen: a legacy stamp, a shifted start,
        // no restore known → released, and the roster adopts the tab.
        #expect(store.checkAgentProcess(s.id, start: 1_759_600_000))
        #expect(!store.checkAgentProcess(s.id, start: 1_759_600_120))
        let tabs = [TabsModel.Tab(label: "bash", index: 0, cwd: "/home/ubuntu"),
                    TabsModel.Tab(label: "kimi", index: 1, cwd: "/home/ubuntu/hash")]
        store.reconcile(entries: [liveRoster(ws, tabs)])
        let twin = store.session(profileID: ws, windowIndex: 1)
        #expect(twin != nil && twin?.id != s.id)
        // Its tab names the original's conversation: the twin goes, the
        // original takes the tab back.
        store.setTranscriptID(twin!.id, s.agentTranscriptID!)
        #expect(store.session(twin!.id) == nil)
        #expect(removed == [twin!.id])
        let back = store.session(s.id)!
        #expect(back.windowIndex == 1)
        #expect(back.releasedWindowIndex == nil)
        #expect(back.endedAt == nil)
        #expect(followed.last?.0 == twin!.id && followed.last?.1 == s.id)
        #expect(store.sessions.filter { $0.profileID == ws }.count == 1)
        // Later reconciles keep it that way: no new adoptee.
        store.reconcile(entries: [liveRoster(ws, tabs)])
        #expect(store.sessions.filter { $0.profileID == ws }.count == 1)
        #expect(store.session(profileID: ws, windowIndex: 1)?.id == s.id)
    }

    @Test("a genuinely new conversation in the released tab stays a session of its own")
    func newConversationStays() {
        let store = tempStore()
        let ws = UUID()
        let s = boundKimi(ws, store: store)
        #expect(store.checkAgentProcess(s.id, start: 1_759_600_000, pid: 1, uptime: 10))
        #expect(!store.checkAgentProcess(s.id, start: 1_759_600_500, pid: 2, uptime: 510))
        let tabs = [TabsModel.Tab(label: "kimi", index: 1, cwd: "/home/ubuntu/hash")]
        store.reconcile(entries: [liveRoster(ws, tabs)])
        let fresh = store.session(profileID: ws, windowIndex: 1)!
        #expect(fresh.id != s.id)
        store.setTranscriptID(fresh.id, "session_11111111-2222-4333-8444-555555555555")
        #expect(store.session(fresh.id)?.agentTranscriptID == "session_11111111-2222-4333-8444-555555555555")
        #expect(store.session(s.id)?.windowIndex == nil)
    }

    @Test("an adoptee may read its original's Kimi conversation — nobody else's")
    func adopteeClaims() {
        let store = tempStore()
        let ws = UUID()
        let s = boundKimi(ws, store: store)
        var bystander = AgentSession(profileID: ws, tool: .kimi, title: "Other", cwd: "~/hash")
        bystander.agentTranscriptID = "session_99999999-8888-4777-8666-555555555555"
        store.upsert(bystander)
        #expect(store.checkAgentProcess(s.id, start: 1_759_600_000))
        #expect(!store.checkAgentProcess(s.id, start: 1_759_600_120))
        store.reconcile(entries: [liveRoster(ws, [TabsModel.Tab(label: "kimi", index: 1, cwd: "/home/ubuntu/hash")])])
        let twin = store.session(profileID: ws, windowIndex: 1)!
        let claimed = store.kimiSessionsClaimed(byAdoptee: twin)
        #expect(!claimed.contains(s.agentTranscriptID!))
        #expect(claimed.contains(bystander.agentTranscriptID!))
        // A session we launched isn't an adoptee: the usual claims.
        #expect(store.kimiSessionsClaimed(byAdoptee: store.session(s.id)!)
            == store.kimiSessionsClaimed(profileID: ws, besides: s.id))
    }

    @Test("a live Kimi tab learns its conversation only when it's the folder's sole unpinned one")
    func soleUnpinnedKimi() {
        let store = tempStore()
        let ws = UUID()
        let a = AgentSession(profileID: ws, tool: .kimi, title: "a", cwd: "~/proj", windowIndex: 1)
        store.upsert(a)
        #expect(store.isSoleUnpinnedKimi(a))
        var b = AgentSession(profileID: ws, tool: .kimi, title: "b", cwd: "~/proj", windowIndex: 2)
        store.upsert(b)
        #expect(!store.isSoleUnpinnedKimi(a))
        b.agentTranscriptID = "session_11111111-2222-4333-8444-555555555555"
        store.upsert(b)
        #expect(store.isSoleUnpinnedKimi(a))
    }
}

@Suite("Quit confirmation wording")
struct QuitConfirmationTextTests {
    @Test("each workspace's fate is said by its close action, grouped, singular and plural")
    func wording() {
        #expect(ACAppDelegate.quitConfirmationText(workspaces: [("dev", .shutdown)], machines: [])
            == "The workspace dev will be shut down.")
        #expect(ACAppDelegate.quitConfirmationText(workspaces: [("QA-codex", .shutdown), ("QA-grok", .shutdown),
                                                               ("QA-security", .suspend)], machines: [])
            == "The workspaces QA-codex and QA-grok will be shut down. The workspace QA-security will be suspended and resume where it left off.")
        // Ask and Run in the background suspend at quit.
        #expect(ACAppDelegate.quitConfirmationText(workspaces: [("a", .ask), ("b", .background), ("c", .suspend)], machines: [])
            == "The workspaces a, b, and c will be suspended and resume where they left off.")
        #expect(ACAppDelegate.quitConfirmationText(workspaces: [], machines: ["connector"])
            == "The infrastructure machine connector is running and will be suspended.")
        let both = ACAppDelegate.quitConfirmationText(workspaces: [("dev", .shutdown)], machines: ["connector", "registry"])
        #expect(both.hasPrefix("The workspace dev will be shut down."))
        #expect(both.hasSuffix("2 infrastructure machines are running (connector, registry) and will be suspended."))
        #expect(!both.contains("close action"))
    }
}

@Suite("Subscription refresh keeps the registration date")
struct SubscriptionRegisteredAtTests {
    private static func tempURL(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("s.enc")
    }
    private static let signedIn = Date(timeIntervalSince1970: 1_759_000_000)
    private static let later = Date(timeIntervalSince1970: 1_759_500_000)

    @Test("Kimi: a refresh rotates the tokens, not registeredAt")
    func kimi() throws {
        let store = KimiSubscriptionStore(fileURL: Self.tempURL("kimi"))
        let pid = UUID()
        try store.setOverride(KimiSubscriptionRecord(accessToken: "a1", refreshToken: "r1",
                                                     expiresAt: Self.signedIn, savedAt: Self.signedIn), for: pid)
        let rotated = KimiSubscriptionRecord(accessToken: "a2", refreshToken: "r2", expiresAt: Self.later,
                                             savedAt: Self.later, lastRefreshedAt: Self.later)
        #expect(try store.commitRefresh(rotated, slotKey: pid.uuidString, replacing: "r1"))
        let r = store.record(for: pid)
        #expect(r?.refreshToken == "r2")
        #expect(r?.savedAt == Self.signedIn)
        #expect(r?.lastRefreshedAt == Self.later)
        // A re-registration is a new sign-in.
        try store.setOverride(KimiSubscriptionRecord(accessToken: "a3", refreshToken: "r3",
                                                     expiresAt: Self.later, savedAt: Self.later), for: pid)
        #expect(store.record(for: pid)?.savedAt == Self.later)
    }

    @Test("Claude, Codex and Grok keep it across a refresh too")
    func others() throws {
        let c = ClaudeSubscriptionStore(fileURL: Self.tempURL("claude"))
        try c.setShared(ClaudeSubscriptionRecord(accessToken: "a1", refreshToken: "r1",
                                                 expiresAt: Self.signedIn, savedAt: Self.signedIn))
        #expect(try c.commitRefresh(ClaudeSubscriptionRecord(accessToken: "a2", refreshToken: "r2",
                                                             expiresAt: Self.later, savedAt: Self.later),
                                    slotKey: "shared", replacing: "r1"))
        #expect(c.record(for: nil)?.savedAt == Self.signedIn)

        let x = CodexSubscriptionStore(fileURL: Self.tempURL("codex"))
        try x.setShared(CodexSubscriptionRecord(accessToken: "a1", refreshToken: "r1", idToken: "",
                                                expiresAt: Self.signedIn, savedAt: Self.signedIn))
        #expect(try x.commitRefresh(CodexSubscriptionRecord(accessToken: "a2", refreshToken: "r2", idToken: "",
                                                            expiresAt: Self.later, savedAt: Self.later),
                                    slotKey: "shared", replacing: "r1"))
        #expect(x.record(for: nil)?.savedAt == Self.signedIn)

        let g = GrokSubscriptionStore(fileURL: Self.tempURL("grok"))
        try g.setShared(GrokSubscriptionRecord(accessToken: "a1", refreshToken: "r1",
                                               expiresAt: Self.signedIn, savedAt: Self.signedIn))
        #expect(try g.commitRefresh(GrokSubscriptionRecord(accessToken: "a2", refreshToken: "r2",
                                                           expiresAt: Self.later, savedAt: Self.later),
                                    slotKey: "shared", replacing: "r1"))
        #expect(g.record(for: nil)?.savedAt == Self.signedIn)
    }
}
