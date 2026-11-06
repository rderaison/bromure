import Foundation
import Testing
@testable import bromure_ac

/// Board report: the composer's Stop didn't always stop the agent. It sent
/// Esc, once, to every agent; Grok stops on Ctrl-C, and Claude running a
/// command can need a second Esc. Stop now sends the key the agent's own busy
/// line names (else its kind's), and once more while that line is still up.
@Suite("Stop sends the key each agent stops on")
struct StopKeyTests {
    typealias M = BeautifiedSessionModel

    @Test("the busy line says which key; else the agent's kind")
    func keys() {
        #expect(M.interruptKey(screen: "  ✻ Pondering… (12s · ↓ 1.2k tokens · esc to interrupt)\n", agent: "claude") == "Escape")
        #expect(M.interruptKey(screen: "◆ Run npm test 1m22s ↓20.6k [↓][stop]\n", agent: "grok") == "C-c")
        #expect(M.interruptKey(screen: "Thinking… (ctrl+c to interrupt)\n", agent: "kimi") == "C-c")
        #expect(M.interruptKey(screen: "• Working (5s • Esc to interrupt)\n", agent: "codex") == "Escape")
        // Nothing on screen says: the kind's.
        #expect(M.interruptKey(screen: "", agent: "grok") == "C-c")
        for kind in ["claude", "codex", "kimi", "omp", nil] as [String?] {
            #expect(M.interruptKey(screen: "> \n", agent: kind) == "Escape")
        }
        // The latest line wins (an old hint in the scrollback doesn't).
        #expect(M.interruptKey(screen: "esc to interrupt\n…\n◆ Run make [stop]\n", agent: "claude") == "C-c")
    }

    @Test("Stop and the Switchboard's phone STOP use it; a second press only while still busy")
    func wired() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let v = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BeautifiedSessionView.swift"), encoding: .utf8)
        let start = try #require(v.range(of: "    func interrupt() {"))
        let body = v[start.upperBound...].prefix(1600)
        #expect(body.contains("let key = Self.interruptKey(screen: await self.paneTail(), agent: kind)"))
        #expect(!body.contains(#"pressKeys(["Escape"])"#))
        let again = try #require(body.range(of: "if Self.screenShowsBusy(await self.paneTail()) {"))
        #expect(body[again.upperBound...].prefix(200).contains("await self.provider.pressKeys([key])"))
        // omp's queue comes back on Esc only.
        #expect(body.contains(#"if key == "Escape", AgentQueueSupport.escapeRestoresQueue(kind)"#))
        let sb = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/Switchboard.swift"), encoding: .utf8)
        #expect(sb.contains(#"BeautifiedSessionModel.interruptKey(screen: "", agent: c.tool.rawValue)"#))
        #expect(!sb.contains(#"send-keys -t bromure:\(w) Escape"#))
    }
}
