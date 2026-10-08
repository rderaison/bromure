import Foundation
import Testing
@testable import bromure_ac

// B72: a new Kimi session in a folder showed the PREVIOUS conversation there
// (a one-shot `kimi -p` run a minute earlier), then the new opening message.
// Kimi's store is keyed by folder, and interactive Kimi only creates its
// session at the first prompt, so "the newest journal in the folder" was the
// old one for the first seconds — the engine's copy took it in, and the new
// journal was merged after it (its tool-discovery lines, identical in every
// session, even anchored the two together). These pin the binding (journal
// begun by this run, then its id), the resume by id, and the copy's refusal
// to splice another journal in.
@Suite("Kimi: a session reads its own conversation")
struct KimiTranscriptBindingTests {

    static let oldID = "session_dcef923e-fa24-4d09-af6f-ac51355b1d2c"
    static let newID = "session_abaa0376-d98d-4aae-9e56-cfaca1701024"

    // Real record shapes (Kimi Code 2.1.x wire.jsonl).
    static func journal(createdAt: Int64, prompt: String, toolsLine: Bool = true) -> String {
        var lines = [
            #"{"type":"metadata","protocol_version":"1.5","created_at":\#(createdAt)}"#,
            #"{"type":"runtime.set_binding","workspaceId":"wd_qa_01aea07dac60","runtimeId":"local","agentId":"main","time":\#(createdAt + 30)}"#,
        ]
        if toolsLine {
            // No time on it: the same bytes in every session.
            lines.append(#"{"type":"mcp.tools_discovered","agentId":"main","serverName":"automations","hash":"76f0","tools":[]}"#)
        }
        lines.append(#"{"type":"turn.prompt","agentId":"main","input":[{"type":"text","text":"\#(prompt)"}],"origin":{"kind":"user"},"turnId":0,"time":\#(createdAt + 100)}"#)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Ids

    @Test("Kimi session ids are recognized, and read off a journal's path")
    func sessionIDs() {
        #expect(AgentSessionLocator.isKimiSessionID(Self.newID))
        #expect(!AgentSessionLocator.isKimiSessionID("abaa0376-d98d-4aae-9e56-cfaca1701024"))
        #expect(!AgentSessionLocator.isKimiSessionID("session_x; rm -rf ~"))
        let path = "/home/ubuntu/.kimi-code/sessions/wd_qa_01aea07dac60/\(Self.newID)/agents/main/wire.jsonl"
        #expect(AgentSessionLocator.kimiSessionID(inPath: path) == Self.newID)
        #expect(AgentSessionLocator.kimiSessionID(inPath: "/home/ubuntu/.claude/projects/x/y.jsonl") == nil)
    }

    @Test("A pinned Kimi session resumes BY ID, never the folder's latest")
    @MainActor func resumeByID() {
        var s = AgentSession(profileID: UUID(), tool: .kimi, title: "x", cwd: "~/qa")
        #expect(AgentSessionEngine.resumeFlags(for: s) == "-c")
        #expect(AgentSessionEngine.resumeFlags(for: s, sharedFolder: true) == "")
        s.agentTranscriptID = Self.newID
        #expect(AgentSessionEngine.resumeFlags(for: s) == "-S \(Self.newID)")
        // Its own id beats the shared-folder fresh start too.
        #expect(AgentSessionEngine.resumeFlags(for: s, sharedFolder: true) == "-S \(Self.newID)")
        // A Claude id on a Kimi session (never valid) is ignored.
        s.agentTranscriptID = "abaa0376-d98d-4aae-9e56-cfaca1701024"
        #expect(AgentSessionEngine.resumeFlags(for: s) == "-c")
    }

    @Test("The chunk command reads the pinned journal first, else floors by creation")
    func chunkCommandPin() throws {
        let pinned = try #require(CodingTaskEngine.transcriptChunkCommand(
            guestCwd: "/home/ubuntu/qa", since: 0, agent: "kimi", pinnedWindow: 1,
            pin: TranscriptPin(kimiSession: Self.newID),
            knownPath: nil, knownOffset: -1, bytes: 8_000_000, earlier: false))
        #expect(pinned.contains("wd_*/\(Self.newID)/agents/main/wire.jsonl"))
        #expect(!pinned.contains("transcript-1.path"))   // Kimi writes no per-window record
        let floored = try #require(CodingTaskEngine.transcriptChunkCommand(
            guestCwd: "/home/ubuntu/qa", since: 1_791_069_633, agent: "kimi", pinnedWindow: 1,
            pin: TranscriptPin(kimiCreatedSince: 1_791_069_631),
            knownPath: nil, knownOffset: -1, bytes: 8_000_000, earlier: false))
        #expect(floored.contains("\"created_at\":[0-9]*"))
        #expect(floored.contains("-ge 1791069631000"))
        // Another agent never takes a Kimi pin.
        let claude = try #require(CodingTaskEngine.transcriptChunkCommand(
            guestCwd: "/home/ubuntu/qa", since: 0, agent: "claude", pinnedWindow: 1,
            pin: TranscriptPin(kimiSession: Self.newID),
            knownPath: nil, knownOffset: -1, bytes: 8_000_000, earlier: false))
        #expect(!claude.contains(Self.newID))
        #expect(claude.contains("transcript-1.path"))
    }

    // MARK: Locator, executed against a fixture store

    private func run(_ cmd: String, home: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func write(home: URL, id: String, body: String, modified: Date) throws {
        let d = home.appendingPathComponent(".kimi-code/sessions/wd_qa_000000000000/\(id)/agents/main")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let f = d.appendingPathComponent("wire.jsonl")
        try body.write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: f.path)
    }

    @Test("A journal begun before this run never stands in for it, however fresh its writes")
    func creationFloorAndPin() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kimi-locator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let launch: Int64 = 1_791_069_633   // the agent's start (epoch s)
        // The previous conversation, begun before the launch but written to
        // most recently (another tab still at it), and this run's own.
        try write(home: home, id: Self.oldID,
                  body: Self.journal(createdAt: (launch - 43) * 1000, prompt: "OLD"),
                  modified: Date())
        try write(home: home, id: Self.newID,
                  body: Self.journal(createdAt: (launch + 7) * 1000, prompt: "NEW"),
                  modified: Date().addingTimeInterval(-60))
        let cwd = home.appendingPathComponent("qa").path
        func located(_ pin: TranscriptPin) throws -> String {
            let cmd = try #require(CodingTaskEngine.planTranscriptCommand(
                guestCwd: cwd, since: 7, agent: "kimi", pin: pin))
            // GNU-isms the guest has and macOS's BSD tools don't.
            return try run(cmd.replacingOccurrences(of: "-newermt @86400 ", with: "")
                .replacingOccurrences(of: "xargs -r", with: "xargs"), home: home)
        }
        // mtime alone: the old conversation wins (the bug).
        #expect(try located(TranscriptPin()).contains("\"OLD\""))
        // Floored by creation: this run's journal.
        let fresh = try located(TranscriptPin(kimiCreatedSince: Int(launch) - 2))
        #expect(fresh.contains("\"NEW\"") && !fresh.contains("\"OLD\""))
        // Nothing begun yet (Kimi creates its session at the first prompt):
        // nothing, rather than somebody else's.
        #expect(try located(TranscriptPin(kimiCreatedSince: Int(launch) + 60)).isEmpty)
        // Pinned: that session's journal, whatever else is newer.
        let pinned = try located(TranscriptPin(kimiSession: Self.newID))
        #expect(pinned.contains("\"NEW\"") && !pinned.contains("\"OLD\""))
    }

    @Test("Two Kimi tabs in one folder: another session's journal is never this tab's")
    func otherSessionsJournalExcluded() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kimi-excl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        // K2's conversation (pinned to K2), written just now; the second
        // Kimi's own, a moment older.
        try write(home: home, id: Self.oldID, body: Self.journal(createdAt: 1_000, prompt: "K2"),
                  modified: Date())
        try write(home: home, id: Self.newID, body: Self.journal(createdAt: 2_000, prompt: "MINE"),
                  modified: Date().addingTimeInterval(-30))
        let cwd = home.appendingPathComponent("qa").path
        func located(_ pin: TranscriptPin) throws -> String {
            let cmd = try #require(CodingTaskEngine.planTranscriptCommand(
                guestCwd: cwd, since: 7, agent: "kimi", pin: pin))
            return try run(cmd.replacingOccurrences(of: "-newermt @86400 ", with: "")
                .replacingOccurrences(of: "xargs -r", with: "xargs"), home: home)
        }
        #expect(try located(TranscriptPin()).contains("\"K2\""))          // by folder: K2's (the bug)
        var pin = TranscriptPin()
        pin.kimiExclude = [Self.oldID]
        let mine = try located(pin)
        #expect(mine.contains("\"MINE\"") && !mine.contains("\"K2\""))
        // Only well-formed ids are spliced into the filter.
        #expect(AgentSessionLocator.kimiExcludeFilter(["session_x'; rm -rf ~"]).isEmpty)
    }

    @Test("An unpinned Kimi tab: the session its process names, else a fresh run's own journal, never another's")
    func unpinnedPin() {
        let named = TranscriptPin.kimiUnpinned(argsSession: Self.newID, resumed: true, since: 100,
                                               exclude: [Self.oldID])
        #expect(named.kimiSession == Self.newID && named.kimiExclude.isEmpty)
        let fresh = TranscriptPin.kimiUnpinned(argsSession: nil, resumed: false, since: 100,
                                               exclude: [Self.oldID, "junk"])
        #expect(fresh.kimiSession == nil && fresh.kimiCreatedSince == 98 && fresh.kimiExclude == [Self.oldID])
        let resumed = TranscriptPin.kimiUnpinned(argsSession: nil, resumed: true, since: 100, exclude: [])
        #expect(resumed.kimiCreatedSince == nil)
    }

    @Test("The floor probe reports the Kimi session a process names and whether it resumed")
    func floorProbeFields() {
        let p = AgentSessionLocator.parseFloorProbe("/home/ubuntu/qa\n1791069633\n\(Self.newID)\n1\n")
        #expect(p?.cwd == "/home/ubuntu/qa" && p?.since == 1_791_069_633)
        #expect(p?.kimiSession == Self.newID && p?.resumed == true)
        // An older probe (two lines) still parses.
        let old = AgentSessionLocator.parseFloorProbe("/home/ubuntu/qa\n5\n")
        #expect(old?.since == 5 && old?.kimiSession == nil && old?.resumed == false)
        #expect(AgentSessionLocator.parseFloorProbe("/x\n0\nsession_bogus\n0")?.kimiSession == nil)
        let cmd = AgentSessionLocator.floorProbeCommand(window: 2)
        #expect(cmd.contains("ks=") && cmd.contains("rs=") && cmd.contains("' -S '"))
    }

    @Test("The Kimi sessions other sessions on the machine own")
    @MainActor func claimedSessions() {
        let store = AgentSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(UUID().uuidString).json"))
        let ws = UUID()
        var k2 = AgentSession(profileID: ws, tool: .kimi, title: "K2", cwd: "~/qa", windowIndex: 1)
        k2.agentTranscriptID = Self.oldID
        var mine = AgentSession(profileID: ws, tool: .kimi, title: "Kimi in qa", cwd: "~/qa", windowIndex: 2)
        mine.agentTranscriptID = nil
        var elsewhere = AgentSession(profileID: UUID(), tool: .kimi, title: "x", cwd: "~/qa")
        elsewhere.agentTranscriptID = Self.newID
        for s in [k2, mine, elsewhere] { store.upsert(s) }
        #expect(store.kimiSessionsClaimed(profileID: ws, besides: mine.id) == [Self.oldID])
        #expect(store.kimiSessionsClaimed(profileID: ws, besides: k2.id).isEmpty)
    }

    // MARK: The local copy

    @Test("The copy never splices another Kimi journal in, even through shared lines")
    func copyRefusesAnotherJournal() throws {
        let old = Data(Self.journal(createdAt: 1_791_069_590_497, prompt: "OLD").utf8)
        let new = Data(Self.journal(createdAt: 1_791_069_640_228, prompt: "NEW").utf8)
        // Newer, and sharing the tool-discovery line: still another conversation.
        #expect(SessionTranscriptCache.merge(history: old, incoming: new, mode: .related) == nil)
        #expect(SessionTranscriptCache.merge(history: old, incoming: new, mode: .overlapOnly) == nil)
        // The same journal grown: merged.
        let grown = Data((String(decoding: old, as: UTF8.self)
            + #"{"type":"turn.prompt","agentId":"main","input":[{"type":"text","text":"MORE"}],"origin":{"kind":"user"},"turnId":1,"time":1791069700000}"#
            + "\n").utf8)
        let merged = try #require(SessionTranscriptCache.merge(history: old, incoming: grown, mode: .related))
        #expect(String(decoding: merged, as: UTF8.self).contains("MORE"))
        // A window of the same journal without its start record: merged.
        let tail = Data((#"{"type":"turn.prompt","agentId":"main","input":[{"type":"text","text":"TAIL"}],"origin":{"kind":"user"},"turnId":2,"time":1791069800000}"#
            + "\n").utf8)
        #expect(SessionTranscriptCache.merge(history: old, incoming: tail, mode: .related) != nil)
        // An OLDER conversation arriving after a newer one: refused by its time too.
        let olderTail = Data((#"{"type":"turn.prompt","agentId":"main","input":[{"type":"text","text":"STALE"}],"origin":{"kind":"user"},"turnId":0,"time":1791069000000}"#
            + "\n").utf8)
        #expect(SessionTranscriptCache.merge(history: new, incoming: olderTail, mode: .related) == nil)
        // The session's own next conversation, handed over as a continuation.
        let next = try #require(SessionTranscriptCache.merge(history: old, incoming: new, mode: .continuation))
        let text = String(decoding: next, as: UTF8.self)
        #expect(text.contains("OLD") && text.contains("NEW"))
    }
}
