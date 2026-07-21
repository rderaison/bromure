#!/usr/bin/python3 -u
"""Bromure AC plan-stream driver — runs INSIDE the guest VM.

Headless replacement for the tmux planning tab (`_plan_tab` in
bromure-agentd.py): instead of scraping a TUI transcript, this process runs
the coding agent through its machine protocol and emits normalized NDJSON
events (plan-stream protocol v1) to the host over vsock port 5832.

    argv: <tool> <branch> <cwd> <prompt-b64>      tool = claude|codex|grok

Per tool:
  * codex  — spawns `codex app-server` (JSON-RPC 2.0 over stdio, JSONL) and
             adapts the v2 thread/turn/item protocol.
  * grok   — spawns `grok agent stdio` (ACP: JSON-RPC 2.0 over stdio) and
             adapts session/new + session/prompt + session/update.
  * claude — spawns `node claude-plan-driver.mjs` (Claude Agent SDK) and
             bridges the node driver's stdio NDJSON — which speaks the SAME
             v1 event/command vocabulary, minus the hello — to the vsock
             link (node has no AF_VSOCK, so python stays the transport).

Wire contract (see plan-stream-protocol.md, frozen 2026-07-20):
  guest→host  hello, state, text, thinking, tool, tool_result, question,
              question_resolved, result (terminal), fatal (terminal)
  host→guest  user, answer, interrupt, end
The driver reconnects with a fresh hello on socket drop and replays nothing.
Planning runs yolo: tool approvals are auto-accepted; only structured user
questions surface to the host. Stdlib only — no pip packages in the guest.
"""

import base64
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import traceback

HOST_CID = socket.VMADDR_CID_HOST if hasattr(socket, "VMADDR_CID_HOST") else 2
PLAN_STREAM_PORT = 5832           # SessionDisk.planStreamVsockPort
MAX_LINE = 1024 * 1024            # protocol: one JSON object per line, <=1 MB

HOME = os.path.expanduser("~")
META = "/mnt/bromure-meta"
TASK_MCP_SHIM = os.path.join(META, "bromure-task-mcp.py")
CLAUDE_DRIVER_SRC = os.path.join(META, "claude-plan-driver.mjs")
PLAN_DRIVER_HOME = os.path.join(HOME, ".bromure", "plan-driver")


def log(*parts):
    msg = " ".join(str(p) for p in parts)
    try:
        sys.stderr.write("%s [plan-driver] %s\n"
                         % (time.strftime("%H:%M:%S"), msg))
        sys.stderr.flush()
    except Exception:
        pass


def _b64d(s):
    try:
        return base64.b64decode(s).decode("utf-8", "replace")
    except Exception:
        return ""


def _trunc(s, n=200):
    s = str(s or "")
    return s if len(s) <= n else s[:n - 1] + "…"


def _shrink_question(ev):
    """Clamp a question event's long fields in place. The bulk of an
    oversized question hides in questions[].options[].description — the
    top-level text/summary truncation never touches it, and a DROPPED
    question would leave the agent blocked awaiting an answer forever."""
    for q in ev.get("questions") or []:
        if not isinstance(q, dict):
            continue
        for key, cap in (("question", 4000), ("header", 500)):
            if isinstance(q.get(key), str) and len(q[key]) > cap:
                q[key] = q[key][:cap] + "…[truncated]"
        for o in q.get("options") or []:
            if not isinstance(o, dict):
                continue
            for key, cap in (("label", 500), ("description", 4000)):
                if isinstance(o.get(key), str) and len(o[key]) > cap:
                    o[key] = o[key][:cap] + "…[truncated]"


# ─────────────────────────── vsock NDJSON link ──────────────────────────────
class VsockLink:
    """Reconnecting NDJSON channel to the host's plan-stream listener.

    Mirrors the bromure-task-mcp shim's connect/backoff pattern, with one
    protocol difference: after every (re)connect the first line out is the
    v1 hello. Nothing is replayed after a drop — the host keeps rendered
    state; at worst events in flight during the drop are lost.
    """

    def __init__(self, branch, tool):
        self.branch = branch
        self.tool = tool
        self._sock = None
        self._state_lock = threading.Lock()
        self._conn_lock = threading.Lock()
        self._send_lock = threading.Lock()
        self._closed = False
        self._reported = False

    def close(self):
        self._closed = True
        s = self._current()
        if s is not None:
            self._drop(s)

    def _current(self):
        with self._state_lock:
            return self._sock

    def _drop(self, s):
        with self._state_lock:
            if self._sock is s:
                self._sock = None
        try:
            s.close()
        except OSError:
            pass

    def _ensure(self):
        """Serialize dials; loser of the race reuses the winner's socket.
        Backoff 0.2s -> 5s, forever until close()."""
        with self._conn_lock:
            existing = self._current()
            if existing is not None:
                return existing
            delay = 0.2
            while not self._closed:
                try:
                    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
                    s.connect((HOST_CID, PLAN_STREAM_PORT))
                    hello = json.dumps(
                        {"v": 1, "ev": "hello",
                         "branch": self.branch, "tool": self.tool},
                        separators=(",", ":")) + "\n"
                    s.sendall(hello.encode("utf-8"))
                    with self._state_lock:
                        self._sock = s
                    return s
                except OSError as e:
                    if not self._reported:
                        self._reported = True
                        log("host not reachable yet (%s) — retrying" % e)
                    time.sleep(delay)
                    delay = min(delay * 2, 5.0)
            return None

    def send(self, ev):
        """Emit one event line, truncating oversized fields to honor the
        1 MB cap (question events get a structure-aware shrink — their bulk
        hides in option descriptions). Returns True once handed to the
        socket, False when the event had to be dropped (size cap or dead
        link) so callers with a blocked counterparty can self-resolve."""
        line = json.dumps(ev, separators=(",", ":")) + "\n"
        if len(line) > MAX_LINE:
            for key in ("text", "summary", "error"):
                if isinstance(ev.get(key), str) and len(ev[key]) > 64000:
                    ev[key] = ev[key][:64000] + "…[truncated]"
            if ev.get("ev") == "question":
                _shrink_question(ev)
            line = json.dumps(ev, separators=(",", ":")) + "\n"
            if len(line) > MAX_LINE:
                log("event too large — dropped:", ev.get("ev"))
                return False
        data = line.encode("utf-8")
        with self._send_lock:
            for _attempt in (0, 1):
                s = self._current() or self._ensure()
                if s is None:
                    return False
                try:
                    s.sendall(data)
                    return True
                except OSError:
                    self._drop(s)
        log("event dropped (link down):", ev.get("ev"))
        return False

    def recv_loop(self, on_cmd):
        """Read host command lines forever, reconnecting on drops."""
        buf = b""
        cur = None
        while not self._closed:
            s = self._current() or self._ensure()
            if s is None:
                return
            if s is not cur:
                cur = s
                buf = b""     # never carry a partial line across sockets
            try:
                chunk = s.recv(65536)
            except OSError:
                chunk = b""
            if not chunk:
                self._drop(s)
                if self._closed:
                    return
                time.sleep(0.2)
                continue
            buf += chunk
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    obj = json.loads(raw.decode("utf-8", "replace"))
                except ValueError:
                    log("unparseable host command ignored")
                    continue
                try:
                    on_cmd(obj)
                except Exception:
                    log("command handler crashed:\n" + traceback.format_exc())


# ─────────────────────────── JSON-RPC child ─────────────────────────────────
class JsonRpcChild:
    """A JSON-RPC 2.0 (JSONL over stdio) child process — codex app-server
    and grok's ACP server both speak this framing."""

    def __init__(self, argv, on_notification, on_request, on_exit, cwd=None):
        self.on_notification = on_notification
        self.on_request = on_request
        self.on_exit = on_exit
        self.proc = subprocess.Popen(
            argv, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1)
        self._id = 0
        self._id_lock = threading.Lock()
        self._pending = {}            # id -> dict(event=..., callback=...)
        self._pending_lock = threading.Lock()
        self._write_lock = threading.Lock()
        threading.Thread(target=self._read_loop, daemon=True).start()
        threading.Thread(target=self._drain_stderr, daemon=True).start()

    def _next_id(self):
        with self._id_lock:
            self._id += 1
            return self._id

    def _write(self, obj):
        line = json.dumps(obj, separators=(",", ":")) + "\n"
        with self._write_lock:
            self.proc.stdin.write(line)
            self.proc.stdin.flush()

    def notify(self, method, params=None):
        try:
            self._write({"jsonrpc": "2.0", "method": method,
                         "params": params if params is not None else {}})
        except (OSError, ValueError):
            log("notify %s failed (child gone?)" % method)

    def request_async(self, method, params, callback):
        """Send a request; callback(result, error) fires on the reader
        thread when the response lands (never for a dead child)."""
        rpc_id = self._next_id()
        with self._pending_lock:
            self._pending[rpc_id] = {"callback": callback}
        try:
            self._write({"jsonrpc": "2.0", "id": rpc_id, "method": method,
                         "params": params if params is not None else {}})
        except (OSError, ValueError):
            with self._pending_lock:
                self._pending.pop(rpc_id, None)
            callback(None, {"message": "child write failed"})
        return rpc_id

    def request(self, method, params=None, timeout=120):
        """Blocking request. Returns (result, error); error is a dict, or
        {"message": "timeout"} when the child never answers."""
        done = threading.Event()
        box = {}

        def _cb(result, error):
            box["result"] = result
            box["error"] = error
            done.set()

        self.request_async(method, params, _cb)
        if not done.wait(timeout):
            return None, {"message": "timeout waiting for %s" % method}
        return box.get("result"), box.get("error")

    def respond(self, rpc_id, result=None, error=None):
        msg = {"jsonrpc": "2.0", "id": rpc_id}
        if error is not None:
            msg["error"] = error
        else:
            msg["result"] = result
        try:
            self._write(msg)
        except (OSError, ValueError):
            log("respond to %s failed (child gone?)" % rpc_id)

    def terminate(self):
        try:
            self.proc.terminate()
        except OSError:
            pass

    def _read_loop(self):
        try:
            for line in self.proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    log("non-JSON child stdout ignored:", _trunc(line, 120))
                    continue
                if not isinstance(msg, dict):
                    continue
                try:
                    if "method" in msg and "id" in msg:
                        self.on_request(msg)
                    elif "method" in msg:
                        self.on_notification(msg)
                    elif "id" in msg:
                        self._resolve(msg)
                except Exception:
                    log("child message handler crashed:\n"
                        + traceback.format_exc())
        except (OSError, ValueError):
            pass
        rc = self.proc.wait()
        # Fail any requests still in flight so blocking callers wake up.
        with self._pending_lock:
            pending = list(self._pending.values())
            self._pending.clear()
        for entry in pending:
            try:
                entry["callback"](None, {"message": "child exited"})
            except Exception:
                pass
        self.on_exit(rc)

    def _resolve(self, msg):
        with self._pending_lock:
            entry = self._pending.pop(msg.get("id"), None)
        if entry is None:
            log("response for unknown id ignored:", msg.get("id"))
            return
        entry["callback"](msg.get("result"), msg.get("error"))

    def _drain_stderr(self):
        try:
            for line in self.proc.stderr:
                line = line.rstrip()
                if line:
                    log("child:", _trunc(line, 400))
        except (OSError, ValueError):
            pass


# ─────────────────────────── driver base ────────────────────────────────────
class Driver:
    def __init__(self, link, branch, cwd, prompt):
        self.link = link
        self.branch = branch
        self.cwd = cwd
        self.prompt = prompt
        self.done = threading.Event()   # set once result/fatal was emitted
        self.exit_code = 0

    # v1 event emitters
    def ev_state(self, state):
        self.link.send({"ev": "state", "state": state})

    def ev_text(self, role, text):
        if text:
            self.link.send({"ev": "text", "role": role, "text": text})

    def ev_thinking(self, text):
        if text:
            self.link.send({"ev": "thinking", "text": text})

    def ev_tool(self, name, summary):
        self.link.send({"ev": "tool", "name": name,
                        "summary": _trunc(summary)})

    def ev_tool_result(self, name, ok, summary):
        self.link.send({"ev": "tool_result", "name": name, "ok": bool(ok),
                        "summary": _trunc(summary)})

    def ev_question(self, qid, questions):
        """Returns False when the question could not be delivered — the
        caller MUST then self-resolve it, or the agent wedges."""
        return self.link.send({"ev": "question", "qid": qid,
                               "questions": questions})

    def ev_question_resolved(self, qid):
        self.link.send({"ev": "question_resolved", "qid": qid})

    def finish(self, ok=True, error=None):
        if self.done.is_set():
            return
        self.link.send({"ev": "result", "ok": bool(ok), "error": error})
        self.done.set()

    def fatal(self, msg):
        if self.done.is_set():
            return
        log("fatal:", msg)
        self.link.send({"ev": "fatal", "error": _trunc(str(msg), 2000)})
        self.exit_code = 1
        self.done.set()

    def handle_cmd(self, cmd):
        """Host command dispatcher — runs on the vsock receive thread."""
        if self.done.is_set():
            return                      # events after result/fatal: ignored
        action = cmd.get("cmd")
        if action == "user":
            text = cmd.get("text") or ""
            # Echo the turn so the host transcript shows what was asked.
            # (ClaudeBridge overrides handle_cmd; the node driver echoes
            # its own turns — no duplication.)
            self.ev_text("user", text)
            self.on_user(text)
        elif action == "answer":
            self.on_answer(cmd)
        elif action == "interrupt":
            self.on_interrupt()
        elif action == "end":
            self.on_end()
        else:
            log("unknown host command ignored:", action)

    # subclass hooks
    def on_user(self, text):
        pass

    def on_answer(self, cmd):
        pass

    def on_interrupt(self):
        pass

    def on_end(self):
        self.finish(ok=True)

    def run(self):
        raise NotImplementedError


def _match_answers(questions, cmd):
    """Pair the host's v1 answers with the agent's original questions.

    v1 answer shape: {"cmd":"answer","qid":...,"answers":[
        {"question":"...","labels":["..."],"other":null}]}
    Two passes so a positional fallback can never steal an answer that
    text-matched a different question: exact question-text matches first
    (consuming), then leftover answers fill leftover questions in order.
    Returns a list of (question, [answer strings]) in question order.
    """
    raw = [a for a in (cmd.get("answers") or []) if isinstance(a, dict)]
    used = [False] * len(raw)
    picked = [None] * len(questions)
    for i, q in enumerate(questions):
        qtext = q.get("question") or ""
        for j, a in enumerate(raw):
            if not used[j] and a.get("question") == qtext:
                picked[i] = a
                used[j] = True
                break
    leftovers = [a for j, a in enumerate(raw) if not used[j]]
    for i in range(len(questions)):
        if picked[i] is None and leftovers:
            picked[i] = leftovers.pop(0)
    out = []
    for q, ans in zip(questions, picked):
        values = []
        if ans:
            values = [x for x in (ans.get("labels") or [])
                      if isinstance(x, str)]
            other = ans.get("other")
            if isinstance(other, str) and other:
                values.append(other)
        out.append((q, values))
    return out


# ─────────────────────────── codex adapter ──────────────────────────────────
# Wire shapes verified against openai/codex codex-rs/app-server-protocol
# (protocol/common.rs + protocol/v2/item.rs, main @ 2026-07-20):
#   item/commandExecution/requestApproval → response {"decision":"accept"}
#   item/fileChange/requestApproval       → response {"decision":"accept"}
#   item/tool/requestUserInput params.questions[]:
#       {id, header, question, isOther, isSecret, options:[{label,description}]}
#   ... response: {"answers": {"<question id>": {"answers": ["..."]}}}
class CodexDriver(Driver):

    def __init__(self, link, branch, cwd, prompt):
        Driver.__init__(self, link, branch, cwd, prompt)
        self.child = None
        self.thread_id = None
        self._turn_active = False
        self._queued_turns = []
        self._turn_lock = threading.Lock()
        self._questions = {}           # qid -> {"rpc_id":..., "raw":[...]}
        self._q_lock = threading.Lock()

    def run(self):
        argv = ["codex", "app-server"]
        if os.path.exists(TASK_MCP_SHIM):
            # Board MCP wiring: same per-invocation `-c` TOML overrides that
            # agentd's _task_mcp_setup uses for `codex exec` — the -c flag is
            # a root codex CLI option, so it applies to `codex app-server`
            # too (config overrides are process-wide; threads inherit them).
            args = json.dumps([TASK_MCP_SHIM, self.branch],
                              separators=(",", ":"))
            argv += ["-c", 'mcp_servers.bromure_board.command="python3"',
                     "-c", "mcp_servers.bromure_board.args=" + args]
        self.ev_state("starting")
        self.child = JsonRpcChild(argv, self._on_notification,
                                  self._on_request, self._on_exit,
                                  cwd=self.cwd)
        result, error = self.child.request("initialize", {
            "clientInfo": {"name": "bromure_plan_driver",
                           "title": "Bromure Plan Driver",
                           "version": "1.0.0"},
            # experimentalApi unlocks the v2 thread/turn surface incl.
            # tool/requestUserInput.
            "capabilities": {"experimentalApi": True},
        }, timeout=60)
        if error:
            self.fatal("codex initialize failed: %s" % error)
            return self._cleanup()
        self.child.notify("initialized")
        result, error = self.child.request("thread/start", {
            "cwd": self.cwd,
            # Planning runs yolo (mirror of --dangerously-bypass-approvals-
            # and-sandbox on the tmux path); approvals are also auto-accepted
            # below in case the server prompts anyway.
            "approvalPolicy": "never",
            "sandbox": "danger-full-access",
        }, timeout=60)
        if error:
            # UNVERIFIED: approvalPolicy/sandbox value spelling could drift
            # between codex releases — retry bare before giving up.
            log("thread/start with policy failed (%s) — retrying bare"
                % error)
            result, error = self.child.request(
                "thread/start", {"cwd": self.cwd}, timeout=60)
        if error or not isinstance(result, dict):
            self.fatal("codex thread/start failed: %s" % error)
            return self._cleanup()
        thread = result.get("thread") or {}
        self.thread_id = thread.get("id")
        if not self.thread_id:
            self.fatal("codex thread/start returned no thread id")
            return self._cleanup()
        self.ev_text("user", self.prompt)   # the brief, for the plan window
        self._start_turn(self.prompt, initial=True)
        self.done.wait()
        self._cleanup()

    def _cleanup(self):
        if self.child is not None:
            self.child.terminate()

    def _start_turn(self, text, initial=False):
        with self._turn_lock:
            if self._turn_active:
                self._queued_turns.append(text)
                return
            self._turn_active = True
        self.ev_state("working")

        def _cb(result, error):
            if not error:
                return
            if initial:
                # A failed FIRST turn means the session never produced
                # anything — going idle would leave the host staring at a
                # hello'd, forever-empty session. Die loudly instead.
                self.fatal("codex turn/start failed: %s" % error)
                return
            log("turn/start failed:", error)
            with self._turn_lock:
                self._turn_active = False
                queued = self._queued_turns.pop(0) \
                    if self._queued_turns else None
            self.ev_state("idle")
            if queued is not None:
                self._start_turn(queued)

        self.child.request_async("turn/start", {
            "threadId": self.thread_id,
            "input": [{"type": "text", "text": text}],
        }, _cb)

    # notifications (codex → driver)
    def _on_notification(self, msg):
        method = msg.get("method") or ""
        params = msg.get("params") or {}
        if method == "item/started":
            self._item_started(params.get("item") or {})
        elif method == "item/completed":
            self._item_completed(params.get("item") or {})
        elif method == "turn/completed":
            turn = params.get("turn") or {}
            status = turn.get("status")
            if status == "failed":
                log("turn failed:", _trunc(json.dumps(turn), 400))
            with self._turn_lock:
                self._turn_active = False
                queued = self._queued_turns.pop(0) \
                    if self._queued_turns else None
            self.ev_state("idle")
            if queued is not None:
                self._start_turn(queued)
        elif method == "serverRequest/resolved":
            # Codex cleared a pending server request itself (turn ended /
            # interrupted before the host answered) — release the question.
            self._resolve_question_by_rpc_id(params.get("requestId"))
        # deltas + turn/started + everything else: ignored (v1 has no deltas)

    def _item_started(self, item):
        kind = item.get("type")
        if kind == "commandExecution":
            self.ev_tool("command", item.get("command") or "")
        elif kind == "mcpToolCall":
            self.ev_tool("%s.%s" % (item.get("server") or "mcp",
                                    item.get("tool") or "tool"),
                         item.get("tool") or "")
        elif kind == "fileChange":
            paths = [c.get("path") or "" for c in item.get("changes") or []
                     if isinstance(c, dict)]
            self.ev_tool("file_change", " ".join(paths) or "file change")

    def _item_completed(self, item):
        kind = item.get("type")
        if kind == "agentMessage":
            self.ev_text("assistant", item.get("text") or "")
        elif kind == "plan":
            self.ev_text("assistant", item.get("text") or "")
        elif kind == "reasoning":
            text = "\n".join(item.get("summary") or []) \
                or "\n".join(item.get("content") or [])
            self.ev_thinking(text)
        elif kind == "commandExecution":
            ok = item.get("status") not in ("failed", "declined")
            self.ev_tool_result("command", ok, item.get("command") or "")
        elif kind == "mcpToolCall":
            ok = item.get("status") not in ("failed", "declined")
            self.ev_tool_result("%s.%s" % (item.get("server") or "mcp",
                                           item.get("tool") or "tool"),
                                ok, item.get("tool") or "")
        elif kind == "fileChange":
            ok = item.get("status") not in ("failed", "declined")
            paths = [c.get("path") or "" for c in item.get("changes") or []
                     if isinstance(c, dict)]
            self.ev_tool_result("file_change", ok, " ".join(paths))

    # server-initiated requests (codex → driver, must be answered)
    def _on_request(self, msg):
        method = msg.get("method") or ""
        rpc_id = msg.get("id")
        if method == "item/commandExecution/requestApproval":
            self.child.respond(rpc_id, {"decision": "accept"})
        elif method == "item/fileChange/requestApproval":
            self.child.respond(rpc_id, {"decision": "accept"})
        elif method in ("execCommandApproval", "applyPatchApproval"):
            # v1-protocol spelling of the same approvals (older servers).
            self.child.respond(rpc_id, {"decision": "approved"})
        elif method in ("item/tool/requestUserInput",
                        "tool/requestUserInput"):
            self._question_request(rpc_id, msg.get("params") or {})
        else:
            log("unsupported codex server request:", method)
            self.child.respond(rpc_id, error={
                "code": -32601, "message": "unsupported by plan driver"})

    def _question_request(self, rpc_id, params):
        raw = [q for q in (params.get("questions") or [])
               if isinstance(q, dict)]
        qid = "q%s" % rpc_id
        questions = []
        for q in raw:
            questions.append({
                "question": q.get("question") or "",
                "header": q.get("header") or "",
                # codex questions are single-select (isOther adds a free-form
                # option, which v1 carries back via "other").
                "multiSelect": False,
                "options": [{"label": o.get("label") or "",
                             "description": o.get("description") or ""}
                            for o in (q.get("options") or [])
                            if isinstance(o, dict)],
            })
        with self._q_lock:
            self._questions[qid] = {"rpc_id": rpc_id, "raw": raw}
        if not self.ev_question(qid, questions):
            # The host never saw the question (size drop / dead link) —
            # self-answer with each question's first option so the turn
            # can never wedge on an unseen picker.
            log("question %s undeliverable — self-answering" % qid)
            with self._q_lock:
                self._questions.pop(qid, None)
            answers = {}
            for q in raw:
                opts = [o for o in (q.get("options") or [])
                        if isinstance(o, dict)]
                first = opts[0].get("label") if opts else ""
                answers[q.get("id") or q.get("question") or ""] = \
                    {"answers": [first or ""]}
            self.child.respond(rpc_id, {"answers": answers})

    def on_answer(self, cmd):
        qid = cmd.get("qid")
        with self._q_lock:
            pending = self._questions.pop(qid, None)
        if pending is None:
            log("answer for unknown qid ignored:", qid)
            return
        answers = {}
        for q, values in _match_answers(pending["raw"], cmd):
            if not values:
                # Never leave a question unanswered in the response map —
                # default to the first option so codex can proceed.
                opts = q.get("options") or []
                first = opts[0].get("label") if opts else ""
                values = [first or ""]
            answers[q.get("id") or q.get("question") or ""] = \
                {"answers": values}
        self.child.respond(pending["rpc_id"], {"answers": answers})

    def _resolve_question_by_rpc_id(self, request_id):
        with self._q_lock:
            for qid, pending in list(self._questions.items()):
                if str(pending["rpc_id"]) == str(request_id):
                    del self._questions[qid]
                    self.ev_question_resolved(qid)
                    return

    # host commands
    def on_user(self, text):
        self._start_turn(text)

    def on_interrupt(self):
        self.child.request_async("turn/interrupt",
                                 {"threadId": self.thread_id},
                                 lambda r, e: None)

    def on_end(self):
        self.finish(ok=True)

    def _on_exit(self, rc):
        if not self.done.is_set():
            self.fatal("codex app-server exited unexpectedly (rc=%s)" % rc)


# ─────────────────────────── grok adapter ───────────────────────────────────
# grok speaks ACP (Agent Client Protocol) over stdio: `grok agent stdio`.
# Per docs.x.ai/build/cli/headless-scripting: initialize (protocolVersion 1),
# authenticate (methodId, _meta.headless), session/new (cwd, mcpServers),
# session/prompt (blocks until the turn ends, returns stopReason);
# session/update notifications stream agent_message_chunk etc.
class GrokDriver(Driver):

    def __init__(self, link, branch, cwd, prompt):
        Driver.__init__(self, link, branch, cwd, prompt)
        self.child = None
        self.session_id = None
        self._turn_active = False
        self._queued_turns = []
        self._turn_lock = threading.Lock()
        self._text_buf = []
        self._thought_buf = []
        self._tool_titles = {}         # toolCallId -> title

    def run(self):
        self.ev_state("starting")
        self.child = JsonRpcChild(["grok", "agent", "stdio"],
                                  self._on_notification, self._on_request,
                                  self._on_exit, cwd=self.cwd)
        result, error = self.child.request("initialize", {
            "protocolVersion": 1,
            "clientCapabilities": {
                "fs": {"readTextFile": False, "writeTextFile": False},
                "terminal": False,
            },
        }, timeout=60)
        if error:
            self.fatal("grok initialize failed: %s" % error)
            return self._cleanup()
        auth_methods = (result or {}).get("authMethods") or []
        result, error = self._session_new()
        if error and auth_methods:
            # Auth required: try the advertised methods with cached
            # credentials — the guest env/proxy handles the real tokens.
            # UNVERIFIED: exact headless auth error signaling; we just retry
            # session/new after each successful authenticate.
            for method in auth_methods:
                method_id = method.get("id") if isinstance(method, dict) \
                    else method
                if not method_id:
                    continue
                _r, auth_err = self.child.request("authenticate", {
                    "methodId": method_id, "_meta": {"headless": True},
                }, timeout=60)
                if auth_err:
                    continue
                result, error = self._session_new()
                if not error:
                    break
        if error or not isinstance(result, dict):
            self.fatal("grok session/new failed: %s" % error)
            return self._cleanup()
        self.session_id = result.get("sessionId")
        if not self.session_id:
            self.fatal("grok session/new returned no sessionId")
            return self._cleanup()
        self.ev_text("user", self.prompt)   # the brief, for the plan window
        self._start_turn(self.prompt, initial=True)
        self.done.wait()
        self._cleanup()

    def _cleanup(self):
        if self.child is not None:
            self.child.terminate()

    def _session_new(self):
        params = {"cwd": self.cwd, "mcpServers": []}
        if os.path.exists(TASK_MCP_SHIM):
            # Board MCP over ACP's native stdio-server list (same shim +
            # branch argument as agentd's _task_mcp_setup writes into
            # .grok/settings.json for tmux runs).
            params["mcpServers"] = [{
                "name": "bromure-board",
                "command": "python3",
                "args": [TASK_MCP_SHIM, self.branch],
                "env": [],
            }]
        return self.child.request("session/new", params, timeout=60)

    def _start_turn(self, text, initial=False):
        with self._turn_lock:
            if self._turn_active:
                self._queued_turns.append(text)
                return
            self._turn_active = True
        self._text_buf = []
        self._thought_buf = []
        self.ev_state("working")

        def _cb(result, error):
            self._flush_turn(error, initial=initial)

        # session/prompt blocks for the whole turn — async so the command
        # loop stays responsive (interrupt/end must get through).
        self.child.request_async("session/prompt", {
            "sessionId": self.session_id,
            "prompt": [{"type": "text", "text": text}],
        }, _cb)

    def _flush_turn(self, error, initial=False):
        """Prompt finished (or failed): emit the accumulated blocks. v1 has
        no deltas, so chunks are held until the result arrives."""
        thought = "".join(self._thought_buf)
        text = "".join(self._text_buf)
        self._thought_buf = []
        self._text_buf = []
        self.ev_thinking(thought)
        self.ev_text("assistant", text)
        if error:
            if initial:
                # A dead FIRST turn = a session that never produced
                # anything; idle would just look stalled. Die loudly.
                self.fatal("grok session/prompt failed: %s" % error)
                return
            log("session/prompt failed:", error)
        with self._turn_lock:
            self._turn_active = False
            queued = self._queued_turns.pop(0) if self._queued_turns else None
        self.ev_state("idle")
        if queued is not None:
            self._start_turn(queued)

    def _on_notification(self, msg):
        if (msg.get("method") or "") != "session/update":
            return
        update = (msg.get("params") or {}).get("update") or {}
        kind = update.get("sessionUpdate")
        if kind == "agent_message_chunk":
            content = update.get("content") or {}
            self._text_buf.append(content.get("text") or "")
        elif kind == "agent_thought_chunk":
            content = update.get("content") or {}
            self._thought_buf.append(content.get("text") or "")
        elif kind == "tool_call":
            title = update.get("title") or update.get("kind") or "tool"
            tc_id = update.get("toolCallId")
            if tc_id:
                self._tool_titles[tc_id] = title
            self.ev_tool(_trunc(title, 80), title)
        elif kind == "tool_call_update":
            status = update.get("status")
            if status in ("completed", "failed"):
                title = self._tool_titles.get(update.get("toolCallId"),
                                              "tool")
                self.ev_tool_result(_trunc(title, 80),
                                    status == "completed", title)
        # "plan" and unknown update kinds: ignored (forward compat)

    def _on_request(self, msg):
        method = msg.get("method") or ""
        rpc_id = msg.get("id")
        if method == "session/request_permission":
            # Auto-grant (planning runs yolo). ACP outcome shape:
            # {"outcome": {"outcome": "selected", "optionId": ...}}.
            # UNVERIFIED: grok's exact option kinds — we prefer the
            # broadest allow option and fall back to the first.
            params = msg.get("params") or {}
            options = [o for o in (params.get("options") or [])
                       if isinstance(o, dict)]
            chosen = None
            for kind in ("allow_always", "allow_once"):
                for o in options:
                    if o.get("kind") == kind:
                        chosen = o.get("optionId")
                        break
                if chosen:
                    break
            if chosen is None and options:
                chosen = options[0].get("optionId")
            self.child.respond(rpc_id, {
                "outcome": {"outcome": "selected", "optionId": chosen}})
        else:
            log("unsupported grok server request:", method)
            self.child.respond(rpc_id, error={
                "code": -32601, "message": "unsupported by plan driver"})

    # host commands (no structured questions for grok)
    def on_user(self, text):
        self._start_turn(text)

    def on_interrupt(self):
        # ACP cancellation is the session/cancel notification.
        # UNVERIFIED: grok's handling — worst case the turn runs out.
        self.child.notify("session/cancel", {"sessionId": self.session_id})

    def on_end(self):
        self.finish(ok=True)

    def _on_exit(self, rc):
        if not self.done.is_set():
            self.fatal("grok agent exited unexpectedly (rc=%s)" % rc)


# ─────────────────────────── claude bridge ──────────────────────────────────
class ClaudeBridge(Driver):
    """Bridges claude-plan-driver.mjs (Claude Agent SDK, node) to the vsock
    link. The node driver speaks the SAME v1 vocabulary over its stdio —
    events out, commands in — with no hello, so the bridge is a pass-
    through: one protocol, two hops.
    """

    def __init__(self, link, branch, cwd, prompt_b64):
        Driver.__init__(self, link, branch, cwd, prompt_b64)
        self.prompt_b64 = prompt_b64
        self.proc = None
        self._stdin_lock = threading.Lock()

    def _mcp_config_path(self):
        """The claude MCP config agentd writes before spawning us (same
        path scheme as _task_mcp_setup's claude branch). Written here as a
        fallback so the driver also works when launched by hand."""
        path = os.path.join(HOME, ".bromure",
                            "task-mcp-%s.json" % self.branch.replace("/",
                                                                     "-"))
        if os.path.exists(path):
            return path
        if not os.path.exists(TASK_MCP_SHIM):
            return None
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                json.dump({"mcpServers": {"bromure-board": {
                    "command": "python3",
                    "args": [TASK_MCP_SHIM, self.branch]}}}, f, indent=2)
            return path
        except OSError as e:
            log("mcp config write failed:", e)
            return None

    def run(self):
        # Copy the staged .mjs next to ~/.bromure/plan-driver/node_modules
        # so its bare `import "@anthropic-ai/claude-agent-sdk"` resolves
        # (ESM resolution walks up from the SCRIPT's directory; NODE_PATH
        # is ignored for ES modules).
        try:
            os.makedirs(PLAN_DRIVER_HOME, exist_ok=True)
            script = os.path.join(PLAN_DRIVER_HOME, "claude-plan-driver.mjs")
            shutil.copy(CLAUDE_DRIVER_SRC, script)
        except OSError as e:
            self.fatal("claude driver staging failed: %s" % e)
            return
        cfg = self._mcp_config_path() or "-"
        self.ev_state("starting")
        try:
            self.proc = subprocess.Popen(
                ["node", script, self.branch, self.cwd, self.prompt_b64,
                 cfg],
                cwd=self.cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True, bufsize=1)
        except OSError as e:
            self.fatal("node spawn failed: %s" % e)
            return
        threading.Thread(target=self._drain_stderr, daemon=True).start()
        try:
            for line in self.proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except ValueError:
                    log("non-JSON node stdout ignored:", _trunc(line, 120))
                    continue
                if not isinstance(ev, dict) or "ev" not in ev:
                    continue
                self.link.send(ev)
                if ev.get("ev") == "result":
                    self.done.set()
                elif ev.get("ev") == "fatal":
                    self.exit_code = 1
                    self.done.set()
        except (OSError, ValueError):
            pass
        rc = self.proc.wait()
        if not self.done.is_set():
            self.fatal("claude plan driver exited unexpectedly (rc=%s)" % rc)

    def _drain_stderr(self):
        try:
            for line in self.proc.stderr:
                line = line.rstrip()
                if line:
                    log("node:", _trunc(line, 400))
        except (OSError, ValueError):
            pass

    def handle_cmd(self, cmd):
        """Forward every host command verbatim to the node driver — same
        vocabulary on both hops, so no translation."""
        if self.done.is_set():
            return
        if self.proc is None or self.proc.poll() is not None:
            return
        try:
            with self._stdin_lock:
                self.proc.stdin.write(
                    json.dumps(cmd, separators=(",", ":")) + "\n")
                self.proc.stdin.flush()
        except (OSError, ValueError):
            log("command forward to node failed")


# ─────────────────────────── main ───────────────────────────────────────────
def main():
    if len(sys.argv) != 5:
        sys.stderr.write(
            "usage: bromure-plan-driver.py <tool> <branch> <cwd> "
            "<prompt-b64>\n")
        return 2
    tool, branch, cwd, prompt_b64 = sys.argv[1:5]
    link = VsockLink(branch, tool)
    if tool == "codex":
        driver = CodexDriver(link, branch, cwd, _b64d(prompt_b64))
    elif tool == "grok":
        driver = GrokDriver(link, branch, cwd, _b64d(prompt_b64))
    elif tool == "claude":
        driver = ClaudeBridge(link, branch, cwd, prompt_b64)
    else:
        sys.stderr.write("unknown tool: %s\n" % tool)
        return 2
    threading.Thread(target=link.recv_loop, args=(driver.handle_cmd,),
                     daemon=True).start()
    try:
        driver.run()
    except Exception:
        driver.fatal("driver crashed:\n" + traceback.format_exc())
    # Give the terminal event a moment to flush before tearing the link down.
    time.sleep(0.2)
    link.close()
    return driver.exit_code


if __name__ == "__main__":
    sys.exit(main())
