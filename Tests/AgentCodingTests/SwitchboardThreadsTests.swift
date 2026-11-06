import Foundation
import Testing
@testable import bromure_ac

@Suite("Switchboard threads")
struct SwitchboardThreadsTests {
    private let pay = UUID(), login = UUID(), infra = UUID()
    private var aliases: [SwitchboardThreading.Alias] {
        [("add-apple-pay", pay), ("fix-login", login), ("infra", infra)].map { h, id in
            SwitchboardThreading.Alias(text: h, key: h, name: h, sessionID: id)
        }
    }
    private func user(_ id: Int, _ s: String) -> TranscriptItem { TranscriptItem(id: id, kind: .userText(s), timestamp: nil) }
    private func reply(_ id: Int, _ s: String) -> TranscriptItem { TranscriptItem(id: id, kind: .assistantText(s), timestamp: nil) }
    private func tool(_ id: Int, session: String?) -> TranscriptItem {
        let detail = session.map { #"{"session":"\#($0)","text":"hi"}"# } ?? #"{"workspace":"w"}"#
        return TranscriptItem(id: id, kind: .toolUse(name: "mcp__switchboard__x", summary: "", detail: detail), timestamp: nil)
    }
    private func result(_ id: Int) -> TranscriptItem {
        TranscriptItem(id: id, kind: .toolResult(tool: "x", content: "ok", isError: false), timestamp: nil)
    }
    private func run(_ items: [TranscriptItem]) -> ThreadedConversation { SwitchboardThreading.analyze(items, aliases: aliases) }

    @Test("a compound handle is a name anywhere; a one-word one only when marked as a name or leading its line")
    func mentions() {
        let m = { SwitchboardThreading.mentions(in: $0, aliases: self.aliases) }
        #expect(m("then add-apple-pay said so") == ["add-apple-pay"])
        #expect(m("the infra team uses this") == [], "plain English isn't a session")
        #expect(m("ask @infra about it") == ["infra"])
        #expect(m("see `infra` and **infra**") == ["infra"])
        #expect(m("• infra is done") == ["infra"])
        #expect(m("Infra is done") == ["infra"])
        #expect(m("add-apple-pay-v2 is another") == [], "part of a longer name")
        #expect(m("fix-login then add-apple-pay") == ["fix-login", "add-apple-pay"])
    }

    @Test("a longer name wins over a shorter one inside it")
    func longestName() {
        let a = ["api", "api-docs"].map { SwitchboardThreading.Alias(text: $0, key: $0, name: $0, sessionID: UUID()) }
            .sorted { $0.text.count > $1.text.count }
        #expect(SwitchboardThreading.mentions(in: "`api-docs` is done", aliases: a) == ["api-docs"])
    }

    @Test("a notice belongs to the session it names, even one no longer known")
    func notices() {
        let c = run([user(1, "[Switchboard] “add-apple-pay” needs you — call next_events."),
                     user(2, "[Switchboard] “Gone Session” finished its turn — call next_events.")])
        #expect(c.threadsOf[1] == ["add-apple-pay"])
        #expect(c.threadsOf[2] == ["gone session"])
        #expect(c.thread("gone session")?.name == "Gone Session")
        #expect(c.thread("gone session")?.sessionID == nil)
        #expect(c.thread("add-apple-pay")?.sessionID == pay)
    }

    @Test("a tool call belongs to the session it names, by @nickname too, and its result with it")
    func tools() {
        let c = run([tool(1, session: "fix-login"), result(2), tool(3, session: "@infra"), result(4)])
        #expect(c.threadsOf[1] == ["fix-login"] && c.threadsOf[2] == ["fix-login"])
        #expect(c.threadsOf[3] == ["infra"] && c.threadsOf[4] == ["infra"])
    }

    @Test("a reply naming nobody is about its turn, if that's one thing")
    func inherit() {
        let one = run([user(1, "[Switchboard] “fix-login” finished its turn — call next_events."), tool(2, session: "fix-login"),
                       reply(3, "All tests pass.")])
        #expect(one.threadsOf[3] == ["fix-login"])
        let two = run([tool(1, session: "fix-login"), tool(2, session: "infra"), reply(3, "Both done.")])
        #expect(two.threadsOf[3] == nil, "two sessions in the turn: can't tell")
        let next = run([user(1, "[Switchboard] “fix-login” finished its turn — call next_events."), reply(2, "Done."),
                        user(3, "What time is it?"), reply(4, "Late.")])
        #expect(next.threadsOf[4] == nil, "your next message starts a new turn")
    }

    @Test("an overview splits by session, unique ids, options staying with their session, code whole")
    func split() {
        let text = "Here's where things stand:\n\n• add-apple-pay needs you:\n\n1. Stripe\n2. Adyen\n\n• fix-login passes:\n\n```\n• not a bullet add-apple-pay\n```\n\n• `infra` is idle."
        let c = run([reply(7, text)])
        #expect(c.items.count == 4)
        #expect(c.items.first?.id == 7)
        #expect(Set(c.items.map(\.id)).count == 4)
        #expect(c.threadsOf[c.items[0].id] == nil)
        #expect(c.threadsOf[c.items[1].id] == ["add-apple-pay"])
        #expect(c.threadsOf[c.items[3].id] == ["infra"])
        guard case .assistantText(let a) = c.items[1].kind, case .assistantText(let b) = c.items[2].kind else {
            Issue.record("not replies"); return
        }
        #expect(a.contains("2. Adyen"))
        #expect(b.contains("```\n• not a bullet"))
    }

    @Test("a reply about one session isn't cut up")
    func noSplit() {
        let c = run([reply(1, "fix-login passes.\n\nIt's ready for review.")])
        #expect(c.items.count == 1)
        #expect(c.threadsOf[1] == ["fix-login"])
    }

    @Test("one thread's view has its items and what you said that led to them, nothing else")
    func filter() {
        let c = run([user(1, "Please check on things."), tool(2, session: "fix-login"), tool(3, session: "infra"),
                     user(4, "[Switchboard] “infra” finished its turn — call next_events."), reply(5, "Idle now.")])
        #expect(c.items(in: "fix-login").map(\.id) == [1, 2])
        #expect(c.items(in: "infra").map(\.id) == [1, 3, 4, 5])
        #expect(c.items(in: nil).count == 5)
    }

    @Test("a filter whose thread has gone counts as no filter, not as a blank chat")
    func strandedFilter() {
        let c = run([tool(1, session: "fix-login"), reply(2, "Nothing else.")])
        #expect(c.effective("fix-login") == "fix-login")
        #expect(c.effective("nobody") == nil)
        #expect(c.items(in: "nobody").count == c.items.count)
        #expect(run([]).items(in: "fix-login").isEmpty && run([]).effective("fix-login") == nil)
    }

    @Test("a CRLF reply splits like any other")
    func crlf() {
        let c = run([reply(1, "• add-apple-pay waits\r\n\r\n• fix-login passes")])
        #expect(c.items.count == 2)
        #expect(c.threadsOf[c.items[1].id] == ["fix-login"])
    }

    @Test("a call whose input is raw text is placed by the name in it, when there's one")
    func rawDetail() {
        func raw(_ id: Int, _ s: String) -> TranscriptItem {
            TranscriptItem(id: id, kind: .toolUse(name: "x", summary: "", detail: s), timestamp: nil)
        }
        let c = run([raw(1, "read_session fix-login"), raw(2, "fix-login and add-apple-pay"), raw(3, "ls -la")])
        #expect(c.threadsOf[1] == ["fix-login"])
        #expect(c.threadsOf[3] == ["fix-login"], "no name: the turn's thread, as ever")
        let json = run([TranscriptItem(id: 1, kind: .toolUse(name: "start", summary: "", detail: #"{"message":"like fix-login"}"#), timestamp: nil)])
        #expect(json.threadsOf[1] == nil, "an object says what it means: words in its text don't count")
    }

    @Test("a header marks each change of subject, not each row; your message ends the run")
    func headers() {
        let c = run([tool(1, session: "fix-login"), reply(2, "fix-login passes."), tool(3, session: "infra"),
                     user(4, "Thanks"), tool(5, session: "infra")])
        let rows: [TranscriptRow] = [.activity([c.items[0]]), .item(c.items[1]), .activity([c.items[2]]), .item(c.items[3]), .activity([c.items[4]])]
        let h = c.headers(rows)
        #expect(h[1] == ["fix-login"])
        #expect(h[2] == nil)
        #expect(h[3] == ["infra"])
        #expect(h[5] == ["infra"])
    }

    @Test("a notice heads itself: the reply under it needs no header of its own")
    func noticeHeads() {
        let c = run([user(1, "[Switchboard] “infra” finished its turn — call next_events."), reply(2, "Idle.")])
        #expect(c.headers([.item(c.items[0]), .item(c.items[1])]).isEmpty)
    }

    @Test("threads list most recent first, in different colours, stable from run to run")
    func threads() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [TranscriptItem(id: 1, kind: .assistantText("fix-login ok"), timestamp: t0),
                     TranscriptItem(id: 2, kind: .assistantText("add-apple-pay ok"), timestamp: t0.addingTimeInterval(9))]
        let c = run(items)
        #expect(c.threads.map(\.id) == ["add-apple-pay", "fix-login"])
        #expect(c.threads[0].hue != c.threads[1].hue)
        #expect(ThreadInk.seed("fix-login") == ThreadInk.seed("fix-login"))
        let many = (0..<ThreadInk.count).map { "session-\($0)-x" }
        let a = many.map { SwitchboardThreading.Alias(text: $0, key: $0, name: $0, sessionID: UUID()) }
        let hues = SwitchboardThreading.analyze(many.enumerated().map { reply($0.offset, "\($0.element) ok") }, aliases: a).threads.map(\.hue)
        #expect(Set(hues).count == ThreadInk.count, "no two the same while there are colours to go round")
    }

    @Test("the fat client's mirror gets the same handles as the host")
    func handles() {
        var a = AgentSession(profileID: UUID(), tool: .claude, title: "Fix the login page now please", windowIndex: 1)
        a.createdAt = Date(timeIntervalSince1970: 1)
        var b = AgentSession(profileID: a.profileID, tool: .claude, title: "Fix the login page again", windowIndex: 2)
        b.createdAt = Date(timeIntervalSince1970: 2)
        var n = AgentSession(profileID: a.profileID, tool: .claude, title: "Other", windowIndex: 3)
        n.nickname = "infra"
        let h = SwitchboardEngine.handles(of: [b, a, n])
        #expect(h[a.id] == "fix-the-login")
        #expect(h[b.id] == "fix-the-login-2")
        #expect(h[n.id] == "infra")
    }
}
