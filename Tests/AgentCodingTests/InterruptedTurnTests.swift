import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-670): "Interrupting Codex now completes and tears down an
/// unfinished automation". Codex's Interrupt (Esc) and SessionEnd hooks
/// reported `done`, the same as its Stop, and a Codex run now finishes on a
/// done: Esc stamped the unfinished run complete, fired the automations
/// chained after it, and with closeWhenDone closed its tab (and deleted a
/// clone). Kimi's Interrupt, Grok's StopCancelled and the idle_prompt
/// notification (Claude, Grok) did the same for their runs and for coding
/// tasks. They now report `idle`: the tab shows done, nothing finishes.
@Suite("An interrupted or idle agent finishes no run or task")
struct InterruptedTurnTests {
    private static func src(_ p: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8)
    }

    @Test("idle shows as done but ends no turn; done does")
    func signal() {
        #expect(AgentStatus(signal: "idle") == .done)
        #expect(AgentStatus(signal: "idle\nsess-1") == .done)
        #expect(!AgentStatus.endsTurn(signal: "idle"))
        #expect(!AgentStatus.endsTurn(signal: " IDLE \nsess-1"))
        #expect(AgentStatus.endsTurn(signal: "done\nsess-1"))
        #expect(AgentStatus(signal: "done") == .done)
    }

    @Test("Codex: Stop is done; Esc (Interrupt) and SessionEnd are idle")
    func codexHooks() throws {
        let agentd = try Self.src("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")
        let start = try #require(agentd.range(of: "_CODEX_STATUS_HOOKS = ["))
        let table = agentd[start.upperBound...].prefix { $0 != "]" }
        #expect(table.contains(#"("Stop", None, "done"),"#))
        #expect(table.contains(#"("Interrupt", None, "idle"),"#))
        #expect(table.contains(#"("SessionEnd", None, "idle"),"#))
        #expect(!table.contains(#"("Interrupt", None, "done")"#) && !table.contains(#"("SessionEnd", None, "done")"#))
    }

    @Test("Kimi's Interrupt and Grok's StopCancelled are idle; their Stop stays done")
    func kimiGrokHooks() throws {
        let kimi = SessionDisk.kimiHooksTOML
        let interrupt = try #require(kimi.range(of: "event = \"Interrupt\""))
        #expect(kimi[interrupt.upperBound...].prefix(80).contains("agent-status.sh idle\""))
        let stop = try #require(kimi.range(of: "event = \"Stop\"\n"))
        #expect(kimi[stop.upperBound...].prefix(80).contains("agent-status.sh done\""))
        #expect(ProfileStore.grokStatusHooksJSON.contains("agent-status.sh idle"))
        #expect(!ProfileStore.grokStatusHooksJSON.contains("agent-status.sh done"))
    }

    @Test("the host finishes runs and tasks only on a turn that ended")
    func hostGate() throws {
        let ac = try Self.src("Sources/AgentCoding/BromureAC.swift")
        #expect(ac.contains("self.setTabAgentStatus(pid, index: w, status,\n                                       turnEnded: AgentStatus.endsTurn(signal: signal))"))
        let fn = try #require(ac.range(of: "func setTabAgentStatus(_ id: Profile.ID, index: Int, _ status: AgentStatus,\n                           turnEnded: Bool = true) {"))
        let body = String(ac[fn.upperBound...].prefix(4000))
        // Every engine finish in the function sits behind `if turnEnded {`.
        let finishes = body.components(separatedBy: "scheduledAutomationEngine.agentFinished(").count - 1
        let gated = body.components(separatedBy: "if turnEnded {\n").count - 1
        #expect(finishes == 2 && gated == 2)
        for chunk in body.components(separatedBy: "scheduledAutomationEngine.agentFinished(").dropLast() {
            #expect(chunk.hasSuffix("if turnEnded {\n                    ") || chunk.hasSuffix("if turnEnded {\n            "))
        }
    }
}
