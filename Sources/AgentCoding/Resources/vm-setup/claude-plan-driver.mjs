#!/usr/bin/env node
// Bromure AC — claude plan driver (guest). Runs a headless Claude Code
// planning session through @anthropic-ai/claude-agent-sdk and speaks the
// plan-stream v1 vocabulary over its OWN stdio: events out (NDJSON on
// stdout), commands in (NDJSON on stdin). No hello — the python driver
// (bromure-plan-driver.py, ClaudeBridge) owns the vsock link and forwards
// both directions verbatim, so there is exactly one event vocabulary.
//
//   argv: <branch> <cwd> <prompt-b64> <mcp-config-json-path|->
//
// The SDK import resolves against ~/.bromure/plan-driver/node_modules —
// agentd npm-installs the pinned plan-driver-package.json there and the
// python driver copies this script alongside before spawning it (ESM bare
// imports resolve from the script's directory; NODE_PATH is ignored).

import { createInterface } from "node:readline";
import { readFileSync } from "node:fs";
import { query } from "@anthropic-ai/claude-agent-sdk";

const [branch, cwd, promptB64, mcpConfigPath] = process.argv.slice(2);
if (!branch || !cwd || promptB64 === undefined) {
  process.stderr.write(
    "usage: claude-plan-driver.mjs <branch> <cwd> <prompt-b64> <mcp-config>\n");
  process.exit(2);
}

const initialPrompt = Buffer.from(promptB64 || "", "base64")
  .toString("utf8");

// ── event emitter (stdout, one JSON object per line) ────────────────────────
function clamp(obj, key, cap) {
  if (typeof obj?.[key] === "string" && obj[key].length > cap) {
    obj[key] = obj[key].slice(0, cap) + "…[truncated]";
  }
}

function shrinkQuestion(ev) {
  // The bulk of an oversized question hides in options[].description —
  // the top-level truncation never reaches it, and a dropped question
  // would leave the SDK blocked awaiting an answer forever.
  for (const q of Array.isArray(ev.questions) ? ev.questions : []) {
    clamp(q, "question", 4000);
    clamp(q, "header", 500);
    for (const o of Array.isArray(q?.options) ? q.options : []) {
      clamp(o, "label", 500);
      clamp(o, "description", 4000);
    }
  }
}

// Returns true once the event was written, false when it had to be
// dropped for size — callers holding a blocked counterparty (questions)
// must then self-resolve.
function send(ev) {
  let line = JSON.stringify(ev);
  if (line.length > 1000000) {
    // Honor the 1 MB line cap of the outer protocol.
    for (const key of ["text", "summary", "error"]) {
      if (typeof ev[key] === "string" && ev[key].length > 64000) {
        ev[key] = ev[key].slice(0, 64000) + "…[truncated]";
      }
    }
    if (ev.ev === "question") shrinkQuestion(ev);
    line = JSON.stringify(ev);
    if (line.length > 1000000) return false;
  }
  process.stdout.write(line + "\n");
  return true;
}

function logErr(...parts) {
  process.stderr.write("[claude-plan] " + parts.join(" ") + "\n");
}

function trunc(s, n = 200) {
  s = String(s ?? "");
  return s.length <= n ? s : s.slice(0, n - 1) + "…";
}

// ── MCP config (the board shim) ─────────────────────────────────────────────
function loadMcpServers(path) {
  if (!path || path === "-") return null;
  try {
    const raw = JSON.parse(readFileSync(path, "utf8"));
    const servers = raw.mcpServers ?? raw;
    if (typeof servers !== "object" || servers === null) return null;
    const out = {};
    for (const [name, entry] of Object.entries(servers)) {
      if (entry && typeof entry === "object" && entry.command) {
        out[name] = { type: "stdio", command: entry.command,
                      args: entry.args ?? [], env: entry.env ?? {} };
      } else if (entry && typeof entry === "object") {
        out[name] = entry; // http/sse or already-typed entries: pass through
      }
    }
    return Object.keys(out).length > 0 ? out : null;
  } catch (e) {
    logErr("mcp config load failed:", String(e));
    return null;
  }
}

// ── streaming input: user turns arrive as "user" commands on stdin ──────────
const turnQueue = [];
let wakeGenerator = null;
let ended = false;

function wake() {
  if (wakeGenerator) {
    const w = wakeGenerator;
    wakeGenerator = null;
    w();
  }
}

function pushTurn(text) {
  turnQueue.push(text);
  wake();
}

function endSession() {
  ended = true;
  wake();
}

function userMessage(text) {
  return {
    type: "user",
    message: { role: "user", content: [{ type: "text", text }] },
    parent_tool_use_id: null,
  };
}

async function* userMessages() {
  yield userMessage(initialPrompt);
  for (;;) {
    while (turnQueue.length === 0 && !ended) {
      await new Promise((resolve) => { wakeGenerator = resolve; });
    }
    if (turnQueue.length > 0) {
      yield userMessage(turnQueue.shift());
      continue;
    }
    return; // ended: generator return ends the session cleanly
  }
}

// ── AskUserQuestion → v1 question / answer round-trip ───────────────────────
let qSeq = 0;
const pendingQuestions = new Map(); // qid -> resolve(answerCmd | null)

function resolveAllQuestions() {
  for (const [qid, resolve] of pendingQuestions) {
    pendingQuestions.delete(qid);
    resolve(null);
  }
}

async function canUseTool(toolName, input) {
  if (toolName !== "AskUserQuestion") {
    // Planning runs yolo: everything else is auto-approved. We keep
    // permissionMode "default" (NOT bypassPermissions) because bypass
    // skips canUseTool entirely and AskUserQuestion could never be
    // intercepted — this allow-all callback is the bypass equivalent.
    return { behavior: "allow", updatedInput: input };
  }
  const rawQuestions = Array.isArray(input?.questions) ? input.questions : [];
  const qid = "q" + ++qSeq;
  const delivered = send({
    ev: "question",
    qid,
    questions: rawQuestions.map((q) => ({
      question: q?.question ?? "",
      header: q?.header ?? "",
      multiSelect: !!q?.multiSelect,
      options: (Array.isArray(q?.options) ? q.options : []).map((o) => ({
        label: o?.label ?? "",
        description: o?.description ?? "",
      })),
    })),
  });
  // Undeliverable (size drop): behave as if resolved-with-null — never
  // block on a question the host cannot see.
  const cmd = delivered
    ? await new Promise((resolve) => { pendingQuestions.set(qid, resolve); })
    : null;
  if (!cmd) {
    // Interrupted / session ended / undeliverable while the picker was up.
    send({ ev: "question_resolved", qid });
    return { behavior: "deny", message: "The user dismissed the question." };
  }
  // Per the Agent SDK user-input docs: allow with updatedInput carrying the
  // original questions plus an answers map keyed by question text; values
  // are the selected label (string), labels array for multiSelect, or the
  // user's free-form text.
  const answers = {};
  const picked = matchAnswers(rawQuestions, cmd);
  rawQuestions.forEach((q, i) => {
    const a = picked[i];
    if (!a) return;
    const labels = Array.isArray(a.labels) ? a.labels.filter(
      (l) => typeof l === "string") : [];
    const other = typeof a.other === "string" && a.other !== ""
      ? a.other : null;
    answers[q?.question ?? ""] = q?.multiSelect
      ? (other ? [...labels, other] : labels)
      : (other ?? labels[0] ?? "");
  });
  return {
    behavior: "allow",
    updatedInput: { questions: input.questions, answers },
  };
}

// Two passes — mirror of the python driver's _match_answers — so a
// positional fallback can never steal an answer that text-matched a
// different question: exact question-text matches first (consuming),
// then leftover answers fill leftover questions in order.
function matchAnswers(rawQuestions, cmd) {
  const list = (Array.isArray(cmd.answers) ? cmd.answers : [])
    .filter((a) => a && typeof a === "object");
  const used = list.map(() => false);
  const picked = rawQuestions.map(() => null);
  rawQuestions.forEach((q, i) => {
    const qtext = q?.question ?? "";
    for (let j = 0; j < list.length; j++) {
      if (!used[j] && list[j].question === qtext) {
        picked[i] = list[j];
        used[j] = true;
        break;
      }
    }
  });
  const leftovers = list.filter((_, j) => !used[j]);
  for (let i = 0; i < picked.length; i++) {
    if (!picked[i] && leftovers.length > 0) picked[i] = leftovers.shift();
  }
  return picked;
}

// ── SDK message stream → v1 events ──────────────────────────────────────────
const toolNames = new Map(); // tool_use_id -> tool name
let lastTurnOk = true;
let lastTurnError = null;

function summarizeToolInput(name, input) {
  if (!input || typeof input !== "object") return name;
  return input.command ?? input.file_path ?? input.pattern ??
    input.description ?? input.url ?? input.prompt ??
    trunc(JSON.stringify(input));
}

function contentText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.filter((b) => b?.type === "text")
    .map((b) => b.text ?? "").join("\n");
}

function handleMessage(msg) {
  switch (msg?.type) {
    case "system":
      if (msg.subtype === "init") send({ ev: "state", state: "working" });
      return;
    case "assistant": {
      const blocks = msg.message?.content ?? msg.content ?? [];
      if (!Array.isArray(blocks)) return;
      for (const b of blocks) {
        if (b?.type === "text" && b.text) {
          send({ ev: "text", role: "assistant", text: b.text });
        } else if (b?.type === "thinking" && b.thinking) {
          send({ ev: "thinking", text: b.thinking });
        } else if (b?.type === "tool_use") {
          toolNames.set(b.id, b.name);
          send({ ev: "tool", name: b.name ?? "tool",
                 summary: trunc(summarizeToolInput(b.name, b.input)) });
        }
      }
      return;
    }
    case "user": {
      // SDK-synthesized user messages carry tool_result blocks.
      const blocks = msg.message?.content;
      if (!Array.isArray(blocks)) return;
      for (const b of blocks) {
        if (b?.type === "tool_result") {
          send({
            ev: "tool_result",
            name: toolNames.get(b.tool_use_id) ?? "tool",
            ok: !b.is_error,
            summary: trunc(contentText(b.content)),
          });
        }
      }
      return;
    }
    case "result":
      // Streaming-input mode emits one SDK "result" per completed turn.
      // v1's "result" is TERMINAL (session over), so a per-turn result
      // maps to state idle; the terminal v1 result goes out when the
      // whole query ends (host "end" command closed the generator).
      lastTurnOk = !msg.is_error;
      lastTurnError = msg.is_error
        ? String(msg.result ?? msg.subtype ?? "error") : null;
      send({ ev: "state", state: "idle" });
      return;
    default:
      return; // forward compat: unknown SDK message types are ignored
  }
}

// ── main ────────────────────────────────────────────────────────────────────
const mcpServers = loadMcpServers(mcpConfigPath);

const q = query({
  prompt: userMessages(),
  options: {
    cwd,
    permissionMode: "default", // see canUseTool: default + allow-all = yolo
    canUseTool,
    ...(mcpServers ? { mcpServers } : {}),
  },
});

// stdin: v1 commands forwarded by the python bridge.
const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  line = line.trim();
  if (!line) return;
  let cmd;
  try {
    cmd = JSON.parse(line);
  } catch {
    logErr("unparseable command ignored");
    return;
  }
  switch (cmd?.cmd) {
    case "user":
      // Echo the turn so the host transcript shows what was asked.
      send({ ev: "text", role: "user", text: cmd.text ?? "" });
      send({ ev: "state", state: "working" });
      pushTurn(cmd.text ?? "");
      return;
    case "answer": {
      const resolve = pendingQuestions.get(cmd.qid);
      if (resolve) {
        pendingQuestions.delete(cmd.qid);
        resolve(cmd);
      } else {
        logErr("answer for unknown qid ignored:", String(cmd.qid));
      }
      return;
    }
    case "interrupt":
      resolveAllQuestions();
      if (typeof q.interrupt === "function") {
        q.interrupt().catch((e) => logErr("interrupt failed:", String(e)));
      } else {
        logErr("query.interrupt unavailable in this SDK build");
      }
      return;
    case "end":
      resolveAllQuestions();
      endSession();
      // Cut short an in-flight turn so teardown is prompt, and force the
      // terminal result if the SDK iterator somehow never completes.
      if (typeof q.interrupt === "function") {
        q.interrupt().catch(() => {});
      }
      setTimeout(() => {
        send({ ev: "result", ok: lastTurnOk, error: lastTurnError });
        process.exit(0);
      }, 30000).unref();
      return;
    default:
      logErr("unknown command ignored:", String(cmd?.cmd));
  }
});
rl.on("close", () => {
  // Bridge went away — wind the session down; the result event (or our
  // exit) tells the python side we are done.
  resolveAllQuestions();
  endSession();
});

send({ ev: "state", state: "starting" });
// The brief: echoed as a user turn so the host's plan window renders it.
send({ ev: "text", role: "user", text: initialPrompt });
try {
  for await (const msg of q) {
    handleMessage(msg);
  }
  send({ ev: "result", ok: lastTurnOk, error: lastTurnError });
  process.exit(0);
} catch (e) {
  send({ ev: "fatal", error: trunc(String(e?.stack ?? e), 2000) });
  process.exit(1);
}
