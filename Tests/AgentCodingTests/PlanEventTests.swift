import Foundation
import Testing
@testable import bromure_ac

@Suite("Plan stream events")
struct PlanEventTests {

    private func parse(_ json: String) -> PlanEvent? {
        PlanEvent.parse(line: Data(json.utf8))
    }

    private func decode(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Guest → host events

    @Test("hello carries branch and tool")
    func hello() {
        #expect(parse(#"{"v":1,"ev":"hello","branch":"wt/fix-leak","tool":"claude"}"#)
                == .hello(branch: "wt/fix-leak", tool: "claude"))
    }

    @Test("state, text, and thinking decode")
    func basics() {
        #expect(parse(#"{"ev":"state","state":"working"}"#) == .state("working"))
        #expect(parse(#"{"ev":"text","role":"user","text":"hi"}"#)
                == .text(role: "user", text: "hi"))
        #expect(parse(#"{"ev":"thinking","text":"hmm"}"#) == .thinking("hmm"))
    }

    @Test("tool call and tool result decode")
    func tools() {
        #expect(parse(#"{"ev":"tool","name":"Bash","summary":"ls -la"}"#)
                == .tool(name: "Bash", summary: "ls -la"))
        #expect(parse(#"{"ev":"tool_result","name":"Bash","ok":false,"summary":"exit 1"}"#)
                == .toolResult(name: "Bash", ok: false, summary: "exit 1"))
    }

    @Test("question decodes qid and reuses TranscriptQuestion")
    func question() {
        let line = #"{"ev":"question","qid":"q-1","questions":["# +
            #"{"question":"Which DB?","header":"Storage","multiSelect":false,"# +
            #""options":[{"label":"sqlite","description":"embedded"},"# +
            #"{"label":"postgres","description":"server"}]},"# +
            #"{"question":"Language?","multiSelect":true,"# +
            #""options":[{"label":"swift","description":""}]}]}"#
        guard case .question(let qid, let qs)? = parse(line) else {
            Issue.record("did not decode as question")
            return
        }
        #expect(qid == "q-1")
        #expect(qs.count == 2)
        #expect(qs[0].question == "Which DB?")
        #expect(qs[0].header == "Storage")
        #expect(!qs[0].multiSelect)
        #expect(qs[0].options.map(\.label) == ["sqlite", "postgres"])
        #expect(qs[0].options[1].description == "server")
        #expect(qs[1].multiSelect)
        #expect(qs[1].header == "")   // missing header defaults to empty
        #expect(qs[1].options == [TranscriptQuestion.Option(label: "swift", description: "")])
    }

    @Test("question_resolved, result, and fatal decode")
    func terminals() {
        #expect(parse(#"{"ev":"question_resolved","qid":"q-1"}"#)
                == .questionResolved(qid: "q-1"))
        #expect(parse(#"{"ev":"result","ok":true,"error":null}"#)
                == .result(ok: true, error: nil))
        #expect(parse(#"{"ev":"result","ok":false,"error":"agent died"}"#)
                == .result(ok: false, error: "agent died"))
        #expect(parse(#"{"ev":"fatal","error":"driver crashed"}"#)
                == .fatal("driver crashed"))
    }

    @Test("tolerance: unknown ev and junk lines return nil")
    func tolerance() {
        #expect(parse(#"{"ev":"telemetry","x":1}"#) == nil)   // unknown event
        #expect(parse("not json at all") == nil)
        #expect(parse("") == nil)
        #expect(parse(#"["ev","hello"]"#) == nil)             // not an object
        #expect(parse(#"{"x":1}"#) == nil)                    // no ev field
    }

    @Test("tolerance: missing optional fields default sanely")
    func defaults() {
        #expect(parse(#"{"ev":"text"}"#) == .text(role: "assistant", text: ""))
        #expect(parse(#"{"ev":"tool_result","name":"Bash"}"#)
                == .toolResult(name: "Bash", ok: true, summary: ""))
        #expect(parse(#"{"ev":"question","qid":"q-2"}"#)
                == .question(qid: "q-2", questions: []))
        // A result that lost its ok flag but carries an error is a failure;
        // one with neither is a success.
        #expect(parse(#"{"ev":"result","error":"x"}"#) == .result(ok: false, error: "x"))
        #expect(parse(#"{"ev":"result"}"#) == .result(ok: true, error: nil))
    }

    // MARK: Host → guest commands

    @Test("user command keeps multi-line text on one NDJSON line")
    func userCommand() {
        let data = PlanCommand.user("line one\nline two").jsonLine()
        #expect(data.last == 0x0A)
        #expect(data.dropLast().firstIndex(of: 0x0A) == nil)   // exactly one line
        let obj = decode(data)
        #expect(obj?["cmd"] as? String == "user")
        #expect(obj?["text"] as? String == "line one\nline two")
    }

    @Test("answer command carries qid, labels, and explicit-null other")
    func answerCommand() {
        let cmd = PlanCommand.answer(qid: "q-1", answers: [
            (question: "Which DB?", labels: ["sqlite", "postgres"], other: nil),
            (question: "Language?", labels: [], other: "rust"),
        ])
        let data = cmd.jsonLine()
        #expect(data.last == 0x0A)
        let obj = decode(data)
        #expect(obj?["cmd"] as? String == "answer")
        #expect(obj?["qid"] as? String == "q-1")
        let answers = obj?["answers"] as? [[String: Any]]
        #expect(answers?.count == 2)
        #expect(answers?[0]["question"] as? String == "Which DB?")
        #expect(answers?[0]["labels"] as? [String] == ["sqlite", "postgres"])
        #expect(answers?[0]["other"] is NSNull)                // null, not absent
        #expect(answers?[1]["question"] as? String == "Language?")
        #expect(answers?[1]["labels"] as? [String] == [])
        #expect(answers?[1]["other"] as? String == "rust")
    }

    @Test("interrupt and end are bare one-line cmd objects")
    func bareCommands() {
        for (cmd, name) in [(PlanCommand.interrupt, "interrupt"), (.end, "end")] {
            let data = cmd.jsonLine()
            #expect(data.last == 0x0A)
            #expect(data.dropLast().firstIndex(of: 0x0A) == nil)
            let obj = decode(data)
            #expect(obj?.count == 1)
            #expect(obj?["cmd"] as? String == name)
        }
    }
}
