import Foundation
import Testing
@testable import bromure_ac

@Suite("What the agent says between its calls stays in the conversation")
struct ThinkingNarrationTests {
    private func item(_ id: Int, _ k: TranscriptItem.Kind) -> TranscriptItem { TranscriptItem(id: id, kind: k, timestamp: nil) }

    @Test("a short thought is shown; empty or long ones fold with the calls")
    func whatFolds() {
        #expect(!TranscriptRow.isActivity(item(1, .thinking("The new tests pass, but one storage-measurement test still fails."))))
        #expect(TranscriptRow.isActivity(item(2, .thinking(""))))
        #expect(TranscriptRow.isActivity(item(3, .thinking("   \n "))))
        #expect(TranscriptRow.isActivity(item(4, .thinking(String(repeating: "reasoning ", count: 100)))))
        #expect(TranscriptRow.isActivity(item(5, .toolResult(tool: "Bash", content: "ok", isError: false))))
    }

    @Test("the commentary between two runs of calls is a row of its own, in order")
    func rowOrder() {
        let items = [
            item(1, .userText("go")),
            item(2, .thinking("")),
            item(3, .toolUse(name: "Bash", summary: "ls", detail: "ls")),
            item(4, .toolResult(tool: "Bash", content: "a", isError: false)),
            item(5, .thinking("Found it; reading it now.")),
            item(6, .toolUse(name: "Bash", summary: "cat", detail: "cat a")),
            item(7, .assistantText("Done.")),
        ]
        let rows = TranscriptRow.rows(items)
        let shape = rows.map { r -> String in
            switch r {
            case .item(let i): if case .thinking = i.kind { return "note" }; if case .userText = i.kind { return "you" }; return "text"
            case .activity(let a): return "calls\(a.count)"
            case .changes: return "changes"
            }
        }
        #expect(shape.filter { $0 != "changes" } == ["you", "calls3", "note", "calls1", "text"])
    }

    @Test("a real session's commentary: every short thought is shown, none folded")
    func realSessionShape() throws {
        // Lines as Claude Code wrote them: text, then commentary logged as thinking.
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"check the sample"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Found it. Reading it now."}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"","signature":"x"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Sample 7 shows the main thread frozen in one lstat.","signature":"y"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Mostly yes."}]}}"#,
        ]
        let items = AgentTranscript.parse(Data((lines.joined(separator: "\n") + "\n").utf8), agent: "claude")
        let shown = TranscriptRow.rows(items).compactMap { r -> String? in
            if case .item(let i) = r, case .thinking(let t) = i.kind { return t }
            return nil
        }
        #expect(shown == ["Sample 7 shows the main thread frozen in one lstat."])
    }
}
