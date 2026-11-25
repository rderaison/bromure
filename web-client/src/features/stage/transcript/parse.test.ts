// Ports of the Swift suites (AgentTranscriptParserTests, CodexCodeModeTests,
// OmpTranscriptCardsTests, TodoParseTests) plus the demo fixtures.
// vite.config's test.include only covers test/**, so run with:
//   npx vitest run --root src/features/stage/transcript
import { describe, expect, it } from 'vitest';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import {
  apiErrorHeadline, codeModeCalls, callCommand, callPatch, latestModel, parseTranscript, patchFiles,
  rewriteSharePaths, sniffAgent, todoMerge, todoRows, unwrapPasted, isLocalRecord, kimiTurnInProgress, shareNames,
} from './parse';
import type { TranscriptItem, TranscriptKind } from './types';

const kinds = (items: TranscriptItem[]) => items.map((i) => i.kind);
const uses = (items: TranscriptItem[]) => items.flatMap((i) => (i.kind.t === 'toolUse' ? [i.kind] : []));
const results = (items: TranscriptItem[]) => items.flatMap((i) => (i.kind.t === 'toolResult' ? [i.kind] : []));

const codexRollout = String.raw`{"timestamp":"2026-08-15T10:23:45.123Z","type":"session_meta","payload":{"id":"u1","timestamp":"2026-08-15T10:23:45.123Z","cwd":"/home/ubuntu/proj","originator":"codex_cli_rs","cli_version":"0.99.0"}}
{"timestamp":"2026-08-15T10:23:45.500Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<user_instructions>never mind me</user_instructions>"}]}}
{"timestamp":"2026-08-15T10:23:45.600Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd dump</environment_context>"}]}}
{"timestamp":"2026-08-15T10:23:46.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix the flaky test"}]}}
{"timestamp":"2026-08-15T10:23:50.000Z","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"Looking for the test first."}],"content":null,"encrypted_content":"gAAAA"}}
{"timestamp":"2026-08-15T10:23:52.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"pytest -k flaky\"],\"workdir\":\"/home/ubuntu/proj\"}","call_id":"call_1"}}
{"timestamp":"2026-08-15T10:23:57.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"{\"output\":\"1 failed\",\"metadata\":{\"exit_code\":1,\"duration_seconds\":4.2}}"}}
{"timestamp":"2026-08-15T10:24:00.000Z","type":"response_item","payload":{"type":"web_search_call","id":"ws_1","status":"completed","action":{"type":"search","query":"pytest flaky rerun"}}}
{"timestamp":"2026-08-15T10:24:10.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"The test races the pool teardown."}]}}
{"timestamp":"2026-08-15T10:24:10.000Z","type":"event_msg","payload":{"type":"agent_message","message":"The test races the pool teardown."}}
{"timestamp":"2026-08-15T10:24:11.000Z","type":"turn_context","payload":{"cwd":"/home/ubuntu/proj","model":"gpt-5"}}`;

const grokUpdates = `{"timestamp":1784388050,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"add a retry "}},"_meta":{"eventId":"e1"}}}
{"timestamp":1784388050,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"to the uploader"}},"_meta":{"eventId":"e2"}}}
{"timestamp":1784388052,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"The uploader lives in sync.rs."}}}}
{"timestamp":1784388053,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"call-1","title":"run_shell","kind":"execute","status":"in_progress","rawInput":{"command":"cargo test uploader"}}}}
{"timestamp":1784388054,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"in_progress"}}}
{"timestamp":1784388059,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"test result: ok"}}]}}}
{"timestamp":1784388061,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done — retry "}}}}
{"timestamp":1784388061,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"added."}}}}
{"timestamp":1784388062,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":100}}}}`;

const kimiWire = `{"type":"metadata","protocol_version":"1.5","created_at":1786809539556}
{"type":"permission.set_mode","mode":"auto","time":1786809539588}
{"type":"turn.prompt","input":[{"type":"text","text":"run echo for me"}],"origin":{"kind":"user"},"time":1786809539589}
{"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"run echo for me"}],"toolCalls":[],"origin":{"kind":"user"},"id":"m1"},"time":1786809539590}
{"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>auto mode</system-reminder>"}],"toolCalls":[],"origin":{"kind":"injection","variant":"permission_mode"},"id":"m2"},"time":1786809539590}
{"type":"context.append_loop_event","event":{"type":"step.begin","uuid":"s1","turnId":"0","step":1},"time":1786809539592}
{"type":"llm.request","kind":"loop","provider":"openai","model":"m","time":1786809539600}
{"type":"context.append_loop_event","event":{"type":"content.part","uuid":"p0","turnId":"0","step":1,"stepUuid":"s1","part":{"type":"think","think":"Simple enough."}},"time":1786809539605}
{"type":"context.append_loop_event","event":{"type":"content.part","uuid":"p1","turnId":"0","step":1,"stepUuid":"s1","part":{"type":"text","text":"Let me "}},"time":1786809539606}
{"type":"context.append_loop_event","event":{"type":"content.part","uuid":"p2","turnId":"0","step":1,"stepUuid":"s1","part":{"type":"text","text":"run that."}},"time":1786809539606}
{"type":"context.append_loop_event","event":{"type":"tool.call","uuid":"t1","turnId":"0","step":1,"stepUuid":"s1","toolCallId":"call_abc123","name":"Bash","args":{"command":"echo kimi-transcript-test"}},"time":1786809539616}
{"type":"context.append_loop_event","event":{"type":"tool.result","parentUuid":"t1","toolCallId":"call_abc123","result":{"output":"kimi-transcript-test","isError":false}},"time":1786809539616}
{"type":"context.append_loop_event","event":{"type":"step.end","uuid":"s1","turnId":"0","step":1,"finishReason":"tool_use"},"time":1786809539617}
{"type":"context.append_loop_event","event":{"type":"content.part","uuid":"p3","turnId":"0","step":2,"stepUuid":"s2","part":{"type":"text","text":"Done."}},"time":1786809539622}
{"type":"turn.ended","turnId":0,"reason":"completed","durationMs":32,"time":1786809539622}`;

const claudeCleared = String.raw`{"type":"user","message":{"role":"user","content":"What's the weather like?"},"uuid":"u0","timestamp":"2026-09-19T20:00:00.000Z","sessionId":"s1"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Sunny."}]},"uuid":"a0","timestamp":"2026-09-19T20:00:05.000Z","sessionId":"s1"}
{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat: The messages below were generated by the user while running local commands.</local-command-caveat>"},"uuid":"m1","timestamp":"2026-09-19T20:01:00.000Z","sessionId":"s1"}
{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>\n            <command-message>clear</command-message>\n            <command-args></command-args>"},"uuid":"u1","timestamp":"2026-09-19T20:01:00.100Z","sessionId":"s1"}
{"type":"system","subtype":"local_command","content":"<local-command-stdout></local-command-stdout>","level":"info","uuid":"sys1","timestamp":"2026-09-19T20:01:00.200Z","sessionId":"s1"}
{"type":"user","message":{"role":"user","content":"<local-command-stdout>Goal set: ship it</local-command-stdout>"},"uuid":"u2","timestamp":"2026-09-19T20:01:30.000Z","sessionId":"s1"}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>The user has memories.</system-reminder>"},{"type":"text","text":"Check a new model called 'jev'. Is it open weight?"}]},"uuid":"u3","timestamp":"2026-09-19T20:02:00.000Z","sessionId":"s1"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking."}]},"uuid":"a1","timestamp":"2026-09-19T20:02:05.000Z","sessionId":"s1"}`;

describe('Codex', () => {
  it('rollout: response items, synthetic-turn filtering, tool traffic', () => {
    const { items } = parseTranscript(codexRollout, 'codex');
    expect(items.length).toBe(6);
    expect(items[0].kind).toEqual({ t: 'userText', text: 'fix the flaky test' });
    expect(items[1].kind).toEqual({ t: 'thinking', text: 'Looking for the test first.' });
    const u = items[2].kind as Extract<TranscriptKind, { t: 'toolUse' }>;
    expect(u.name).toBe('shell');
    expect(u.summary).toBe('pytest -k flaky');
    expect(u.detail).toContain('workdir');
    expect(u.detail).toContain('"command" : [');
    expect(items[3].kind).toEqual({ t: 'toolResult', tool: 'shell', content: '1 failed', isError: true });
    expect(items[4].kind).toMatchObject({ t: 'toolUse', name: 'web_search', summary: 'pytest flaky rerun' });
    expect(items[5].kind).toEqual({ t: 'assistantText', text: 'The test races the pool teardown.' });
    expect(items[0].timestamp).toBe(Date.parse('2026-08-15T10:23:46.000Z'));
    expect(latestModel(codexRollout)).toBe('gpt-5');
  });

  it('event_msg mirror is the fallback', () => {
    const eventsOnly = `{"timestamp":"2026-08-15T10:23:46.000Z","type":"event_msg","payload":{"type":"user_message","message":"hello","kind":"plain"}}
{"timestamp":"2026-08-15T10:23:47.000Z","type":"event_msg","payload":{"type":"user_message","message":"<user_instructions>x</user_instructions>","kind":"user_instructions"}}
{"timestamp":"2026-08-15T10:23:48.000Z","type":"event_msg","payload":{"type":"agent_reasoning","text":"thinking about it"}}
{"timestamp":"2026-08-15T10:23:49.000Z","type":"event_msg","payload":{"type":"agent_message","message":"hi there"}}`;
    expect(kinds(parseTranscript(eventsOnly, 'codex').items)).toEqual([
      { t: 'userText', text: 'hello' }, { t: 'thinking', text: 'thinking about it' }, { t: 'assistantText', text: 'hi there' },
    ]);
  });

  const codeMode = String.raw`{"timestamp": "2026-10-05T15:55:01.105Z", "type": "response_item", "payload": {"type": "custom_tool_call", "status": "completed", "call_id": "call_ingkLwzVqpefL8ZH7uaTFhQd", "name": "exec", "input": "text(await tools.exec_command({cmd:\"pwd && rg --files -g 'AGENTS.md' -g 'calc.py' -g '*test*' -g 'pyproject.toml' -g 'README*' && git status --short\",max_output_tokens:2000}));\ntext(ALL_TOOLS.filter(x=>/board_get_task|board_set_plan|board_ready_for_review/.test(x.name)));\n"}}
{"timestamp": "2026-10-05T15:55:01.286Z", "type": "response_item", "payload": {"type": "custom_tool_call_output", "call_id": "call_ingkLwzVqpefL8ZH7uaTFhQd", "output": [{"type": "input_text", "text": "Script completed\nWall time 0.1 seconds\nOutput:\n"}, {"type": "input_text", "text": "{\"chunk_id\":\"3ab367\",\"wall_time_seconds\":0.000009083,\"exit_code\":0,\"original_token_count\":23,\"output\":\"/home/ubuntu/.bromure/worktrees/cx-demo/qa-cx-task1-multiply-261005-1154\\nREADME.md\\ncalc.py\\n\"}"}, {"type": "input_text", "text": "[{\"name\":\"mcp__bromure_board__board_get_task\",\"description\":\"…\"}]"}]}}
{"timestamp": "2026-10-05T15:55:09.478Z", "type": "response_item", "payload": {"type": "custom_tool_call", "status": "completed", "call_id": "call_yQHtzeQyFO99x16xbgW2gJ40", "name": "exec", "input": "const results = await Promise.allSettled([\ntools.mcp__bromure_board__board_get_task({}),\ntools.exec_command({cmd:\"cat calc.py README.md; for p in /AGENTS.md /home/AGENTS.md /home/ubuntu/AGENTS.md /home/ubuntu/.bromure/AGENTS.md /home/ubuntu/.bromure/worktrees/AGENTS.md /home/ubuntu/.bromure/worktrees/cx-demo/AGENTS.md; do if [ -f \\\"$p\\\" ]; then cat \\\"$p\\\"; fi; done; ls -a\",max_output_tokens:3000})\n]); results.forEach(text);\n"}}
{"timestamp": "2026-10-05T15:55:09.580Z", "type": "response_item", "payload": {"type": "custom_tool_call_output", "call_id": "call_yQHtzeQyFO99x16xbgW2gJ40", "output": [{"type": "input_text", "text": "Script completed\nWall time 0.1 seconds\nOutput:\n"}, {"type": "input_text", "text": "{\"status\":\"fulfilled\",\"value\":{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"branch\\\":\\\"wt\\\\/qa-cx-task1-multiply-261005-1154\\\",\\\"details\\\":\\\"Add a multiply(a, b) function to calc.py and commit it.\\\",\\\"stage\\\":\\\"inProgress\\\",\\\"title\\\":\\\"QA-CX task1 multiply\\\"}\"}]}}"}, {"type": "input_text", "text": "{\"status\":\"fulfilled\",\"value\":{\"chunk_id\":\"f895c5\",\"wall_time_seconds\":0.000009208,\"exit_code\":0,\"original_token_count\":22,\"output\":\"def add(a, b):\\n    return a + b\\n# cx-demo\\nTiny calculator.\\n.\\n..\\n.git\\nREADME.md\\ncalc.py\\n\"}}"}]}}
{"timestamp": "2026-10-05T15:55:25.083Z", "type": "response_item", "payload": {"type": "custom_tool_call", "status": "completed", "call_id": "call_jwXKBg9MqXmwRy9erf3AF0Yj", "name": "exec", "input": "text(await tools.mcp__bromure_board__board_set_plan({plan:\"Add multiply(a, b) following calc.py's existing style, verify basic arithmetic cases, and commit the change before handing off for review.\"}));\ntext(await tools.apply_patch(\"*** Begin Patch\\n*** Update File: /home/ubuntu/.bromure/worktrees/cx-demo/qa-cx-task1-multiply-261005-1154/calc.py\\n@@\\n def add(a, b):\\n     return a + b\\n+\\n+\\n+def multiply(a, b):\\n+    return a * b\\n*** End Patch\"));\ntext(await tools.exec_command({cmd:\"python -B - <<'PY'\\nfrom calc import add, multiply\\nassert multiply(3, 4) == 12\\nprint('All arithmetic checks passed.')\\nPY\\n git diff --check && git add calc.py && git commit -m \\\"Add multiply function to calculator\\\" && git status --short\",max_output_tokens:2000}));\n"}}
{"timestamp": "2026-10-05T15:55:25.217Z", "type": "response_item", "payload": {"type": "custom_tool_call_output", "call_id": "call_jwXKBg9MqXmwRy9erf3AF0Yj", "output": [{"type": "input_text", "text": "Script completed\nWall time 0.1 seconds\nOutput:\n"}, {"type": "input_text", "text": "{\"content\":[{\"type\":\"text\",\"text\":\"Plan recorded on the task.\"}]}"}, {"type": "input_text", "text": "{}"}, {"type": "input_text", "text": "{\"chunk_id\":\"fc5f68\",\"wall_time_seconds\":0.00000775,\"exit_code\":0,\"original_token_count\":40,\"output\":\"/bin/bash: line 1: python: command not found\\n[wt/qa-cx-task1-multiply-261005-1154 6a2e9ad] Add multiply function to calculator\\n 1 file changed, 4 insertions(+)\\n\"}"}]}}`;

  it('code-mode exec scripts become shell, patch and MCP cards with their own results', () => {
    const { items } = parseTranscript(codeMode);
    const u = uses(items);
    expect(u.map((x) => x.name)).toEqual(['shell', 'mcp__bromure_board__board_get_task', 'shell',
      'mcp__bromure_board__board_set_plan', 'apply_patch', 'shell']);
    expect(u[0].summary.startsWith("pwd && rg --files -g 'AGENTS.md'")).toBe(true);
    expect(u[0].detail).toContain('"command"');
    expect(u[4].summary).toBe('/home/ubuntu/.bromure/worktrees/cx-demo/qa-cx-task1-multiply-261005-1154/calc.py');
    expect(u[4].detail).toContain('+def multiply(a, b):');
    expect(u.some((x) => x.summary.includes('tools.'))).toBe(false);
    const r = results(items);
    expect(r[0].tool).toBe('shell');
    expect(r[0].content).toBe('/home/ubuntu/.bromure/worktrees/cx-demo/qa-cx-task1-multiply-261005-1154\nREADME.md\ncalc.py');
    expect(r.some((x) => x.tool === 'mcp__bromure_board__board_get_task' && x.content.includes('"stage":"inProgress"'))).toBe(true);
    expect(r.some((x) => x.tool === 'mcp__bromure_board__board_set_plan' && x.content === 'Plan recorded on the task.')).toBe(true);
    expect(r.some((x) => x.content.includes('Script completed'))).toBe(false);
    expect(r.some((x) => x.tool === 'apply_patch')).toBe(false);
    expect(r.filter((x) => x.tool === 'shell').length).toBe(3);
    expect(r.some((x) => x.isError)).toBe(false);
  });

  it('nonzero exit, MCP isError', () => {
    const jsonl = String.raw`{"timestamp":"2026-10-05T16:00:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"c1","name":"exec","input":"text(await tools.exec_command({cmd:'false', \"max_output_tokens\":100}));\ntext(await tools.mcp__delegation__request({to:\"@peer\",text:\"hi\",timeout_seconds:50}));\n"}}
{"timestamp":"2026-10-05T16:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":[{"type":"input_text","text":"Script completed\nWall time 0.1 seconds\nOutput:\n"},{"type":"input_text","text":"{\"chunk_id\":\"a\",\"exit_code\":1,\"output\":\"boom\\n\"}"},{"type":"input_text","text":"{\"content\":[{\"type\":\"text\",\"text\":\"Error: @peer is out of reach.\"}],\"isError\":true}"}]}}`;
    const { items } = parseTranscript(jsonl, 'codex');
    expect(uses(items).map((x) => [x.name, x.summary])).toEqual([['shell', 'false'], ['mcp__delegation__request', '@peer']]);
    const r = results(items);
    expect(r.length).toBe(2);
    expect(r[0]).toEqual({ t: 'toolResult', tool: 'shell', content: 'boom\n(exit code 1)', isError: true });
    expect(r[1]).toMatchObject({ tool: 'mcp__delegation__request', isError: true });
  });

  it('a running script hands its results over through wait', () => {
    const jsonl = String.raw`{"timestamp":"2026-10-05T16:00:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"c1","name":"exec","input":"text(await tools.mcp__delegation__wait({delegation_id:\"D9\",timeout_seconds:50}));\n"}}
{"timestamp":"2026-10-05T16:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":"Script running with cell ID 10\nWall time 31.0 seconds\nOutput:\n"}}
{"timestamp":"2026-10-05T16:00:02.000Z","type":"response_item","payload":{"type":"function_call","name":"wait","arguments":"{\"cell_id\":\"10\",\"yield_time_ms\":1000}","call_id":"w1"}}
{"timestamp":"2026-10-05T16:00:03.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"w1","output":"Script running with cell ID 10\nWall time 1.0 seconds\nOutput:\n"}}
{"timestamp":"2026-10-05T16:00:04.000Z","type":"response_item","payload":{"type":"function_call","name":"wait","arguments":"{\"cell_id\":\"10\",\"yield_time_ms\":20000}","call_id":"w2"}}
{"timestamp":"2026-10-05T16:00:05.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"w2","output":[{"type":"input_text","text":"Script completed\nWall time 9.2 seconds\nOutput:\n"},{"type":"input_text","text":"{\"content\":[{\"type\":\"text\",\"text\":\"Nothing arrived in time.\"}]}"}]}}`;
    const { items } = parseTranscript(jsonl, 'codex');
    expect(uses(items).map((x) => x.name)).toEqual(['mcp__delegation__wait']);
    expect(results(items).map((x) => [x.tool, x.content])).toEqual([['mcp__delegation__wait', 'Nothing arrived in time.']]);
  });

  it('a tool-list-only script shows nothing; older formats', () => {
    const hidden = String.raw`{"timestamp":"2026-10-05T16:00:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"c1","name":"exec","input":"const ts=ALL_TOOLS.filter(x=>/delegat/i.test(x.name)); text(ts);\n"}}
{"timestamp":"2026-10-05T16:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":[{"type":"input_text","text":"Script completed\nWall time 0.0 seconds\nOutput:\n"},{"type":"input_text","text":"[{\"name\":\"mcp__delegation__list_peers\"}]"}]}}`;
    expect(parseTranscript(hidden, 'codex').items).toEqual([]);
    const older = String.raw`{"timestamp":"2026-08-15T10:23:52.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"ls\"]}","call_id":"call_1"}}
{"timestamp":"2026-08-15T10:23:57.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"{\"output\":\"a\",\"metadata\":{\"exit_code\":0}}"}}
{"timestamp":"2026-08-15T10:24:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","call_id":"call_2","input":"*** Begin Patch\n*** Add File: hello.txt\n+hi\n*** End Patch"}}
{"timestamp":"2026-08-15T10:24:01.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_2","output":"Success. Updated the following files:\nA hello.txt"}}`;
    const { items } = parseTranscript(older, 'codex');
    expect(uses(items).map((x) => [x.name, x.summary])).toEqual([['shell', 'ls'], ['apply_patch', 'hello.txt']]);
    expect(uses(items)[1].detail).toContain('"patch"');
    expect(results(items).map((x) => x.tool)).toEqual(['shell', 'apply_patch']);
  });

  it('literal scanner: quoting, escapes, non-literal arguments', () => {
    const calls = codeModeCalls(String.raw`// tools.fake_in_comment({})
const x = "tools.not_a_call({})";
await tools.exec_command({cmd:'echo \'hi\' é', "max_output_tokens":10, list:[1, 2.5, true, null,],});
await tools.view_image({path: somePath});
await tools.apply_patch(` + '`*** Begin Patch\n*** Update File: a.py\n*** End Patch`);');
    expect(calls.map((c) => c.name)).toEqual(['exec_command', 'view_image', 'apply_patch']);
    expect(callCommand(calls[0])).toBe("echo 'hi' é");
    expect(((calls[0].args as Record<string, unknown>).list as unknown[]).length).toBe(4);
    expect(calls[1].hasArgs).toBe(false);
    expect(calls[1].raw).toBe('{path: somePath}');
    expect(patchFiles(callPatch(calls[2]) ?? '')).toEqual(['a.py']);
  });
});

describe('Grok', () => {
  it('ACP stream: chunk merging, tool lifecycle, plumbing dropped', () => {
    const { items } = parseTranscript(grokUpdates, 'grok');
    expect(items.length).toBe(5);
    expect(items[0].kind).toEqual({ t: 'userText', text: 'add a retry to the uploader' });
    expect(items[1].kind).toEqual({ t: 'thinking', text: 'The uploader lives in sync.rs.' });
    expect(items[2].kind).toMatchObject({ t: 'toolUse', name: 'run_shell', summary: 'cargo test uploader' });
    expect(items[3].kind).toEqual({ t: 'toolResult', tool: 'run_shell', content: 'test result: ok', isError: false });
    expect(items[4].kind).toEqual({ t: 'assistantText', text: 'Done — retry added.' });
    expect(items[0].timestamp).toBe(1_784_388_050_000);
  });
  it('failed tool update carries the error flag', () => {
    const jsonl = `{"timestamp":1,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"c","title":"edit_file","kind":"edit","rawInput":{"file_path":"/x/y.rs"}}}}
{"timestamp":2,"method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"c","status":"failed","rawOutput":"no such file"}}}`;
    const { items } = parseTranscript(jsonl);
    expect(items.length).toBe(2);
    expect(items[1].kind).toEqual({ t: 'toolResult', tool: 'Edit', content: 'no such file', isError: true });
  });
});

describe('Kimi', () => {
  it('wire journal: fold to conversation, injections and plumbing dropped', () => {
    const { items } = parseTranscript(kimiWire, 'kimi');
    expect(kinds(items)).toEqual([
      { t: 'userText', text: 'run echo for me' },
      { t: 'thinking', text: 'Simple enough.' },
      { t: 'assistantText', text: 'Let me run that.' },
      { t: 'toolUse', name: 'Bash', summary: 'echo kimi-transcript-test', detail: '{\n  "command" : "echo kimi-transcript-test"\n}' },
      { t: 'toolResult', tool: 'Bash', content: 'kimi-transcript-test', isError: false },
      { t: 'assistantText', text: 'Done.' },
    ]);
    expect(items[0].timestamp).toBe(1786809539590);
  });
  it('turnInProgress', () => {
    const open = kimiWire.split('\n').slice(0, -1).join('\n');
    expect(kimiTurnInProgress(kimiWire, 1786809539700)).toBe(false);
    expect(kimiTurnInProgress(open, 1786809539700)).toBe(true);
    expect(kimiTurnInProgress(open, 1786809539700 + 200_000)).toBe(false);
    expect(kimiTurnInProgress(open, 1786809539700, 180, 1786809549700)).toBe(false);
  });
});

describe('Claude', () => {
  it('local-command records are dropped and /clear starts the chat over', () => {
    const { items, cleared } = parseTranscript(claudeCleared);
    expect(cleared).toBe(true);
    expect(kinds(items)).toEqual([
      { t: 'userText', text: "Check a new model called 'jev'. Is it open weight?" },
      { t: 'assistantText', text: 'Looking.' },
    ]);
    expect(isLocalRecord('<bash-input>ls</bash-input>')).toBe(true);
    expect(isLocalRecord('plain words, a <system-reminder> later')).toBe(false);
  });

  it('questions resolve from toolUseResult; API errors are typed', () => {
    const jsonl = [
      { type: 'assistant', timestamp: '2026-09-19T20:00:00Z', message: { content: [{ type: 'tool_use', id: 'q1', name: 'AskUserQuestion',
        input: { questions: [{ question: 'Color?', header: 'C', options: [{ label: 'Red' }, { label: 'Blue', description: 'cool' }] }] } }] } },
      { type: 'user', toolUseResult: { answers: { 'Color?': 'Blue' } }, message: { content: [{ type: 'tool_result', tool_use_id: 'q1', content: 'ok' }] } },
      { type: 'assistant', isApiErrorMessage: true, error: 'rate_limit', message: { content: [{ type: 'text', text: 'API Error: 429 slow down' }] } },
      { type: 'assistant', isApiErrorMessage: true, message: { content: 'API Error: 451 Bromure blocked this request: possible prompt injection' } },
      { tool_name: 'AskUserQuestion', tool_input: { questions: [{ question: 'Pending?', options: [] }] } },
      { type: 'user', message: { content: 'Here: <pasted_content id="1">pasted text</pasted_content>' } },
    ].map((o) => JSON.stringify(o)).join('\n') + '\n{"type":"user","message":{"cont';
    const { items } = parseTranscript(jsonl, 'hermes');
    expect(items[0].kind).toEqual({ t: 'question', q: { question: 'Color?', header: 'C', multiSelect: false,
      options: [{ label: 'Red', description: '' }, { label: 'Blue', description: 'cool' }], answer: 'Blue' } });
    expect(items[1].kind).toEqual({ t: 'toolResult', tool: 'AskUserQuestion', content: 'ok', isError: false });
    expect(items[2].kind).toEqual({ t: 'agentError', error: { kind: 'rateLimit', status: 429, message: 'API Error: 429 slow down' } });
    const blocked = items[3].kind;
    expect(blocked.t === 'agentError' && blocked.error.kind).toBe('blocked');
    if (blocked.t === 'agentError') expect(apiErrorHeadline(blocked.error)).toBe('Blocked by Bromure — prompt injection');
    expect(items[4].kind).toEqual({ t: 'userText', text: 'Here: pasted text' });
    expect(items[5].kind).toMatchObject({ t: 'question', q: { question: 'Pending?' } });
    expect(items[5].timestamp).toBeUndefined();
    expect(unwrapPasted('a <pasted_content id="x">b</pasted_content id="x"> c')).toBe('a b c');
  });

  const dir = '/private/tmp/brmW-state/fixture';
  it.skipIf(!existsSync(dir))('demo fixtures parse as Claude with stable unique ids', () => {
    for (const f of readdirSync(dir).filter((x) => x.endsWith('.jsonl'))) {
      const text = readFileSync(`${dir}/${f}`, 'utf8');
      expect(sniffAgent(text)).toBe('claude');
      const { items } = parseTranscript(text);
      expect(items.length).toBeGreaterThan(0);
      expect(new Set(items.map((i) => i.id)).size).toBe(items.length);
    }
    const { items } = parseTranscript(readFileSync(`${dir}/checkout.jsonl`, 'utf8'));
    expect(items[2].kind).toMatchObject({ t: 'toolUse', name: 'Grep', summary: 'src' }); // "path" outranks "pattern" (Swift key order)
    expect(items[3].kind).toMatchObject({ t: 'toolResult', tool: 'Grep' });
    expect(items[4].kind).toMatchObject({ t: 'toolUse', name: 'Read', summary: '/home/ubuntu/northwind-web/src/api/orders.ts' });
    const last = items[items.length - 1].kind;
    expect(last.t === 'question' && last.q.answer).toBeUndefined();
    const shown = rewriteSharePaths(items, {});
    expect(shown[4].kind).toMatchObject({ summary: '~/northwind-web/src/api/orders.ts' });
  });
});

describe('omp', () => {
  const msg = (role: string, content: unknown, extra: Record<string, unknown> = {}) =>
    JSON.stringify({ type: 'message', timestamp: '2026-10-05T10:00:00.000Z', message: { role, content, ...extra } });

  it('attachment paste unwrapped; xd:// write is the MCP tool; xd/artifact reads', () => {
    const data = [
      JSON.stringify({ type: 'session', id: 's1', cwd: '/home/ubuntu/p', version: 3 }),
      msg('user', '<attachment>\nabc\n</attachment>'),
      msg('assistant', [{ type: 'toolCall', id: 'c1', name: 'write', intent: 'Delivering answer 42 to peer request',
        arguments: { path: 'xd://mcp__bromure-delegation__deliver', content: '{"delegation_id":"9bc4147c","summary":"42"}' } }]),
      msg('toolResult', [{ type: 'text', text: 'delivered' }], { toolName: 'write', toolCallId: 'c1', isError: false }),
      msg('assistant', [
        { type: 'toolCall', id: 'r1', name: 'read', arguments: { path: 'xd://mcp__bromure-delegation__request' } },
        { type: 'toolCall', id: 'r2', name: 'read', arguments: { path: 'artifact://11:raw' } },
      ]),
      msg('assistant', [], { stopReason: 'error', errorStatus: 451, errorMessage: '451 Bromure blocked this request: possible prompt injection detected in tool output.' }),
    ].join('\n');
    expect(sniffAgent(data)).toBe('omp');
    const { items } = parseTranscript(data);
    expect(items[0].kind).toEqual({ t: 'userText', text: 'abc' });
    const u = uses(items);
    expect(u[0]).toMatchObject({ name: 'mcp__bromure-delegation__deliver', summary: 'Delivering answer 42 to peer request' });
    expect(u[0].detail).toContain('"delegation_id"');
    expect(results(items)[0].tool).toBe('mcp__bromure-delegation__deliver');
    expect(u[1]).toMatchObject({ name: 'tool_lookup', summary: 'Looking up bromure delegation request' });
    expect(u[2]).toMatchObject({ name: 'read_output', summary: 'Reading earlier output #11' });
    expect(items[items.length - 1].kind).toMatchObject({ t: 'agentError', error: { kind: 'blocked', status: 451 } });
  });

  it('todo plan folds into one ticking checklist; ask resolves', () => {
    const data = [
      msg('assistant', [{ type: 'toolCall', id: 't1', name: 'todo', arguments: { op: 'init', list: [{ phase: 'P', items: ['write hello.py', 'write README.md', 'run tests'] }] } }]),
      msg('toolResult', [{ type: 'text', text: 'Remaining items (2):\n  - write README.md [in_progress] (P)\n  - run tests [pending] (P)' }], { toolName: 'todo', toolCallId: 't1' }),
      msg('assistant', [{ type: 'toolCall', id: 'a1', name: 'ask', arguments: { questions: [{ id: 'color', question: 'Which color?', options: [{ label: 'Green' }] }] } }]),
      msg('toolResult', [{ type: 'text', text: 'User selected: Green' }], { toolName: 'ask', toolCallId: 'a1' }),
    ].join('\n');
    const { items } = parseTranscript(data, 'omp');
    expect(items.length).toBe(2);
    expect(items[0].kind).toEqual({ t: 'todo', title: 'To-dos', rows: [
      { text: 'write hello.py', status: 'done', phase: 'P' },
      { text: 'write README.md', status: 'active', phase: 'P' },
      { text: 'run tests', status: 'pending', phase: 'P' },
    ] });
    expect(items[1].kind).toMatchObject({ t: 'question', q: { question: 'Which color?', header: 'color', answer: 'Green' } });
  });
});

describe('sniff, todo, share paths', () => {
  it('sniffing tells the stores apart, defaulting to Claude', () => {
    expect(sniffAgent(codexRollout)).toBe('codex');
    expect(sniffAgent(grokUpdates)).toBe('grok');
    expect(sniffAgent(kimiWire)).toBe('kimi');
    expect(sniffAgent('{"type":"user","message":{"role":"user","content":"hello"}}')).toBe('claude');
    expect(sniffAgent('garbage\n')).toBe('claude');
    expect(sniffAgent('berish"}}\n' + kimiWire)).toBe('kimi');
    expect(parseTranscript(kimiWire, 'goose').items.length).toBe(6);
  });

  it('TodoParse', () => {
    expect(todoRows({ op: 'done', phase: 'x' })).toEqual([]);
    expect(todoRows({ todos: [{ content: 'a', status: 'completed' }, { content: 'b', status: 'in_progress' }, { content: 'c', status: 'pending' }] })
      .map((r) => r.status)).toEqual(['done', 'active', 'pending']);
    expect(todoRows({ plan: [{ step: 'investigate', status: 'completed' }, { step: 'fix', status: 'in_progress' }] })
      .map((r) => r.status)).toEqual(['done', 'active']);
    expect(todoMerge([{ text: 'x', status: 'pending' }], undefined)).toEqual([{ text: 'x', status: 'pending' }]);
  });

  it('share paths: whole components, escaped JSON, shell commands keep the guest home', () => {
    const names = shareNames(['gk-demo']);
    const items = parseTranscript([
      JSON.stringify({ type: 'assistant', message: { content: [
        { type: 'tool_use', id: '1', name: 'Read', input: { file_path: '/mnt/bromure-share-1/a.txt' } },
        { type: 'tool_use', id: '2', name: 'Bash', input: { command: 'ls /home/ubuntu /mnt/bromure-share-10' } },
        { type: 'text', text: 'see /mnt/bromure-share-1/a.txt' },
      ] } }),
    ].join('\n')).items;
    const out = rewriteSharePaths(items, names);
    expect(out[0].kind).toMatchObject({ summary: '~/gk-demo/a.txt' });
    expect((out[0].kind as Extract<TranscriptKind, { t: 'toolUse' }>).detail).toContain('~\\/gk-demo\\/a.txt');
    expect(out[1].kind).toMatchObject({ summary: 'ls /home/ubuntu /mnt/bromure-share-10' });
    expect(out[2].kind).toEqual({ t: 'assistantText', text: 'see ~/gk-demo/a.txt' });
  });
});
