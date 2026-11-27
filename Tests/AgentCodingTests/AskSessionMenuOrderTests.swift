import Foundation
import Testing
@testable import bromure_ac

// Code review → "Ask a Session to Fix It": the menu listed the sessions in
// store order, not by name.
@Suite("Ask a session: menu order")
struct AskSessionMenuOrderTests {
    private func p(_ nick: String, _ title: String = "t", _ ws: String = "", assigned: Bool = true) -> PeerMention {
        PeerMention(sessionID: UUID(), nick: nick, title: title, workspace: ws, assigned: assigned)
    }

    @Test("by the name shown, Finder's order, case aside; ties by workspace")
    func order() {
        let peers = [p("zeta"), p("agent-10"), p("Beta"), p("agent-2"), p("x", "Alpha task", assigned: false),
                     p("mid", "t", "B"), p("mid", "t", "A")]
        #expect(PeerMention.byName(peers).map { $0.assigned ? $0.nick + "/" + $0.workspace : $0.title }
                == ["agent-2/", "agent-10/", "Alpha task", "Beta/", "mid/A", "mid/B", "zeta/"])
    }

    @Test("the menu lists them that way")
    func wiring() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/AutomationHubView.swift"), encoding: .utf8)
        #expect(src.contains("ForEach(PeerMention.byName(routing.sessions))"))
    }
}
