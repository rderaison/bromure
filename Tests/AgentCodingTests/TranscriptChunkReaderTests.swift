import Foundation
import SwiftUI
import Testing
@testable import bromure_ac

/// The beautified chat's transcript reader (`transcriptReaderPython`, run by
/// `transcriptChunkCommand`) on a long Claude session over a slow link —
/// the reported "remote chat sits on the thinking cue forever": every read
/// must be bounded by its window (a multi-MB record no longer drags a
/// first read far past it), "load earlier" must always make progress, and
/// a read that keeps failing must say so instead of an endless cue.
@Suite("Transcript chunk reader")
struct TranscriptChunkReaderTests {

    // MARK: Synthetic transcript

    private static func record(_ n: Int, role: String = "assistant", text: String? = nil) -> String {
        let body = text ?? "reply \(n) " + String(repeating: "lorem ipsum ", count: 40)
        let content = role == "user" ? "\"prompt \(n)\""
            : #"[{"type":"text","text":"\#(body)"}]"#
        return #"{"type":"\#(role)","uuid":"u-\#(n)","timestamp":"2026-10-07T10:00:00.000Z","message":{"role":"\#(role)","content":\#(content)}}"#
            + "\n"
    }

    /// A tool result of `bytes` (a giant `cat`, a screenshot's base64).
    private static func giant(_ n: Int, bytes: Int) -> String {
        let blob = String(repeating: "QUJDRA", count: bytes / 6)
        return #"{"type":"user","uuid":"g-\#(n)","timestamp":"2026-10-07T10:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t\#(n)","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(blob)"}}]}]}}"#
            + "\n"
    }

    /// ~`count` ordinary records with a giant one every `giantEvery`.
    private static func transcript(count: Int, giantEvery: Int = 0, giantBytes: Int = 0) -> Data {
        var s = ""
        for i in 0..<count {
            s += record(i, role: i % 5 == 0 ? "user" : "assistant")
            if giantEvery > 0, i % giantEvery == giantEvery - 1 { s += giant(i, bytes: giantBytes) }
        }
        return Data(s.utf8)
    }

    private struct Read { let size: Int; let start: Int; let end: Int; let bytes: Data }

    /// Runs the reader exactly as the guest does (python3 on stdin).
    private static func read(_ file: URL, known: String = "", offset: Int = -1, want: Int,
                             mode: String = "tail") throws -> Read {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-", file.path, known, String(offset), String(want), mode]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        input.fileHandleForWriting.write(Data(CodingTaskEngine.transcriptReaderPython.utf8))
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let f = try #require(TranscriptFetch.parse(Data("x\n\n".utf8) + out))
        return Read(size: f.size, start: f.start, end: f.end, bytes: f.chunk)
    }

    private static func temp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-\(UUID().uuidString).jsonl")
        try data.write(to: url)
        return url
    }

    private static func isLineStart(_ data: Data, _ offset: Int) -> Bool {
        offset == 0 || data[data.startIndex + offset - 1] == 0x0A
    }

    // MARK: Tests

    @Test("a first read takes a line-aligned window from the end, whole lines only")
    func firstReadBounded() throws {
        let data = Self.transcript(count: 3_000)
        let url = try Self.temp(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let want = 256_000
        let r = try Self.read(url, want: want)
        #expect(r.size == data.count)
        #expect(r.end == data.count)
        #expect(Self.isLineStart(data, r.start))
        #expect(r.end - r.start <= want + 2_000)    // back to the line it opened in, no further
        #expect(r.bytes == data[r.start..<r.end])
        #expect(!AgentTranscript.parse(r.bytes, agent: "claude").isEmpty)
    }

    @Test("a window opening inside a multi-MB record skips past it instead of shipping it")
    func giantStraddlerSkipped() throws {
        // [ordinary…][3 MB record][ordinary ~100 KB…]: a 256 KB window opens in the giant.
        var s = String(decoding: Self.transcript(count: 400), as: UTF8.self)
        s += Self.giant(9_999, bytes: 3_000_000)
        for i in 0..<180 { s += Self.record(10_000 + i) }
        let data = Data(s.utf8)
        let url = try Self.temp(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let want = 256_000
        let r = try Self.read(url, want: want)
        #expect(r.end == data.count)
        #expect(Self.isLineStart(data, r.start))
        #expect(r.end - r.start <= want)            // not the 3 MB record
        #expect(r.bytes.range(of: Data("g-9999".utf8)) == nil)
        // …and "load earlier" brings that record whole, then keeps going.
        let e = try Self.read(url, known: url.path, offset: r.start, want: want, mode: "earlier")
        #expect(e.end == r.start)
        #expect(e.end > e.start)
        #expect(e.bytes.range(of: Data("g-9999".utf8)) != nil)
        #expect(Self.isLineStart(data, e.start))
    }

    @Test("a giant LAST record still shows whole; an unfinished one waits")
    func giantLastRecord() throws {
        let head = String(decoding: Self.transcript(count: 200), as: UTF8.self)
        let big = Self.giant(1, bytes: 1_000_000)
        let data = Data((head + big).utf8)
        let url = try Self.temp(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try Self.read(url, want: 100_000)
        #expect(r.end == data.count)
        #expect(r.bytes.range(of: Data("g-1".utf8)) != nil)
        #expect(Self.isLineStart(data, r.start))
        // Being written (no newline yet): nothing past the last whole line.
        let open = Data((head + String(big.dropLast(10))).utf8)
        let url2 = try Self.temp(open)
        defer { try? FileManager.default.removeItem(at: url2) }
        let r2 = try Self.read(url2, want: 100_000)
        #expect(r2.end <= head.utf8.count)
        #expect(Self.isLineStart(open, r2.start))
        #expect(r2.bytes.last.map { $0 == 0x0A } ?? true)
    }

    @Test("polls read only new bytes; far behind, a read starts over at the end")
    func incrementalAndJump() throws {
        var data = Self.transcript(count: 1_000)
        let url = try Self.temp(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let want = 64_000
        let first = try Self.read(url, want: want)
        // Nothing new: an empty chunk at the cursor.
        let idle = try Self.read(url, known: url.path, offset: first.end, want: want)
        #expect(idle.start == first.end && idle.end == first.end && idle.bytes.isEmpty)
        // A little more: exactly the appended lines (plus not the half-written one).
        let more = Data((Self.record(5_000) + Self.record(5_001)).utf8)
        data.append(more)
        data.append(Data("{\"type\":\"assist".utf8))
        try data.write(to: url)
        let next = try Self.read(url, known: url.path, offset: first.end, want: want)
        #expect(next.start == first.end)
        #expect(next.bytes == more)
        // Away while the agent wrote far more than the jump factor allows:
        // a fresh window at the end, not tens of MB in one exec.
        var grown = data.prefix(next.end)
        for i in 0..<3_000 { grown.append(Data(Self.record(20_000 + i).utf8)) }
        try grown.write(to: url)
        #expect(grown.count - next.end > want * CodingTaskEngine.tailJumpFactor)
        let caught = try Self.read(url, known: url.path, offset: next.end, want: want)
        #expect(caught.start > next.end)
        #expect(caught.end == grown.count)
        #expect(caught.end - caught.start <= want + 2_000)
    }

    @Test("load earlier walks back to the file's start, every step making progress")
    func earlierReassembles() throws {
        let data = Self.transcript(count: 600, giantEvery: 150, giantBytes: 300_000)
        let url = try Self.temp(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let want = 100_000
        let first = try Self.read(url, want: want)
        var held = first.bytes
        var base = first.start
        var steps = 0
        while base > 0, steps < 500 {
            let e = try Self.read(url, known: url.path, offset: base, want: want, mode: "earlier")
            #expect(e.end == base)
            #expect(e.start < base)                 // never stuck on a long line
            #expect(Self.isLineStart(data, e.start))
            held = e.bytes + held
            base = e.start
            steps += 1
        }
        #expect(base == 0)
        #expect(held == data)
    }

    @Test("a history that starts mid-record, with huge lines and images, still parses")
    func parserToleratesEdges() throws {
        var s = "AAAAQUJDRA\"}}]}}\n"                                      // the end of a cut record
        s += Self.record(1, role: "user")
        s += Self.giant(2, bytes: 2_000_000)                                 // 2 MB screenshot
        s += Self.record(3, text: String(repeating: "x", count: 1_500_000))  // 1.5 MB reply
        s += Self.record(4, role: "user")
        let items = AgentTranscript.parse(Data(s.utf8), agent: "claude")
        let prompts = items.filter { if case .userText = $0.kind { return true }; return false }
        #expect(prompts.count == 2)
        #expect(items.contains { if case .assistantText(let t) = $0.kind { return t.count > 1_000_000 }; return false })
    }

    @Test("no find floor is written as a pre-1970 date west of Greenwich")
    func findFloorClamped() throws {
        #expect(AgentSessionLocator.findEpoch(0) == 86_400)
        #expect(AgentSessionLocator.findEpoch(1_791_416_966) == 1_791_416_966)
        let cmd = try #require(CodingTaskEngine.transcriptChunkCommand(
            guestCwd: "/Users/me/proj", since: 0, agent: "claude", pinnedWindow: 1,
            knownPath: nil, knownOffset: -1, bytes: 1_500_000, earlier: false))
        #expect(!cmd.contains("-newermt @0 ") && !cmd.contains("-newermt @0)"))
        #expect(!AgentSessionLocator.floorProbeCommand(window: 1).contains("@0"))
    }

    /// The reported case end to end: a RESUMED Claude (floor 0) on a Bromure
    /// Sidecar in New York. Its `find` shim turns `@<epoch>` into a local
    /// date for BSD find; `@0` became "1969-12-31 19:00:00", which BSD find
    /// can't parse — the pinned transcript was never found and the chat sat
    /// on the thinking cue. Runs the real chunk command through that shim.
    @Test("a resumed session on a Sidecar west of Greenwich finds its pinned transcript")
    func resumedSidecarFindsPinned() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("sidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        let proj = home.appendingPathComponent(".claude/projects/-Users-me-proj", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".bromure"), withIntermediateDirectories: true)
        let jsonl = proj.appendingPathComponent("c5d43ba1-d733-4f7e-af0f-fa4356a8ef07.jsonl")
        let data = Self.transcript(count: 300)
        try data.write(to: jsonl)
        try (jsonl.path + "\n%1 \n").write(to: home.appendingPathComponent(".bromure/transcript-1.path"),
                                          atomically: true, encoding: .utf8)
        func exe(_ name: String, _ body: String) throws {
            let u = bin.appendingPathComponent(name)
            try body.write(to: u, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        }
        try exe("tmux", "#!/bin/sh\necho %1\n")
        // The Sidecar's find shim as shipped before the fix: @epoch → local date.
        try exe("find", """
            #!/bin/bash
            args=(); conv=0
            for a in "$@"; do
              if [ $conv = 1 ] && [[ "$a" == @* ]]; then a=$(/bin/date -r "${a#@}" '+%Y-%m-%d %H:%M:%S'); fi
              conv=0
              case "$a" in -newer[amcB]t) conv=1 ;; esac
              args+=("$a")
            done
            exec /usr/bin/find "${args[@]}"
            """)
        let cmd = try #require(CodingTaskEngine.transcriptChunkCommand(
            guestCwd: "/Users/me/proj", since: 0, agent: "claude", pinnedWindow: 1,
            knownPath: nil, knownOffset: -1, bytes: 64_000, earlier: false))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", cmd]
        p.environment = ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin",
                         "TZ": "America/New_York"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let raw = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let f = try #require(TranscriptFetch.parse(raw))
        #expect(f.path == jsonl.path)
        #expect(f.end == data.count)
        #expect(!f.chunk.isEmpty)
    }
}

// MARK: - Failed reads surface as an error, not a perpetual cue

@Suite("Transcript load state")
@MainActor
struct TranscriptLoadStateTests {

    @Test("the tracker calls an empty chat failed after repeated failures, never a populated one")
    func tracker() {
        var t = TranscriptLoadTracker()
        let now = Date()
        #expect(t.record(.failed, at: now, showing: false, working: true) == nil)
        #expect(t.record(.failed, at: now, showing: false, working: true) == .failed)
        #expect(t.record(.failed, at: now, showing: true, working: true) == nil)
        let fetch = TranscriptFetch(path: "/p", pq: Data(), size: 1, start: 0, end: 1, chunk: Data("x".utf8))
        #expect(t.record(.fetched(fetch), at: now, showing: false, working: true) == nil)
        #expect(t.failStreak == 0)
        // No transcript while the agent works: only after the grace period.
        #expect(t.record(.none, at: now, showing: false, working: true) == nil)
        #expect(t.record(.none, at: now.addingTimeInterval(TranscriptLoadTracker.missingGrace + 1),
                         showing: false, working: true) == .notFound)
        // An idle agent with no transcript is just a fresh session.
        #expect(t.record(.none, at: now.addingTimeInterval(100), showing: false, working: false) == nil)
    }

    /// A working agent whose transcript reads all time out (the fat client's
    /// exec over a slow tunnel), then come back.
    private final class Provider: BeautifiedTranscriptProvider {
        var failing = true
        var accent: Color { .blue }
        func activeTabIndex() -> Int? { 0 }
        func isWorking() -> Bool { true }
        func guestFileOp(_ op: [String: Any]) async -> [String: Any]? { nil }
        func execGuest(_ command: String, timeout: Int) async -> String? {
            if command.contains("capture-pane") { return "" }
            if command.contains("pane_current_path") { return "/home/ubuntu/p\n0\n" }
            guard command.contains("BROMURE_PY") else { return "" }
            if failing { return nil }   // timed out
            let body = #"{"type":"user","message":{"role":"user","content":"hello"},"timestamp":"2026-10-07T10:00:00Z"}"# + "\n"
            return "/home/ubuntu/.claude/projects/p/s.jsonl\n\n\(body.utf8.count)\n0\n\(body.utf8.count)\n" + body
        }
    }

    @Test("a timed-out first read shows an error with Retry, not an endless thinking cue")
    func timedOutReadSurfaces() async {
        let provider = Provider()
        let model = BeautifiedSessionModel(provider: provider)
        model.start()
        defer { model.stop() }
        var until = Date().addingTimeInterval(60)
        while model.loadIssue == nil, Date() < until { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(model.loadIssue == .failed)
        #expect(model.items.isEmpty)
        #expect(model.working)              // the agent IS working…
        #expect(!model.showsLiveCue)        // …but the chat says why it's empty instead
        #expect(!model.loading)
        // Retry once the link is back: the conversation shows, the error goes.
        provider.failing = false
        model.retryLoad()
        until = Date().addingTimeInterval(60)
        while model.items.isEmpty, Date() < until { try? await Task.sleep(nanoseconds: 50_000_000) }
        #expect(!model.items.isEmpty)
        #expect(model.loadIssue == nil)
        #expect(model.showsLiveCue)
    }
}
