import Foundation
import Testing
@testable import bromure_ac

// Codex 0.157 "code mode": the model's only tool is `exec`, a JavaScript
// snippet calling the real tools. Fixture lines are trimmed from a real
// rollout (QA workspace, codex-cli 0.157.0): call ids, inputs and outputs
// verbatim; the long tool-list print shortened.

@Suite("Codex code-mode transcript")
struct CodexCodeModeTests {
    private let rollout = #"""
    {"timestamp": "2026-10-05T15:55:01.105Z", "type": "response_item", "payload": {"type": "custom_tool_call", "status": "completed", "call_id": "call_ingkLwzVqpefL8ZH7uaTFhQd", "name": "exec", "input": "text(await tools.exec_command({cmd:\"pwd && rg --files -g 'AGENTS.md' -g 'calc.py' -g '*test*' -g 'pyproject.toml' -g 'README*' && git status --short\",max_output_tokens:2000}));\ntext(ALL_TOOLS.filter(x=>/board_get_task|board_set_plan|board_ready_for_review/.test(x.name)));\n"}}
    {"timestamp": "2026-10-05T15:55:01.286Z", "type": "response_item", "payload": {"type": "custom_tool_call_output", "call_id": "call_ingkLwzVqpefL8ZH7uaTFhQd", "output": [{"type": "input_text", "text": "Script completed\nWall time 0.1 seconds\nOutput:\n"}, {"type": "input_text", "text": "{\"chunk_id\":\"3ab367\",\"wall_time_seconds\":0.000009083,\"exit_code\":0,\"original_token_count\":23,\"output\":\"/home/ubuntu/.bromure/worktrees/cx-demo/qa-cx-task1-multiply-261005-1154\\nREADME.md\\ncalc.py\\n\"}"}, {"type": "input_text", "text": "[{\"name\":\"mcp__bromure_board__board_get_task\",\"description\":\"…\"}]"}]}}
    {"timestamp": "2026-10-05T15:55:09.478Z", "type": "response_item", "payload": {"type": "custom_tool_call", "status": "completed", "call_id": "call_yQHtzeQyFO99x16xbgW2gJ40", "name": "exec", "input": "const results = await Promise.allSettled([\ntools.mcp__bromure_board__board_get_task({}),\ntools.exec_command({cmd:\"cat calc.py README.md; for p in /AGENTS.md /home/AGENTS.md /home/ubuntu/AGENTS.md /home/ubuntu/.bromure/AGENTS.md /home/ubuntu/.bromure/worktrees/AGENTS.md /home/ubuntu/.bromure/worktrees/cx-demo/AGENTS.md; do if [ -f \\\"$p\\\" ]; then cat \\\"$p\\\"; fi; done; ls -a\",max_output_tokens:3000})\n]); results.forEach(text);\n"}}
    {"timestamp": "2026-10-05T15:55:09.580Z", "type": "response_item", "payload": {"type": "custom_tool_call_output", "call_id": "call_yQHtzeQyFO99x16xbgW2gJ40", "output": [{"type": "input_text", "text": "Script completed\nWall time 0.1 seconds\nOutput:\n"}, {"type": "input_text", "text": "{\"status\":\"fulfilled\",\"value\":{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"branch\\\":\\\"wt\\\\/qa-cx-task1-multiply-261005-1154\\\",\\\"details\\\":\\\"Add a multiply(a, b) function to calc.py and commit it.\\\",\\\"stage\\\":\\\"inProgress\\\",\\\"title\\\":\\\"QA-CX task1 multiply\\\"}\"}]}}"}, {"type": "input_text", "text": "{\"status\":\"fulfilled\",\"value\":{\"chunk_id\":\"f895c5\",\"wall_time_seconds\":0.000009208,\"exit_code\":0,\"original_token_count\":22,\"output\":\"def add(a, b):\\n    return a + b\\n# cx-demo\\nTiny calculator.\\n.\\n..\\n.git\\nREADME.md\\ncalc.py\\n\"}}"}]}}
    {"timestamp": "2026-10-05T15:55:25.083Z", "type": "response_item", "payload": {"type": "custom_tool_call", "status": "completed", "call_id": "call_jwXKBg9MqXmwRy9erf3AF0Yj", "name": "exec", "input": "text(await tools.mcp__bromure_board__board_set_plan({plan:\"Add multiply(a, b) following calc.py's existing style, verify basic arithmetic cases, and commit the change before handing off for review.\"}));\ntext(await tools.apply_patch(\"*** Begin Patch\\n*** Update File: /home/ubuntu/.bromure/worktrees/cx-demo/qa-cx-task1-multiply-261005-1154/calc.py\\n@@\\n def add(a, b):\\n     return a + b\\n+\\n+\\n+def multiply(a, b):\\n+    return a * b\\n*** End Patch\"));\ntext(await tools.exec_command({cmd:\"python -B - <<'PY'\\nfrom calc import add, multiply\\nassert multiply(3, 4) == 12\\nassert multiply(0, 9) == 0\\nassert multiply(-3, 4) == -12\\nassert multiply(-3, -4) == 12\\nassert multiply(2.5, 4) == 10.0\\nassert add(3, 4) == 7\\nprint('All arithmetic checks passed.')\\nPY\\n git diff --check && git add calc.py && git commit -m \\\"Add multiply function to calculator\\\" && git status --short\",max_output_tokens:2000}));\n"}}
    {"timestamp": "2026-10-05T15:55:25.217Z", "type": "response_item", "payload": {"type": "custom_tool_call_output", "call_id": "call_jwXKBg9MqXmwRy9erf3AF0Yj", "output": [{"type": "input_text", "text": "Script completed\nWall time 0.1 seconds\nOutput:\n"}, {"type": "input_text", "text": "{\"content\":[{\"type\":\"text\",\"text\":\"Plan recorded on the task.\"}]}"}, {"type": "input_text", "text": "{}"}, {"type": "input_text", "text": "{\"chunk_id\":\"fc5f68\",\"wall_time_seconds\":0.00000775,\"exit_code\":0,\"original_token_count\":40,\"output\":\"/bin/bash: line 1: python: command not found\\n[wt/qa-cx-task1-multiply-261005-1154 6a2e9ad] Add multiply function to calculator\\n 1 file changed, 4 insertions(+)\\n\"}"}]}}
    """#

    private func uses(_ items: [TranscriptItem]) -> [(String, String, String)] {
        items.compactMap {
            if case .toolUse(let n, let s, let d) = $0.kind { return (n, s, d) }
            return nil
        }
    }
    private func results(_ items: [TranscriptItem]) -> [(String, String, Bool)] {
        items.compactMap {
            if case .toolResult(let t, let c, let e) = $0.kind { return (t, c, e) }
            return nil
        }
    }

    @Test("exec scripts become shell, patch and MCP cards with their own results")
    func scriptCalls() {
        let items = CodexTranscriptParser.parse(Data(rollout.utf8))
        let u = uses(items)
        // Script 1: one command (+ a tool-list print, no card). Script 2: an
        // MCP call and a command via Promise.allSettled. Script 3: MCP,
        // apply_patch, command.
        #expect(u.map(\.0) == ["shell", "mcp__bromure_board__board_get_task", "shell",
                               "mcp__bromure_board__board_set_plan", "apply_patch", "shell"])
        #expect(u[0].1.hasPrefix("pwd && rg --files -g 'AGENTS.md'"))
        #expect(u[0].2.contains("\"command\""))
        #expect(u[4].1 == "/home/ubuntu/.bromure/worktrees/cx-demo/qa-cx-task1-multiply-261005-1154/calc.py")
        #expect(u[4].2.contains("+def multiply(a, b):"))
        #expect(!u.contains { $0.1.contains("tools.") })

        let r = results(items)
        #expect(r.first?.0 == "shell")
        #expect(r.first?.1 == "/home/ubuntu/.bromure/worktrees/cx-demo/qa-cx-task1-multiply-261005-1154\nREADME.md\ncalc.py")
        #expect(r.contains { $0.0 == "mcp__bromure_board__board_get_task" && $0.1.contains("\"stage\":\"inProgress\"") })
        #expect(r.contains { $0.0 == "mcp__bromure_board__board_set_plan" && $0.1 == "Plan recorded on the task." })
        #expect(!r.contains { $0.1.contains("Script completed") })
        // The applied patch says nothing ({}); its card is the diff.
        #expect(!r.contains { $0.0 == "apply_patch" })
        #expect(r.filter { $0.0 == "shell" }.count == 3)
        #expect(!r.contains { $0.2 })
    }

    @Test("Activity summary counts commands, edits and tool calls apart")
    func activitySummary() {
        let items = CodexTranscriptParser.parse(Data(rollout.utf8))
        let line = ActivitySummary.line(items)
        #expect(line.text.contains("3"))
        #expect(line.symbols.contains("pencil"))
        #expect(line.symbols.contains("terminal"))
    }

    @Test("A nonzero exit is an error with its code; MCP isError and rejections too")
    func failures() {
        let jsonl = #"""
        {"timestamp":"2026-10-05T16:00:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"c1","name":"exec","input":"text(await tools.exec_command({cmd:'false', \"max_output_tokens\":100}));\ntext(await tools.mcp__delegation__request({to:\"@peer\",text:\"hi\",timeout_seconds:50}));\n"}}
        {"timestamp":"2026-10-05T16:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":[{"type":"input_text","text":"Script completed\nWall time 0.1 seconds\nOutput:\n"},{"type":"input_text","text":"{\"chunk_id\":\"a\",\"exit_code\":1,\"output\":\"boom\\n\"}"},{"type":"input_text","text":"{\"content\":[{\"type\":\"text\",\"text\":\"Error: @peer is out of reach.\"}],\"isError\":true}"}]}}
        """#
        let items = CodexTranscriptParser.parse(Data(jsonl.utf8))
        let u = uses(items)
        #expect(u.map(\.0) == ["shell", "mcp__delegation__request"])
        #expect(u[0].1 == "false")
        #expect(ActivitySummary.category(u[1].0) == .delegation)
        let r = results(items)
        #expect(r.count == 2)
        #expect(r[0].0 == "shell" && r[0].2 && r[0].1.hasPrefix("boom"))
        #expect(r[0].1.contains("1"))
        #expect(r[1].0 == "mcp__delegation__request" && r[1].2)
    }

    @Test("A script still running hands its results over through wait")
    func runningCell() {
        let jsonl = #"""
        {"timestamp":"2026-10-05T16:00:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"c1","name":"exec","input":"text(await tools.mcp__delegation__wait({delegation_id:\"D9\",timeout_seconds:50}));\n"}}
        {"timestamp":"2026-10-05T16:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":"Script running with cell ID 10\nWall time 31.0 seconds\nOutput:\n"}}
        {"timestamp":"2026-10-05T16:00:02.000Z","type":"response_item","payload":{"type":"function_call","name":"wait","arguments":"{\"cell_id\":\"10\",\"yield_time_ms\":1000}","call_id":"w1"}}
        {"timestamp":"2026-10-05T16:00:03.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"w1","output":"Script running with cell ID 10\nWall time 1.0 seconds\nOutput:\n"}}
        {"timestamp":"2026-10-05T16:00:04.000Z","type":"response_item","payload":{"type":"function_call","name":"wait","arguments":"{\"cell_id\":\"10\",\"yield_time_ms\":20000}","call_id":"w2"}}
        {"timestamp":"2026-10-05T16:00:05.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"w2","output":[{"type":"input_text","text":"Script completed\nWall time 9.2 seconds\nOutput:\n"},{"type":"input_text","text":"{\"content\":[{\"type\":\"text\",\"text\":\"Nothing arrived in time.\"}]}"}]}}
        """#
        let items = CodexTranscriptParser.parse(Data(jsonl.utf8))
        #expect(uses(items).map(\.0) == ["mcp__delegation__wait"])
        let r = results(items)
        #expect(r.count == 1)
        #expect(r.first?.0 == "mcp__delegation__wait")
        #expect(r.first?.1 == "Nothing arrived in time.")
    }

    @Test("A script that only reads the tool list shows nothing")
    func toolListScripts() {
        let jsonl = #"""
        {"timestamp":"2026-10-05T16:00:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"c1","name":"exec","input":"const ts=ALL_TOOLS.filter(x=>/delegat/i.test(x.name)); text(ts);\n"}}
        {"timestamp":"2026-10-05T16:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":[{"type":"input_text","text":"Script completed\nWall time 0.0 seconds\nOutput:\n"},{"type":"input_text","text":"[{\"name\":\"mcp__delegation__list_peers\"}]"}]}}
        """#
        #expect(CodexTranscriptParser.parse(Data(jsonl.utf8)).isEmpty)
    }

    @Test("Older formats: function_call shell and the freeform apply_patch")
    func olderFormats() {
        let jsonl = #"""
        {"timestamp":"2026-08-15T10:23:52.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"ls\"]}","call_id":"call_1"}}
        {"timestamp":"2026-08-15T10:23:57.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"{\"output\":\"a\",\"metadata\":{\"exit_code\":0}}"}}
        {"timestamp":"2026-08-15T10:24:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","call_id":"call_2","input":"*** Begin Patch\n*** Add File: hello.txt\n+hi\n*** End Patch"}}
        {"timestamp":"2026-08-15T10:24:01.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_2","output":"Success. Updated the following files:\nA hello.txt"}}
        """#
        let items = CodexTranscriptParser.parse(Data(jsonl.utf8))
        let u = uses(items)
        #expect(u.map(\.0) == ["shell", "apply_patch"])
        #expect(u[0].1 == "ls")
        #expect(u[1].1 == "hello.txt")
        #expect(u[1].2.contains("\"patch\""))
        let r = results(items)
        #expect(r.map(\.0) == ["shell", "apply_patch"])
        #expect(r[1].1.hasPrefix("Success."))
    }

    @Test("Literal scanner: quoting, escapes, non-literal arguments")
    func scanner() {
        let calls = CodexCodeMode.calls(in: #"""
        // tools.fake_in_comment({})
        const x = "tools.not_a_call({})";
        await tools.exec_command({cmd:'echo \'hi\' \u00e9', "max_output_tokens":10, list:[1, 2.5, true, null,],});
        await tools.view_image({path: somePath});
        await tools.apply_patch(`*** Begin Patch
        *** Update File: a.py
        *** End Patch`);
        """#)
        #expect(calls.map(\.name) == ["exec_command", "view_image", "apply_patch"])
        #expect(calls[0].command == "echo 'hi' é")
        #expect(((calls[0].args as? [String: Any])?["list"] as? [Any])?.count == 4)
        #expect(calls[1].args == nil)
        #expect(calls[1].raw == "{path: somePath}")
        #expect(CodexCodeMode.patchFiles(calls[2].patch ?? "") == ["a.py"])
    }

    @Test("The model of the latest turn wins")
    func latestModel() {
        let jsonl = #"""
        {"timestamp":"t","type":"turn_context","payload":{"model":"gpt-a"}}
        {"timestamp":"t","type":"turn_context","payload":{"model":"gpt-b"}}
        """#
        #expect(CodexTranscriptParser.latestModel(Data(jsonl.utf8)) == "gpt-b")
    }
}
