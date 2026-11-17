import Foundation

// MARK: - Hermes Agent: status hook + transcript mirror (guest side)

extension Profile {
    /// Guest path of the Hermes hook script (`hermesHookScript`).
    static let hermesHookGuestPath = "/home/ubuntu/.bromure/hermes-hook.py"

    /// The Hermes events the hook is registered for (`hooks.<event>` in
    /// ~/.hermes/config.yaml, approved in shell-hooks-allowlist.json by the
    /// bashrc's `_bromure_hermes_apply`).
    static let hermesHookEvents = [
        "on_session_open", "on_session_start", "pre_llm_call", "post_llm_call",
        "pre_tool_call", "post_tool_call", "pre_approval_request", "post_approval_response",
        "on_human_input_request", "on_human_input_resolved", "on_session_end",
        "on_session_finalize",
    ]

    /// Hermes's shell hook for every event in `hermesHookEvents`
    /// (`hermes-hook.py`, staged in ~/.bromure like agent-status.sh).
    ///
    /// Hermes runs every turn of an interactive `hermes chat` in ONE shared
    /// background gateway per Hermes home, not in the tab's process. A hook
    /// therefore runs as a child of that gateway: its environment (TMUX_PANE)
    /// is whichever tab started the gateway, and its `cwd` is the install
    /// root. The tab is found from the session instead: Hermes records each
    /// CLI's session in `$HERMES_HOME/runtime/active_sessions.json` with the
    /// CLI's pid, whose environment names its pane. With no record for the
    /// session (a fresh chat claims its slot once it has an id), the one
    /// Hermes CLI with a pane, if there's exactly one, is the tab.
    ///
    /// Two jobs:
    ///   1. Status: the event, as the signal agent-status.sh takes (working,
    ///      done, needsInput, start), with a Claude-hook-shaped JSON on stdin
    ///      (session id, transcript path, and for a tool call the call itself
    ///      for the tool-call lineage). The agent pid is the gateway's (the
    ///      hook's parent): the tools' processes are its children.
    ///   2. Transcript: Hermes keeps its conversations in SQLite
    ///      (`state.db`), which the chat view can't read in chunks. The hook
    ///      appends the session's new messages, in Claude Code's JSONL shape,
    ///      to `~/.hermes/bromure-transcripts/<cwd, non-alphanumerics as
    ///      '-'>/<session>.jsonl` — append-only, so the view's byte offsets
    ///      stay valid. The last message id copied is kept beside it
    ///      (`<session>.jsonl.pos`, under an flock: two hooks of one session
    ///      can run at once).
    ///
    /// Always prints `{}` and exits 0: a status reporter must never block or
    /// rewrite a tool call, nor stall a turn.
    static let hermesHookScript = #"""
    #!/usr/bin/python3 -I
    # Bromure Agentic Coding — Hermes status hook + transcript mirror (managed; do not edit).
    import datetime, fcntl, json, os, pwd, re, sqlite3, subprocess, sys

    HOME = pwd.getpwuid(os.getuid()).pw_dir
    STATUS = os.path.join(HOME, ".bromure", "agent-status.sh")
    MIRROR = os.path.join(HOME, ".hermes", "bromure-transcripts")
    SIGNAL = {
        "on_session_open": "start", "on_session_start": "start",
        "pre_llm_call": "working", "pre_tool_call": "working",
        "post_approval_response": "working", "on_human_input_resolved": "working",
        "pre_approval_request": "needsInput", "on_human_input_request": "needsInput",
        "on_session_end": "done", "on_session_finalize": "done",
    }
    SKIPPED_KINDS = {"hidden", "internal_notification", "auto_continue"}
    MAX_TEXT = 200000
    SID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")


    def hermes_home():
        h = os.environ.get("HERMES_HOME") or ""
        return h if os.path.isabs(h) else os.path.join(HOME, ".hermes")


    def environ_of(pid):
        try:
            with open("/proc/%d/environ" % pid, "rb") as f:
                raw = f.read()
        except (OSError, ValueError):
            return {}
        env = {}
        for kv in raw.split(b"\0"):
            k, sep, v = kv.partition(b"=")
            if sep:
                env[k.decode(errors="replace")] = v.decode(errors="replace")
        return env


    def pane_of(pid):
        env = environ_of(pid)
        if env.get("TMUX_PANE") and env.get("TMUX"):
            return {"pid": pid, "TMUX": env["TMUX"], "TMUX_PANE": env["TMUX_PANE"]}
        return None


    def find_tab(home, sid):
        """(tab, leased): the CLI (pid + pane) whose chat is `sid` and whether
        Hermes's own lease named it; (None, False) when there's no telling."""
        try:
            with open(os.path.join(home, "runtime", "active_sessions.json")) as f:
                entries = json.load(f).get("entries") or []
        except (OSError, ValueError, AttributeError):
            entries = []
        if sid:
            for e in entries:
                if not isinstance(e, dict):
                    continue
                meta = e.get("metadata") if isinstance(e.get("metadata"), dict) else {}
                if sid in (str(e.get("session_id") or ""), str(meta.get("live_session_id") or "")):
                    try:
                        tab = pane_of(int(e.get("pid")))
                    except (TypeError, ValueError):
                        tab = None
                    if tab:
                        return tab, True
        # No record: the one Hermes CLI with a pane, if only one.
        found, me = {}, os.getpid()
        try:
            pids = os.listdir("/proc")
        except OSError:
            pids = []
        for d in pids:
            if not d.isdigit() or int(d) in (me, os.getppid()):
                continue
            try:
                with open("/proc/%s/cmdline" % d, "rb") as f:
                    argv = f.read().split(b"\0")
                with open("/proc/%s/comm" % d, "rb") as f:
                    comm = f.read().decode(errors="replace").strip()
            except OSError:
                continue
            words = [w.decode(errors="replace") for w in argv if w]
            if not comm.startswith("python") and comm != "hermes":
                continue
            # The launcher: a script (`python -I …/bin/hermes chat`) or inline
            # code (`python -I -c "…import hermes_bootstrap…" chat`).
            launcher = any(os.path.basename(w) == "hermes" for w in words[:3]) \
                or ("-c" in words[:3] and any("hermes_bootstrap" in w for w in words[:4]))
            if not launcher or "gateway" in words or any("hermes-hook" in w for w in words):
                continue
            tab = pane_of(int(d))
            if tab:
                found[tab["TMUX_PANE"]] = tab
        return (next(iter(found.values())) if len(found) == 1 else None), False


    def stamp(ts):
        try:
            return datetime.datetime.fromtimestamp(float(ts), datetime.timezone.utc) \
                .strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
        except (TypeError, ValueError, OverflowError, OSError):
            return None


    def text_of(content):
        if content is None:
            return ""
        if isinstance(content, str) and content.startswith("\x00json:"):
            try:
                content = json.loads(content[6:])
            except ValueError:
                return content[6:]
        if isinstance(content, str):
            return content
        parts = content if isinstance(content, list) else [content]
        out = []
        for p in parts:
            if isinstance(p, str):
                out.append(p)
            elif isinstance(p, dict):
                kind = p.get("type")
                if kind in ("text", "input_text", "output_text") and isinstance(p.get("text"), str):
                    out.append(p["text"])
                elif kind in ("image_url", "image", "input_image"):
                    out.append("[image]")
        return "\n".join(t for t in out if t)


    def cap(s):
        return s if len(s) <= MAX_TEXT else s[:MAX_TEXT] + "\n… (truncated)"


    def tool_uses(raw):
        try:
            calls = json.loads(raw) if isinstance(raw, str) else (raw or [])
        except ValueError:
            return []
        out = []
        for c in calls if isinstance(calls, list) else []:
            if not isinstance(c, dict):
                continue
            fn = c.get("function") if isinstance(c.get("function"), dict) else c
            args = fn.get("arguments", fn.get("input", {}))
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except ValueError:
                    args = {"arguments": args}
            if not isinstance(args, dict):
                args = {"arguments": args}
            out.append({"type": "tool_use", "id": str(c.get("id") or c.get("call_id") or ""),
                        "name": str(fn.get("name") or "tool"), "input": args})
        return out


    def convert(m, sid, cwd):
        """One stored message as Claude Code JSONL lines (none to skip it)."""
        if (m.get("display_kind") or "") in SKIPPED_KINDS:
            return []
        role = m.get("role")
        base = {"timestamp": stamp(m.get("timestamp")), "sessionId": sid, "cwd": cwd,
                "uuid": "hermes-%s-%s" % (sid, m.get("id"))}
        text = cap(text_of(m.get("content")).strip())
        if role == "user":
            return [dict(base, type="user", message={"role": "user", "content": text})] if text else []
        if role == "assistant":
            blocks = []
            thought = text_of(m.get("reasoning_content") or m.get("reasoning")).strip()
            if thought:
                blocks.append({"type": "thinking", "thinking": cap(thought)})
            if text:
                blocks.append({"type": "text", "text": text})
            blocks += tool_uses(m.get("tool_calls"))
            return [dict(base, type="assistant", message={"role": "assistant", "content": blocks})] if blocks else []
        if role == "tool":
            return [dict(base, type="user", message={"role": "user", "content": [{
                "type": "tool_result", "tool_use_id": str(m.get("tool_call_id") or ""),
                "content": text}]})]
        return []


    def transcript_path(cwd, sid):
        return os.path.join(MIRROR, re.sub(r"[^A-Za-z0-9]", "-", cwd), sid + ".jsonl")


    def open_db(home):
        db = os.path.join(home, "state.db")
        if not os.path.exists(db):
            return None
        return sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=3)


    def session_row(con, sid):
        """(cwd, parent session id) of a stored session; ("", "") when unknown."""
        cols = {r[1] for r in con.execute("PRAGMA table_info(sessions)")}
        pick = [c for c in ("cwd", "parent_session_id") if c in cols]
        if not pick:
            return "", ""
        row = con.execute("SELECT %s FROM sessions WHERE id = ?" % ", ".join(pick), (sid,)).fetchone()
        got = dict(zip(pick, row)) if row else {}
        return str(got.get("cwd") or ""), str(got.get("parent_session_id") or "")


    def mirror(con, sid, cwd, tab):
        """Append the session's new messages; returns the transcript's path."""
        if not cwd and tab:
            try:
                cwd = os.readlink("/proc/%d/cwd" % tab["pid"])
            except OSError:
                cwd = ""
        if not cwd.startswith("/"):
            return None
        path = transcript_path(cwd, sid)
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        cols = {r[1] for r in con.execute("PRAGMA table_info(messages)")}
        want = [c for c in ("id", "role", "content", "tool_call_id", "tool_calls", "timestamp",
                            "reasoning", "reasoning_content", "display_kind") if c in cols]
        if "id" not in want or "role" not in want:
            return path
        fd = os.open(path + ".pos", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "r+") as pos:
            fcntl.flock(pos, fcntl.LOCK_EX)
            pos.seek(0)
            try:
                last = int(pos.read().strip() or 0)
            except ValueError:
                last = 0
            rows = con.execute(
                "SELECT %s FROM messages WHERE session_id = ? AND id > ? ORDER BY id LIMIT 5000"
                % ", ".join(want), (sid, last)).fetchall()
            lines = []
            for r in rows:
                m = dict(zip(want, r))
                last = max(last, int(m["id"]))
                lines += convert(m, sid, cwd)
            if lines:
                out = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
                with os.fdopen(out, "a", encoding="utf-8") as f:
                    f.write("".join(json.dumps(l, ensure_ascii=False) + "\n" for l in lines))
            if rows:
                pos.seek(0)
                pos.truncate()
                pos.write(str(last))
        return path


    def report(signal, tab, payload):
        env = {"PATH": os.environ.get("PATH") or "/usr/local/bin:/usr/bin:/bin", "HOME": HOME,
               "TMUX": tab["TMUX"], "TMUX_PANE": tab["TMUX_PANE"],
               # The tool-call lineage's agent: the gateway running the tools.
               "BROMURE_HOOK_AGENT_PID": str(os.getppid())}
        subprocess.run(["sh", STATUS, signal, tab["TMUX_PANE"]], input=json.dumps(payload).encode(),
                       env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)


    def main():
        try:
            event = json.loads(sys.stdin.read() or "{}")
        except ValueError:
            return
        if not isinstance(event, dict):
            return
        name = str(event.get("hook_event_name") or "")
        extra = event.get("extra") if isinstance(event.get("extra"), dict) else {}
        sid = str(event.get("session_id") or extra.get("session_id") or "")
        if not SID_RE.match(sid):
            return
        home = hermes_home()
        tab, leased = find_tab(home, sid)
        con = open_db(home)
        path = None
        try:
            cwd, parent = session_row(con, sid) if con else ("", "")
            # A session with a parent that no CLI claims is a subagent's (a
            # delegated task, run inside the parent's turn): its turn end is
            # not the tab's, and its messages aren't the tab's chat.
            if parent and not leased:
                return
            if con:
                path = mirror(con, sid, cwd, tab)
        except Exception:
            path = None
        finally:
            if con:
                con.close()
        signal = SIGNAL.get(name)
        if not signal or not tab:
            return
        payload = {"hook_event_name": "Hermes:" + name, "session_id": sid}
        if path:
            payload["transcript_path"] = path
        if name == "pre_tool_call":
            payload.update({"hook_event_name": "PreToolUse",
                            "tool_name": event.get("tool_name") or "",
                            "tool_input": event.get("tool_input") or {},
                            "tool_use_id": str(extra.get("tool_call_id") or "")})
        report(signal, tab, payload)


    try:
        main()
    except Exception:
        pass
    print("{}")
    """#
}
