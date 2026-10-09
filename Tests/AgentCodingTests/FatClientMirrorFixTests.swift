import Foundation
import Testing
@testable import bromure_ac

// Fat-client mirror fixes: console presence (where an agent's browser
// opens), the link-state screen, room resting cells, and the Files pane
// over a slow link.

@Suite("Fat-client mirror")
@MainActor
struct FatClientMirrorFixTests {

    // MARK: Console presence

    @Test("only mirror-window input is reported to the remote as console use")
    func mirrorInputIsWhatTheRemoteHears() {
        let p = ConsolePresence()
        // Never touched: ancient.
        #expect(p.idleMillis() >= Int.max / 4)
        // Input in this app's own windows is this server's console — not
        // something a mirror reports to ITS server (self-mirror flapped).
        p.noteLocal()
        #expect(p.idleMillis() >= Int.max / 4)
        p.noteMirror()
        #expect(p.idleMillis() < 5_000)
    }

    @Test("a self-mirror's report wins over older local input, loses to newer")
    func selfMirrorArbitration() {
        let p = ConsolePresence()
        p.noteLocal()
        Thread.sleep(forTimeInterval: 0.005)   // distinct instants under a loaded runner
        p.noteMirror()
        Thread.sleep(forTimeInterval: 0.005)
        // The mirror's poll reports its (fresh) idle time back to the same app.
        p.noteRemote(idleMs: p.idleMillis())
        #expect(p.remotePreferred)
        Thread.sleep(forTimeInterval: 0.005)
        // Clicking the server's own window takes the seat back.
        p.noteLocal()
        #expect(!p.remotePreferred)
    }

    @Test("idle clamp")
    func idleClamp() {
        let now = Date()
        #expect(ConsolePresence.idleMillis(since: .distantPast, now: now) == Int.max / 2)
        #expect(ConsolePresence.idleMillis(since: now.addingTimeInterval(-1.5), now: now) == 1500)
        #expect(ConsolePresence.idleMillis(since: now.addingTimeInterval(5), now: now) == 0)
    }

    // MARK: Link state

    @Test("an established link that drops reconnects quietly; key help only for a first connect or a rejection")
    func linkPresentation() {
        typealias C = RemoteHostController
        #expect(C.linkPresentation(connected: true, hasSnapshot: true, verdict: nil) == .live)
        #expect(C.linkPresentation(connected: false, hasSnapshot: true, verdict: nil) == .reconnecting)
        #expect(C.linkPresentation(connected: false, hasSnapshot: true, verdict: .unreachable) == .reconnecting)
        #expect(C.linkPresentation(connected: false, hasSnapshot: false, verdict: nil) == .firstConnect)
        #expect(C.linkPresentation(connected: false, hasSnapshot: false, verdict: .unreachable) == .firstConnect)
        #expect(C.linkPresentation(connected: false, hasSnapshot: true, verdict: .authFailed) == .needsKey)
        #expect(C.linkPresentation(connected: false, hasSnapshot: false, verdict: .authFailed) == .needsKey)
        #expect(C.linkPresentation(connected: false, hasSnapshot: true, verdict: .hostKeyChanged) == .hostKeyChanged)
    }

    // MARK: Room resting cells

    @Test("a resting cell whose transcript read failed tries again instead of pinning the opening message")
    func restingReadRetries() async {
        let store = AgentRoomStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("rooms-\(UUID().uuidString).json"))
        let room = store.create(name: "R")
        var s = AgentSession(profileID: UUID(), tool: .claude, title: "paused",
                             openingMessage: "hello")
        s.roomID = room.id
        let backend = FlakyRoomBackend(store: store)
        backend.roomSessions = [s]
        backend.failuresLeft = 2
        let c = RoomStageController(roomID: room.id, backend: backend, listModel: SessionListModel())
        c.restingRetryDelay = 0
        defer { c.stop() }

        c.loadResting(s)
        for _ in 0..<40 {
            if backend.calls >= 1, c.restingDebugState[s.id.uuidString] == -1 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // Failed: still unread (the opening message shows), not pinned empty.
        #expect(c.restingDebugState[s.id.uuidString] == -1)
        // The refresh tick re-asks until the read lands.
        for _ in 0..<100 {
            c.refresh()
            if (c.restingDebugState[s.id.uuidString] ?? -1) > 0 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect((c.restingDebugState[s.id.uuidString] ?? -1) > 0)
        #expect(backend.calls == 3)
    }

    // MARK: Files pane

    @Test("the pane's poll doesn't orphan a slow listing (spinner forever over a fat client)")
    func pollDoesNotOrphanSlowRefresh() async {
        let m = FileExplorerModel()
        let calls = Counter()
        m.execProvider = { _, _, _ in
            calls.n += 1
            try await Task.sleep(nanoseconds: 300_000_000)   // slower than the poll
            return ""
        }
        m.setLocation(profileID: UUID(), cwd: "/home/ubuntu", repoRoot: nil)
        #expect(m.loading)
        // Poll every 100 ms, as a fast stand-in for the pane's 4 s timer
        // against a link slower than it.
        for _ in 0..<9 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            Task { await m.pollRefresh() }
        }
        #expect(!m.loading)
        #expect(m.loadError == nil)
        // The first listing landed and later polls only ran once it had.
        #expect(calls.n <= 4)
    }

    // MARK: Stage split (local window and mirror share it)

    @Test("browser width keeps the chat's floor; files fold when all three can't fit")
    func stageSplit() {
        let min = StageSplit.browserMinWidth
        // Plenty of room: the wish, capped at the max.
        #expect(StageSplit.clampBrowser(640, area: 2000, fileWidth: 300) == 640)
        #expect(StageSplit.clampBrowser(3000, area: 4000, fileWidth: 0) == StageSplit.browserMaxWidth)
        // Tight: what's left beside the chat's 360 pt, never under the floor.
        #expect(StageSplit.clampBrowser(900, area: 1100, fileWidth: 0) == 1100 - StageSplit.chatMinWidth)
        #expect(StageSplit.clampBrowser(900, area: 700, fileWidth: 0) == min)
        // Files fold only when chat + browser + files can't all fit.
        #expect(!StageSplit.foldsFiles(area: 1400, fileWidth: 300))
        #expect(StageSplit.foldsFiles(area: StageSplit.chatMinWidth + min + 299, fileWidth: 300))
        #expect(!StageSplit.foldsFiles(area: 900, fileWidth: 0))
    }

    // MARK: CDP for a client-side browser

    @Test("a relayed (client-side) browser tells the guest to send CDP tools through the channel")
    func cdpViaHostEndpoint() async {
        let relayed = BrowserMCPServer(browser: { nil }, ensureBrowser: {}, cdpViaHost: true)
        let line = #"{"jsonrpc":"2.0","id":7,"method":"bromure/cdpEndpoint"}"#
        let out = await relayed.handle(line: line) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
        let err = json?["error"] as? [String: Any]
        #expect(err?["code"] as? Int == BrowserMCPServer.cdpViaHostCode)
        #expect(json?["id"] as? Int == 7)
    }

    @Test("the guest shim forwards a CDP tool to the host when told cdp-via-host",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func shimForwardsCDPViaHost() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/Resources/vm-setup")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", """
            import importlib.util
            s = importlib.util.spec_from_file_location("b", "bromure-browser-mcp.py")
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            class Host:
                def __init__(self): self.seen = []
                def request(self, req):
                    self.seen.append(req.get("method") + ":" + str((req.get("params") or {}).get("name")))
                    if req.get("method") == "bromure/cdpEndpoint":
                        return {"jsonrpc": "2.0", "id": req["id"], "error": {"code": m.CDP_VIA_HOST_CODE, "message": "cdp-via-host"}}
                    return {"jsonrpc": "2.0", "id": req["id"], "result": {"content": [{"type": "text", "text": "ok"}]}}
            srv = m.Server(); srv.host = Host()
            r = srv._cdp_tool({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                               "params": {"name": "browser_screenshot", "arguments": {}}})
            print(r["id"], r["result"]["content"][0]["text"], ",".join(srv.host.seen))
            """]
        proc.currentDirectoryURL = script
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = pipe
        try proc.run(); proc.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(out == "3 ok bromure/cdpEndpoint:None,tools/call:browser_screenshot")
    }
}

@MainActor
private final class Counter { var n = 0 }

@MainActor
private final class FlakyRoomBackend: RoomStageBackend {
    let roomStore: AgentRoomStore
    var roomSessions: [AgentSession] = []
    var failuresLeft = 0
    var calls = 0
    init(store: AgentRoomStore) { roomStore = store }
    func chatKey(for s: AgentSession) -> String? { nil }
    func makeChat(for s: AgentSession) -> BeautifiedSessionModel? { nil }
    func startSwitchboard(_ room: AgentRoom) {}
    func setLayout(_ room: UUID, _ layout: String) {}
    func wake(_ s: AgentSession, with text: String) {}
    func restingTranscript(for s: AgentSession, ended: Bool) async -> Data? {
        calls += 1
        if failuresLeft > 0 { failuresLeft -= 1; return nil }
        return Data("""
        {"type":"user","message":{"role":"user","content":"hello"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi there"}]}}

        """.utf8)
    }
    func peerMentions(for s: AgentSession) -> [PeerMention] { [] }
    func assignNickname(_ id: UUID, _ nick: String) {}
}
