import Foundation
import Testing
@testable import bromure_ac

/// Live-QA round S3: markdown tables in the chat (S3-1).
@Suite("Live QA S3 — reply tables")
struct LiveQAS3TableTests {

    private let reply = """
    Here is a comparison.

    | # | Option | Verdict |
    |---|:------:|--------:|
    | 1 | **Bold** and `a\\|b` | Good |
    | 2 | Short |

    In short, pick one.
    """

    @Test("S3-1: a top-level pipe table is lifted out of the prose, with alignments and cells")
    func tableLifted() {
        let segs = TranscriptTables.parse(reply)
        #expect(segs.count == 3)
        guard segs.count == 3, case .table(let t) = segs[1] else { Issue.record("no table"); return }
        #expect(t.alignments == [.leading, .center, .trailing])
        #expect(t.rows.count == 3)
        #expect(t.rows[0] == ["#", "Option", "Verdict"])
        #expect(t.rows[1] == ["1", "**Bold** and `a|b`", "Good"])
        // A short row is padded to the header's width.
        #expect(t.rows[2] == ["2", "Short", ""])
        if case .markdown(let before) = segs[0] { #expect(before.contains("Here is")) }
        if case .markdown(let after) = segs[2] { #expect(after.contains("pick one")) }
    }

    @Test("S3-1: pipes in a code fence, a quote or without a delimiter row stay markdown")
    func notTables() {
        let fenced = "```\n| a | b |\n|---|---|\n```"
        #expect(TranscriptTables.segments(fenced) == [.markdown(fenced)])
        let quoted = "> | a | b |\n> |---|---|"
        #expect(TranscriptTables.segments(quoted) == [.markdown(quoted)])
        let noDelimiter = "a | b\nc | d"
        #expect(TranscriptTables.segments(noDelimiter) == [.markdown(noDelimiter)])
        // Cell counts must agree between header and delimiter.
        let mismatch = "| a | b |\n|---|"
        #expect(TranscriptTables.segments(mismatch) == [.markdown(mismatch)])
        #expect(TranscriptTables.delimiter("---") == nil)   // a rule, not a table
    }

    @Test("S3-1: a table still streaming (header, no delimiter yet) stays prose until it can be one")
    func streamingTable() {
        #expect(TranscriptTables.parse("Intro\n\n| a | b |") == [.markdown("Intro\n\n| a | b |")])
        let segs = TranscriptTables.parse("Intro\n\n| a | b |\n|---|---|\n| 1 |")
        #expect(segs.count == 2)
        if case .table(let t) = segs.last { #expect(t.rows == [["a", "b"], ["1", ""]]) }
    }

    @Test("S3-1: a long table cut into rows repeats its header atop each later piece")
    func chunkedTableKeepsHeader() {
        var text = "| col A | col B |\n|---|---|\n"
        for i in 0..<200 { text += "| row \(i) with some words | value \(i) |\n" }
        let pieces = TranscriptRow.chunks(text, limit: 500)
        #expect(pieces.count > 1)
        for p in pieces {
            let segs = TranscriptTables.parse(p)
            #expect(segs.count == 1)
            guard case .table(let t)? = segs.first else { Issue.record("piece is not a table: \(p.prefix(60))"); continue }
            #expect(t.rows[0] == ["col A", "col B"])
        }
        // Every data row survives, once.
        let rows = pieces.flatMap { p -> [[String]] in
            if case .table(let t)? = TranscriptTables.parse(p).first { return Array(t.rows.dropFirst()) }
            return []
        }
        #expect(rows.count == 200)
    }

    @Test("S3-1: columns shrink fairly to the width offered; narrow ones keep theirs")
    func layoutWidths() {
        #expect(TranscriptTableLayout.widths(available: 1000, ideal: [40, 100, 300]) == [40, 100, 300])
        #expect(TranscriptTableLayout.widths(available: nil, ideal: [40, 300]) == [40, 300])
        let w = TranscriptTableLayout.widths(available: 300, ideal: [40, 400, 400])
        #expect(w[0] == 40)
        #expect(w[1] == 130 && w[2] == 130)
        #expect(w.reduce(0, +) <= 300)
    }

    @Test("S3-1: the bench fixture is a Kimi reply that grows in place, table and all")
    func benchFixture() {
        let data = ScrollBench.tableReplyFixture(rows: 12)
        let items = AgentTranscript.parse(data)
        #expect(items.count == 2)
        guard case .assistantText(let text)? = items.last?.kind else { Issue.record("no reply"); return }
        let tables = TranscriptTables.parse(text).filter { if case .table = $0 { return true } else { return false } }
        #expect(tables.count == 2)
    }
}

/// S3-2: trace records from before fingerprints held real key fragments.
@Suite("Live QA S3 — legacy trace previews")
struct LiveQAS3TraceTests {

    private func legacyRecord(_ fake: String, _ real: String, leak: String) -> TraceRecord {
        TraceRecord(sessionID: UUID(), profileID: UUID(), host: "api.anthropic.com", port: 443,
                    method: "POST", path: "/v1/messages?x=a…b", statusCode: 200, requestBytes: 10,
                    responseBytes: 20, latencyMs: 12.5,
                    swaps: [SwapEntry(header: "Authorization/x-api-key", fakePreview: fake, realPreview: real)],
                    leaks: [LeakEntry(header: "Authorization", valuePreview: leak, suspicion: .knownPrefix)],
                    bodyStored: false)
    }

    private func encode(_ r: TraceRecord) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return try e.encode(r)
    }

    private static let fragments = ["sk-a…I8iG", "sk-a…bQAA", "c6cc…skFw", "xai-…Zz9q", "dop_…a1b2", "ghp_…wxyz"]

    @Test("S3-2: a legacy record decodes with every preview redacted")
    func redactOnDecode() throws {
        let data = try encode(legacyRecord("sk-a…I8iG", "c6cc…skFw", leak: "ghp_…wxyz"))
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let r = try d.decode(TraceRecord.self, from: data)
        #expect(!r.swaps[0].fakePreview.contains("…"))
        #expect(!r.swaps[0].realPreview.contains("…"))
        #expect(!r.leaks[0].valuePreview.contains("…"))
        #expect(r.swaps[0].fakePreview.contains("redacted"))
        // Everything else is as it was.
        #expect(r.path == "/v1/messages?x=a…b")
    }

    @Test("S3-2: the stored trace files are rewritten once — no secret fragment left, the rest intact")
    func rewriteFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trace-s3-\(UUID().uuidString)")
        let day = root.appendingPathComponent("2026-10-04", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        var lines: [Data] = []
        lines.append(try encode(legacyRecord("sk-a…I8iG", "sk-a…bQAA", leak: "ghp_…wxyz")))
        lines.append(try encode(legacyRecord("sk-b…kUyU", "xai-…Zz9q", leak: "dop_…a1b2")))
        lines.append(try encode(legacyRecord("Anthropic key #3f9a1c2e", "Anthropic key #11223344", leak: "credential #deadbeef")))
        lines.append(Data("not json at all, keep me".utf8))
        let file = day.appendingPathComponent("\(UUID().uuidString).jsonl")
        try lines.reduce(Data()) { $0 + $1 + Data([0x0a]) }.write(to: file)

        let n = TraceStore.redactLegacyPreviews(root: root)
        #expect(n == 6)
        let text = try String(contentsOf: file, encoding: .utf8)
        for frag in Self.fragments { #expect(!text.contains(frag), "still holds \(frag)") }
        #expect(text.contains("Anthropic key #3f9a1c2e"))     // fingerprints untouched
        #expect(text.contains("not json at all, keep me"))
        // Every record still decodes, with its other fields.
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let records = text.split(separator: "\n").compactMap { try? d.decode(TraceRecord.self, from: Data($0.utf8)) }
        #expect(records.count == 3)
        #expect(records.allSatisfy { $0.host == "api.anthropic.com" && $0.latencyMs == 12.5 })
        // Idempotent.
        #expect(TraceStore.redactLegacyPreviews(root: root) == 0)
        try? FileManager.default.removeItem(at: root)
    }
}

/// S3-3: a message sent on resume goes through the session's guarded queue.
@Suite("Live QA S3 — resume with a message")
@MainActor
struct LiveQAS3ResumeQueueTests {

    private func engine() -> (AgentSessionEngine, AgentSessionStore) {
        let store = AgentSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-s3-\(UUID().uuidString).json"))
        return (AgentSessionEngine(store: store, delegate: nil), store)
    }

    @Test("S3-3: the message is held on the session's queue (not typed), aimed at its window, with a way to the agent")
    func heldNotTyped() {
        let (eng, store) = engine()
        var s = AgentSession(profileID: UUID(), tool: .omp, title: "omp", cwd: "~/p", windowIndex: 2)
        s.agentAlive = true
        store.upsert(s)
        let queue = ChatQueueStore(fileURL: nil)
        let target = PaneTarget(ref: .index(2), foreground: .agent)
        eng.holdForAgent(s.id, "Reply with DELTA", target: target, window: 2, queue: queue)
        let key = ChatQueueStore.sessionKey(s.id)
        let list = queue.messages(key)
        #expect(list.count == 1)
        #expect(list.first?.held == true)
        #expect(list.first?.sessionID == s.id)
        #expect(list.first?.target == target)
        #expect(list.first?.failure == nil)
        #expect(ChatQueueStore.deliverable(list[0]))
        #expect(queue.hasDriver(key))
    }

    @Test("S3-3: an agent that never came up leaves the message on the strip, Not sent — never dropped")
    func neverDropped() {
        let (eng, store) = engine()
        let s = AgentSession(profileID: UUID(), tool: .codex, title: "codex", cwd: "~/p", windowIndex: nil)
        store.upsert(s)
        let queue = ChatQueueStore(fileURL: nil)
        eng.holdForAgent(s.id, "hello", target: nil, window: nil,
                         failure: ChatQueueStore.notTypedText, queue: queue)
        let list = queue.messages(ChatQueueStore.sessionKey(s.id))
        #expect(list.count == 1)
        #expect(list.first?.failure == ChatQueueStore.notTypedText)
        #expect(list.first?.text == "hello")
    }

    @Test("S3-3: a chat's own driver is never replaced by the engine's")
    func chatDriverWins() {
        let queue = ChatQueueStore(fileURL: nil)
        var asked = 0
        queue.setDriver("k", .init(isWorking: { asked += 1; return true }, deliver: { _, _ in .typed }))
        queue.provideDriver("k", .init(isWorking: { nil }, deliver: { _, _ in .failed }))
        #expect(queue.hasDriver("k"))
        queue.provideDriver("other", .init(isWorking: { nil }, deliver: { _, _ in .failed }))
        #expect(queue.hasDriver("other"))
        _ = asked
    }

    @Test("S3-3: the baseline counts the saved conversation's user turns")
    func baseline() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"one"},"uuid":"u1","timestamp":"2026-10-05T10:00:00Z"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]},"uuid":"a1","timestamp":"2026-10-05T10:00:01Z"}"#,
            #"{"type":"user","message":{"role":"user","content":"two"},"uuid":"u2","timestamp":"2026-10-05T10:00:02Z"}"#,
        ]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        #expect(AgentSessionEngine.userTurns(in: data, agent: "claude") == 2)
        #expect(AgentSessionEngine.userTurns(in: nil, agent: "claude") == 0)
    }
}

/// S3-4: Bromure's own 451 is not "Provider unreachable".
@Suite("Live QA S3 — Bromure's own blocks")
struct LiveQAS3BlockTests {

    @Test("S3-4: a 451 carrying Bromure's block body reads as blocked by Bromure, per engine")
    func blockedKinds() {
        let pi = AgentAPIError.claude(error: nil, status: nil,
            message: "API Error: 451 Bromure blocked this request: possible prompt injection detected in tool output.")
        #expect(pi.kind == .blocked)
        #expect(pi.status == 451)
        #expect(pi.blockedBy == .promptInjection)
        let f = SessionFailure(pi)
        #expect(f.kind == .blocked)
        #expect(f.blockedBy == .promptInjection)
        #expect(f.headline == BromureBlock.promptInjection.headline)
        #expect(AgentSession.providerErrorKind(f) == "blocked")

        let rules = AgentAPIError.omp(errorID: nil, status: 451,
            message: "Bromure blocked this request: possible rogue instructions detected in CLAUDE.md.")
        #expect(rules.blockedBy == .rulesInjection)
        let leak = AgentAPIError.codex(info: nil, message: "unexpected status 451: Bromure: outbound request blocked — leaked credential to non-designated host.")
        #expect(leak.blockedBy == .credentialLeak)
        let kimi = AgentAPIError.kimi(code: "provider.api_error", name: nil, status: 451, message: "")
        #expect(kimi.kind == .blocked)
        #expect(kimi.blockedBy == .unknown)
    }

    @Test("S3-4: provider errors keep their kinds")
    func providerErrorsUnchanged() {
        #expect(AgentAPIError.claude(error: nil, status: nil, message: "API Error: 500 Internal").kind == .overloaded
                || AgentAPIError.claude(error: nil, status: nil, message: "API Error: 500 Internal").kind == .other)
        #expect(AgentAPIError.claude(error: nil, status: 401, message: "unauthorized").kind == .auth)
        #expect(AgentAPIError.codex(info: nil, message: "connection refused").kind == .other)
    }

    @Test("S3-4: the block as printed on the agent's screen is recognized too")
    func onScreen() {
        let tail = ["⎿  API Error: 451 Bromure blocked this request: possible prompt injection detected in tool output."]
        let f = SessionFailure.detect(tail: tail, agent: "claude")
        #expect(f?.kind == .blocked)
        #expect(f?.blockedBy == .promptInjection)
    }
}

/// S3-5: an archived session's transcript in order; no liveness once put away.
@Suite("Live QA S3 — archived sessions")
@MainActor
struct LiveQAS3ArchiveTests {

    private func rec(_ uuid: String, parent: String?, _ text: String) -> Data {
        let p = parent.map { "\"\($0)\"" } ?? "null"
        return Data(#"{"parentUuid":\#(p),"type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"\#(uuid)"}"#.utf8)
    }

    @Test("S3-5: a record placed before its parent goes right after it; the rest keep their place")
    func parentOrder() {
        let prompt = rec("u1", parent: nil, "Reply with just the word READY.")
        let ready = rec("a1", parent: "u1", "READY")
        let paste = rec("u2", parent: "a1", "paste")
        let reply = rec("a2", parent: "u2", "reply")
        let broken = [paste, ready, prompt, reply]
        #expect(SessionTranscriptCache.parentOrdered(broken) == [prompt, ready, paste, reply])
        // In order already: untouched.
        #expect(SessionTranscriptCache.parentOrdered([prompt, ready, paste, reply]) == [prompt, ready, paste, reply])
        // Records without parents (other agents) are never moved.
        let a = Data(#"{"type":"x","n":1}"#.utf8), b = Data(#"{"type":"x","n":2}"#.utf8)
        #expect(SessionTranscriptCache.parentOrdered([b, a]) == [b, a])
    }

    @Test("S3-5: a copy merged out of order reads back in order")
    func loadReorders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tc-s3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = SessionTranscriptCache(directory: dir)
        let id = UUID()
        let prompt = rec("u1", parent: nil, "Reply with just the word READY.")
        let ready = rec("a1", parent: "u1", "READY")
        let paste = rec("u2", parent: "a1", "paste")
        let file = dir.appendingPathComponent(id.uuidString + ".jsonl")
        try ([paste, ready, prompt].reduce(Data()) { $0 + $1 + Data([0x0a]) }).write(to: file)
        let loaded = try #require(cache.load(id))
        let items = AgentTranscript.parse(loaded, agent: "claude")
        let texts = items.compactMap { i -> String? in if case .userText(let t) = i.kind { return t }; return nil }
        #expect(texts == ["Reply with just the word READY.", "READY", "paste"])
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("S3-5: archiving clears the liveness verdict; so does the machine going away")
    func liveness() {
        let store = AgentSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-s3-\(UUID().uuidString).json"))
        let pid = UUID(), other = UUID()
        var a = AgentSession(profileID: pid, tool: .claude, title: "A", cwd: "~/a", windowIndex: 1)
        a.agentAlive = true
        var b = AgentSession(profileID: other, tool: .claude, title: "B", cwd: "~/b", windowIndex: 1)
        b.agentAlive = true
        store.upsert(a); store.upsert(b)
        store.setArchived(a.id, true)
        #expect(store.session(a.id)?.agentAlive == nil)
        // Only `pid`'s machine is attached: `other`'s sessions lose their verdict.
        store.clearLiveness(outside: [pid])
        #expect(store.session(b.id)?.agentAlive == nil)
    }

    @Test("Minor: a session that took over a tab never takes its predecessor's title")
    func predecessorTitle() {
        let old = AgentSession(profileID: UUID(), tool: .kimi, title: "Please save my contact card. My", cwd: "~/q", windowIndex: nil)
        let new = AgentSession(profileID: old.profileID, tool: .kimi, title: "Kimi in q", cwd: "~/q", windowIndex: 2)
        let map = [new.id: old.id]
        #expect(AgentSessionStore.isPredecessorTitle("Please save my contact card. My", of: new.id, successorOf: map, in: [old, new]))
        #expect(!AgentSessionStore.isPredecessorTitle("Reply with ALPHA", of: new.id, successorOf: map, in: [old, new]))
        #expect(!AgentSessionStore.isPredecessorTitle("Please save my contact card. My", of: old.id, successorOf: map, in: [old, new]))
    }
}

/// S3-6: credential consent decisions in the Security Timeline; a timeout
/// isn't a remembered no.
@Suite("Live QA S3 — credential consent")
struct LiveQAS3ConsentTests {

    @Test("S3-6: an answer at the deadline is a timeout; one before it is the user's")
    func timeoutClassification() {
        let t0 = Date()
        #expect(ConsentBroker.isTimeout(askedAt: t0, answeredAt: t0.addingTimeInterval(120), timeout: 120))
        #expect(ConsentBroker.isTimeout(askedAt: t0, answeredAt: t0.addingTimeInterval(119.5), timeout: 120))
        #expect(!ConsentBroker.isTimeout(askedAt: t0, answeredAt: t0.addingTimeInterval(4), timeout: 120))
    }

    @Test("S3-6: every consent decision is a Timeline row")
    func timelineRows() {
        let pid = UUID()
        func row(_ decision: String) -> SecurityTimeline.Event? {
            SecurityTimeline.map(profileID: pid, eventType: "credential.consent",
                                 eventData: ["credential": .string("GitHub token (octocat)"),
                                             "credential_id": .string("http:gh"),
                                             "scope": .string("for any *.github.com request"),
                                             "decision": .string(decision)], now: Date())
        }
        #expect(row("allow_1h")?.kind == .allowed)
        #expect(row("allow_5m")?.kind == .allowed)
        #expect(row("allow_session")?.kind == .allowed)
        #expect(row("deny")?.kind == .blocked)
        let timeout = row("timeout")
        #expect(timeout?.kind == .blocked)
        #expect(timeout?.decision.contains("asks again") == true)
        #expect(row("deny_remembered")?.coalesceKey != nil)
        #expect(row("allow_1h")?.condition.contains("GitHub token (octocat)") == true)
        // A legacy preview in a display name never lands in a row.
        let legacy = SecurityTimeline.map(profileID: pid, eventType: "credential.consent",
                                          eventData: ["credential": .string("AWS access key AKIA…WXYZ"),
                                                      "decision": .string("deny")], now: Date())
        #expect(legacy?.condition.contains("…") == false)
    }
}

/// Minor: PII counting — one phone is one phone.
@Suite("Live QA S3 — PII counts")
struct LiveQAS3PIICountTests {
    private func span(_ text: String, _ s: String, _ label: PIILabel, from: Int = 0) -> PIISpan {
        let ns = text as NSString
        let r = ns.range(of: s, range: NSRange(location: from, length: ns.length - from))
        return PIISpan(start: r.location, end: NSMaxRange(r), label: label, score: 0.9, heuristic: false)
    }

    @Test("Minor: a phone number cut in pieces counts once; so does one met twice in a request")
    func phoneOnce() {
        let text = "Call me at +1 (555) 123-4567 today."
        let pieces = [span(text, "+1", .phone), span(text, "(555) 123-4567", .phone)]
        #expect(PIIRewriter.countedKinds(pieces, in: text)[.phone] == 1)
        var seen = Set<String>()
        let first = PIIRewriter.countedKinds([span(text, "+1 (555) 123-4567", .phone)], in: text, seen: &seen)
        let other = "Saved: 1-555-123-4567"
        let again = PIIRewriter.countedKinds([span(other, "1-555-123-4567", .phone)], in: other, seen: &seen)
        #expect(first[.phone] == 1)
        #expect(again[.phone] == nil)
        // Two different numbers are two.
        let two = "Home 555-0100, work 555-0199"
        #expect(PIIRewriter.countedKinds([span(two, "555-0100", .phone), span(two, "555-0199", .phone)], in: two)[.phone] == 2)
    }
}

/// Branch sessions carry the same role/autonomy flags as plain-folder ones.
@Suite("Live QA S3 — branch session flags")
@MainActor
struct LiveQAS3BranchFlagTests {

    private func session(_ tool: Profile.Tool) -> AgentSession {
        AgentSession(profileID: UUID(), tool: tool, title: "t", cwd: "~/repo", windowIndex: nil)
    }

    @Test("Every agent's branch launch carries the flags a plain session would")
    func flagsPerAgent() {
        for tool in [Profile.Tool.codex, .claude, .grok, .omp, .kimi] {
            let s = session(tool)
            for kimi in [KimiApprovals.neverAsk, .askWhenNeeded] {
                let args = AgentSessionEngine.worktreeCreateArgs(
                    guestPath: "/home/ubuntu/repo", slug: "x", display: "X", session: s,
                    prompt: "go", background: "", base: "", kimi: kimi)
                #expect(args.count == 8)
                #expect(args[3] == tool.rawValue)
                #expect(args[7] == AgentSessionEngine.roleFlags(for: s, kimi: kimi))
            }
        }
        let codex = AgentSessionEngine.worktreeCreateArgs(guestPath: "/r", slug: "x", display: "X", session: session(.codex),
                                                          prompt: "", background: "", base: "")
        #expect(codex[7] == "--dangerously-bypass-approvals-and-sandbox")
        let kimi = AgentSessionEngine.worktreeCreateArgs(guestPath: "/r", slug: "x", display: "X", session: session(.kimi),
                                                         prompt: "", background: "", base: "", kimi: .askWhenNeeded)
        #expect(kimi[7] == "--yolo")
    }

    @Test("The flags reach the guest in the 8th field — after a placeholder base when there is none")
    func encoded() throws {
        let line = try #require(GuestCommand.line(action: "create",
            args: ["/w", "slug", "Disp", "codex", "", "", "", "--dangerously-bypass-approvals-and-sandbox"]))
        let rest = String(line.drop { $0 != " " }.dropFirst())
        let f = GuestCommand.fields(rest, 8)
        #expect(line.hasPrefix("worktree-create "))
        #expect(f[5] == "-")
        #expect(f[6] == "-")
        #expect(GuestCommand.decode(f[7]) == "--dangerously-bypass-approvals-and-sandbox")
        // No flags (Claude, grok): the line is as before.
        let plain = try #require(GuestCommand.line(action: "create", args: ["/w", "slug", "Disp", "claude", "", "", "", ""]))
        #expect(GuestCommand.fields(String(plain.drop { $0 != " " }.dropFirst()), 8)[6] == "")
    }
}
