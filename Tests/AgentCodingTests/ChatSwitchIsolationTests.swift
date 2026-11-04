import Foundation
import SwiftUI
import Testing
@testable import bromure_ac

/// Board: "When switching between beautified transcripts, artefacts from the
/// wrong window show up" — a chat must only ever read, keep and show its own
/// session's conversation, whatever the user or the guest's active tab do
/// while one of its polls is under way.
@Suite("A chat keeps to its own session across a switch", .serialized)
@MainActor
struct ChatSwitchIsolationTests {
    /// Holds the poll in its terminal scan — the first await of every poll —
    /// until the test lets it go, and counts the transcript reads after it.
    private final class GatedProvider: BeautifiedTranscriptProvider {
        var accent: Color { .blue }
        var gate: CheckedContinuation<Void, Never>?
        var scanning = false
        var holdScan = true
        var reads = 0
        func activeTabIndex() -> Int? { 1 }
        func isWorking() -> Bool { false }
        func guestFileOp(_ op: [String: Any]) async -> [String: Any]? { nil }
        func execGuest(_ command: String, timeout: Int) async -> String? {
            if command.contains("capture-pane") {
                if holdScan {
                    scanning = true
                    await withCheckedContinuation { gate = $0 }
                }
                return ""
            }
            if command.contains("pane_current_path") { return "/home/ubuntu/b\n0\n" }
            guard command.hasPrefix("f=\"\";") else { return "" }
            reads += 1
            let file = Data((#"{"type":"user","message":{"role":"user","content":"session B's question"},"timestamp":"2026-11-04T16:00:00Z"}"# + "\n").utf8)
            return "/home/ubuntu/.claude/projects/-home-ubuntu-b/b.jsonl\n\n\(file.count)\n0\n\(file.count)\n"
                + String(decoding: file, as: UTF8.self)
        }
    }

    private func wait(_ what: () -> Bool) async {
        let deadline = Date().addingTimeInterval(4)
        while !what(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    @Test("a chat stopped mid-poll reads nothing more, and saves nothing as its session's copy")
    func stoppedMidPoll() async {
        let provider = GatedProvider()
        let m = BeautifiedSessionModel(provider: provider)
        var saved = 0
        m.transcriptSink = { _ in saved += 1 }
        m.start()
        await wait { provider.scanning && provider.gate != nil }
        #expect(provider.gate != nil)
        // The user switches away while the scan's exec is on the wire — which
        // a cancel doesn't interrupt.
        m.stop()
        provider.gate?.resume()
        provider.gate = nil
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(provider.reads == 0, "a stopped chat went on to read a transcript")
        #expect(saved == 0, "a stopped chat saved what it read as its session's copy")
        #expect(m.items.isEmpty)
    }

    @Test("a chat restarted while a poll was under way still shows its conversation")
    func restartedMidPoll() async {
        let provider = GatedProvider()
        let m = BeautifiedSessionModel(provider: provider)
        m.start()
        await wait { provider.gate != nil }
        m.stop()
        provider.holdScan = false
        m.start()
        provider.gate?.resume()
        provider.gate = nil
        await wait { !m.items.isEmpty }
        #expect(!m.items.isEmpty)
        m.stop()
    }

    private func pane() -> SessionPane {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-switch-\(UUID().uuidString)", isDirectory: true)
        let delegate = ACAppDelegate(
            imageManager: UbuntuImageManager(storageDir: tmp, setupDir: tmp), headless: true)
        let p = SessionPane(profile: Profile(name: "t", tool: .claude, authMode: .subscription, homeModel: .virtiofs),
                            acDelegate: delegate)
        p.beautifierLocked = false
        return p
    }

    private func roster(_ windows: [Int], active: Int) -> [GuestTab] {
        windows.map { GuestTab(index: $0, active: $0 == active, label: "claude") }
    }

    @Test("a local chat reads its own window, not the pane's active tab — and nothing once it's gone")
    func localProviderIsPinned() {
        let p = pane()
        p.applyTabList(roster([3, 5], active: 3))
        let provider = LocalTranscriptProvider(pane: p, window: 5)
        #expect(provider.activeTabIndex() == 5)
        p.model.tabs[1].agentStatus = .working
        #expect(provider.isWorking())
        p.applyTabList(roster([3], active: 3))
        #expect(provider.activeTabIndex() == nil)
    }

    @Test("a session on stage doesn't follow the guest's active tab")
    func onStageIgnoresRoster() {
        let p = pane()
        p.applyTabList(roster([1, 2, 4], active: 1))
        p.sessionOnStage = true
        p.switchTo(index: 2)                              // window 4, session A
        #expect(p.beautifiedModel != nil)
        let chat = p.beautifiedModel
        // The guest confirms the switch — no switch is pending any more…
        p.applyTabList(roster([1, 2, 4], active: 4))
        // …and another client moves the shared active tab.
        p.applyTabList(roster([1, 2, 4], active: 2))
        #expect(p.model.activeTab?.index == 4)
        #expect(p.beautifiedModel === chat, "the chat was rebuilt for another window")
        // A window before it closes: same chat, at its new position.
        p.applyTabList(roster([1, 4], active: 1))
        #expect(p.model.activeTab?.index == 4)
        #expect(p.beautifiedModel === chat)
        p.sessionOnStage = false
        p.setViewMode(.terminal, persist: false)
        p.retireNativeTerminals()
    }

    @Test("a quick A→B→A never mounts B's chat when the snapshots catch up")
    func quickBackAndForth() {
        let p = pane()
        p.applyTabList(roster([1, 2], active: 1))
        p.sessionOnStage = true
        p.switchTo(index: 1)                              // to B (window 2)
        p.switchTo(index: 0)                              // back to A (window 1)
        let chat = p.beautifiedModel
        // A snapshot from before either select "confirms" A…
        p.applyTabList(roster([1, 2], active: 1))
        // …then the guest catches up with the first select, before the second.
        p.applyTabList(roster([1, 2], active: 2))
        #expect(p.model.activeTab?.index == 1)
        #expect(p.beautifiedModel === chat, "B's chat flashed up under A")
        p.applyTabList(roster([1, 2], active: 1))
        #expect(p.beautifiedModel === chat)
        p.sessionOnStage = false
        p.setViewMode(.terminal, persist: false)
        p.retireNativeTerminals()
    }

    @Test("a machine's terminal still follows the guest's active tab")
    func offStageFollowsRoster() {
        let p = pane()
        p.setViewMode(.terminal, persist: false)
        p.applyTabList(roster([1, 2], active: 1))
        p.applyTabList(roster([1, 2], active: 2))
        #expect(p.model.activeTab?.index == 2)
        p.retireNativeTerminals()
    }

    @Test("the fat client's chat is held to its own conversation, as the app's is")
    func fatClientPin() {
        let ws = UUID()
        let conv = "0194a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
        var mine = AgentSession(profileID: ws, tool: .omp, title: "mine", windowIndex: 1)
        var other = AgentSession(profileID: ws, tool: .omp, title: "other", windowIndex: 2)
        other.agentTranscriptID = conv
        let store = AgentSessionStore(mirror: true)
        store.applyMirror([mine, other])
        let host = RemoteHostController(host: RemoteHost(name: "t", address: "127.0.0.1", port: 1, user: "nobody"))
        host.sessionStore.applyMirror([mine, other])
        let provider = RemoteTranscriptProvider(controller: host, workspaceID: ws, windowIndex: 1,
                                                sessionID: mine.id, accent: .blue)
        // Not pinned yet: never the other session's conversation.
        #expect(provider.transcriptPin(window: 1).foreignConversations == [conv])
        #expect(AgentSessionEngine.isForeignConversation(
            path: "/home/ubuntu/.omp/agent/sessions/x/2026-11-04T16-00-00-000Z_\(conv).jsonl",
            agent: "omp", pin: provider.transcriptPin(window: 1)) == true)
        // Pinned: its own, by id, on both clients.
        mine.agentTranscriptID = "0194a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5c"
        host.sessionStore.applyMirror([mine, other])
        #expect(provider.transcriptPin(window: 1) == store.chatTranscriptPin(for: mine, profileID: ws))
        #expect(provider.transcriptPin(window: 1).ompSession == mine.agentTranscriptID)
    }
}
