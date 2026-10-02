#!/usr/bin/env bash
# The two-incarnation boot: does agentd actually come up?
#
# This test exists because a strict workspace shipped that never opened its shell
# connection to the host. The symptom is indistinguishable from a dead guest --
# "No shell connection", no journal (strict masks getty), and no exec path to
# debug through -- and every other suite here passed, because every other suite
# drives the supervisor or the sandbox directly and none of them boots agentd.
#
# So this one runs the REAL `bromure-agentd.py` main(), in the REAL
# post-revocation state (strict applied, sudo gone), against a fake host on
# vsock, and asks the only question that matters: within N seconds, has the host
# got its control channel and does a session exist?
#
# It runs for each of the four configurations, because they take different paths
# through `create_session`:
#   sentry-only    no Landlock, no seccomp
#   landlock-only  Landlock, no process layer
#   strict         everything, run_as the workspace user
#   strict + run_as a DIFFERENT user, on a real virtiofs workdir
#
# The last one is here because it shipped broken and none of the others could have
# caught it. `run_as_user: sandbox` produced a workspace that reported itself
# fully enforced and had no session, and answered every host command with exit 127
# and no output. Four separate causes, each invisible to the others:
#
#   * `ctl.sock` was chowned to the WORKLOAD's group, so agentd -- the only
#     legitimate client -- got EACCES from `connect`, which `_ws_run` turned into
#     a bare 127;
#   * tmux refuses any client whose uid is not the server's, whatever the socket
#     permits, and `has-session` prints that and exits 0, so agentd's probe read
#     as success;
#   * the `sandbox` account had no home, so HOME pointed at the project folder;
#   * and the account's shell was `nologin`, so every pane exited at once.
#
# The third case uses `run_as_user: "1000"` -- the workspace user's own uid -- so
# it exercised the policy plumbing and none of the above.
#
# Run: tests/test_boot.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
WORK=$(mktemp -d /tmp/boottest-XXXXXX)
# 0755, not mktemp's 0700: the real run directory lives under /run, which every
# uid can traverse, and a `run_as_user` that is not the workspace user cannot
# reach a socket inside a 0700 parent. Without this the fourth case failed with
# "tmux server socket did not appear within 10s" three directories away from the
# cause -- which is also why the supervisor now says WHICH component it could not
# traverse.
chmod 0755 "$WORK"
AGENTD="$ROOT/patched/bromure-agentd.py"
SHELL_PORT=5800
DEADLINE=${DEADLINE:-45}
IDLE_SECONDS=${IDLE_SECONDS:-60}
SUPERVISOR=""
AGENTD_PID=""
FAKE_HOST=""
fails=0
matched_cases=0
skipped_cases=0

say() { printf '\n=== %s ===\n' "$1"; }
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

# This suite boots the real sandboxd, which grants ICMP echo sockets to the
# workload's gid -- correct in production, and a change to the machine that a
# test has no business leaving behind. Measured: a full run left the range at a
# run_as_user workspace's system gid, so some unrelated system group kept ping
# sockets until the next reboot.
PING_RANGE=/proc/sys/net/ipv4/ping_group_range
PING_SAVED=$(cat "$PING_RANGE" 2>/dev/null || echo "1	0")

cleanup() {
    for m in "$WORK/etc/sudoers.d" "$WORK/etc/group" "$WORK/etc/gshadow"; do
        mountpoint -q "$m" 2>/dev/null && sudo umount "$m" 2>/dev/null
    done
    [ -n "$AGENTD_PID" ] && kill -9 "$AGENTD_PID" 2>/dev/null
    [ -n "$FAKE_HOST" ] && kill -9 "$FAKE_HOST" 2>/dev/null
    for pid in $(pgrep -f "python3 $ROOT/bromure-sandboxd" 2>/dev/null); do
        sudo kill "$pid" 2>/dev/null
    done
    sudo pkill -f "python3 .*bromure-attestd.py" 2>/dev/null
    sudo tmux -S "$WORK/run/server/tmux.sock" kill-server 2>/dev/null
    # LAST, after every daemon above is dead. This suite starts sandboxd as a
    # systemd TRANSIENT UNIT, which outlives this script's own process -- so a
    # restore at the top of cleanup races a sandboxd that is still running and
    # about to grant the range again. Measured: a full suite run ended at
    # `1000 1000` with the restore first, and the journal showed the transient
    # unit being stopped a moment later. Stop the writer, then restore the
    # state.
    sudo systemctl stop bromure-sandboxd 2>/dev/null
    sudo sh -c "printf '%s' '$PING_SAVED' > $PING_RANGE" 2>/dev/null
    sudo rm -rf "$WORK"
}
trap cleanup EXIT

sudo modprobe vsock_loopback 2>/dev/null
sudo systemctl stop bromure-sandboxd bromure-attestd 2>/dev/null
sudo systemctl reset-failed bromure-sandboxd bromure-attestd 2>/dev/null

# A stand-in for the host's shell-agent listener. agentd is pointed at
# VMADDR_CID_LOCAL, so this is the same code path it takes to reach CID 2.
# A stand-in for the host's shell-agent listener that speaks the REAL protocol.
#
# The first version only accepted connections, which proved the guest could reach
# the host and nothing else. That gap is why `run_as_user: sandbox` shipped twice:
# `vm exec` does not call `_ws_run` from the test's own process, it arrives over
# vsock 5800 as a length-prefixed JSON request, and every assertion in this file
# bypassed that path entirely.
#
#   guest -> host: opens a pooled connection and waits
#   host  -> guest: [u32be len][{"cmd" | "argv", "workdir", "timeout"}]
#   guest -> host: [u32be len][{"stdout", "stderr", "exit_code"}]
#
# An interactive request switches the connection to the framed pty protocol:
#   [1 byte type][u32be len][payload], type 0 data, 1 resize, 2 exit, 3 stdin EOF
#
# The test drives it through a unix socket: one line of JSON in, one line out.
cat > "$WORK/fake_host.py" <<'PY'
import json, os, queue, socket, struct, sys, threading

VMADDR_CID_ANY = 0xFFFFFFFF
FRAME_DATA, FRAME_RESIZE, FRAME_EXIT, FRAME_EOF = 0, 1, 2, 3

port = int(sys.argv[1])
marker = sys.argv[2]
ctl_path = sys.argv[3]
attest_log = sys.argv[4] if len(sys.argv) > 4 else None
sentry_log = sys.argv[5] if len(sys.argv) > 5 else None
pool = queue.Queue()
accepted = 0
ATTEST_PORT = 5840
SENTRY_PORT = 5841


def recv_exact(sock, count):
    buf = b""
    while len(buf) < count:
        chunk = sock.recv(count - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def acceptor():
    global accepted
    listener = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((VMADDR_CID_ANY, port))
    listener.listen(32)
    while True:
        try:
            conn, _ = listener.accept()
        except OSError:
            return
        accepted += 1
        with open(marker, "w") as handle:
            handle.write(str(accepted))
        pool.put(conn)


def send_request(conn, request):
    body = json.dumps(request).encode()
    conn.sendall(struct.pack(">I", len(body)) + body)


def read_response(conn, timeout):
    conn.settimeout(timeout)
    header = recv_exact(conn, 4)
    if not header:
        return None
    (length,) = struct.unpack(">I", header)
    body = recv_exact(conn, length)
    if not body:
        return None
    return json.loads(body.decode("utf-8", "replace"))


def take(timeout=60.0):
    return pool.get(timeout=timeout)


def do_exec(request, timeout):
    """One non-interactive exec, retrying across pooled connections.

    A pooled connection may already have been closed by the guest, so a dead one
    is discarded rather than reported as a failed command.
    """
    last = "no usable connection"
    for _ in range(4):
        try:
            conn = take(timeout)
        except queue.Empty:
            return {"error": "the guest opened no connection within %.0fs" % timeout}
        try:
            send_request(conn, request)
            reply = read_response(conn, timeout)
            if reply is not None:
                return reply
            last = "the guest closed the connection without replying"
        except OSError as exc:
            last = str(exc)
        finally:
            try:
                conn.close()
            except OSError:
                pass
    return {"error": last}


def do_attach(request, send_text, expect, timeout):
    """An interactive pty session: send keystrokes, collect output, report."""
    try:
        conn = take(timeout)
    except queue.Empty:
        return {"error": "the guest opened no connection within %.0fs" % timeout}
    try:
        send_request(conn, dict(request, interactive=True, cols=80, rows=24))
        if send_text:
            payload = send_text.encode()
            conn.sendall(bytes([FRAME_DATA]) + struct.pack(">I", len(payload))
                         + payload)
        conn.settimeout(timeout)
        collected, exit_code = b"", None
        deadline = __import__("time").time() + timeout
        while __import__("time").time() < deadline:
            try:
                head = recv_exact(conn, 5)
            except socket.timeout:
                break
            if not head:
                break
            kind = head[0]
            (length,) = struct.unpack(">I", head[1:])
            body = recv_exact(conn, length) if length else b""
            if body is None:
                break
            if kind == FRAME_DATA:
                collected += body
                if expect and expect.encode() in collected:
                    break
            elif kind == FRAME_EXIT:
                exit_code = struct.unpack(">i", body)[0] if len(body) == 4 else None
                break
        return {"output": collected.decode("utf-8", "replace"),
                "exit_code": exit_code}
    except OSError as exc:
        return {"error": str(exc)}
    finally:
        try:
            conn.close()
        except OSError:
            pass


def control():
    try:
        os.unlink(ctl_path)
    except OSError:
        pass
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(ctl_path)
    os.chmod(ctl_path, 0o666)
    listener.listen(8)
    while True:
        conn, _ = listener.accept()
        threading.Thread(target=serve_control, args=(conn,), daemon=True).start()


def serve_control(conn):
    try:
        conn.settimeout(300)
        data = b""
        while b"\n" not in data:
            chunk = conn.recv(65536)
            if not chunk:
                return
            data += chunk
        ask = json.loads(data.decode().strip())
        timeout = float(ask.get("timeout", 60))
        if ask.get("op") == "attach":
            reply = do_attach(ask.get("request") or {}, ask.get("send"),
                              ask.get("expect"), timeout)
        elif ask.get("op") == "pool":
            reply = {"accepted": accepted, "idle": pool.qsize()}
        else:
            request = {"timeout": int(timeout)}
            if ask.get("argv"):
                request["argv"] = ask["argv"]
            if ask.get("cmd"):
                request["cmd"] = ask["cmd"]
            if ask.get("workdir"):
                request["workdir"] = ask["workdir"]
            reply = do_exec(request, timeout)
        conn.sendall((json.dumps(reply) + "\n").encode())
    except Exception as exc:  # the test must see a reason, not a hang
        try:
            conn.sendall((json.dumps({"error": "fake host: %s" % exc}) + "\n").encode())
        except OSError:
            pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def sentry_listener():
    """The host's side of vsock 5841, so a booted workspace's sentry can be read.

    Length-prefixed JSON, unlike 5840's newline-delimited frames. The point of
    having it here is the idle assertion: a workspace doing nothing must produce
    no `sandbox_denied`, and that can only be shown by watching a REAL boot with
    the sentry loaded. Bromure's own status loops used to fill that stream.
    """
    if not sentry_log:
        return
    listener = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        listener.bind((VMADDR_CID_ANY, SENTRY_PORT))
    except OSError as exc:
        with open(sentry_log, "a") as handle:
            handle.write(json.dumps({"bind_failed": str(exc)}) + "\n")
        return
    listener.listen(8)
    while True:
        try:
            conn, _ = listener.accept()
        except OSError:
            return
        threading.Thread(target=read_sentry, args=(conn,), daemon=True).start()


def read_sentry(conn):
    buf = b""
    try:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
            while len(buf) >= 4:
                (length,) = struct.unpack(">I", buf[:4])
                if length == 0 or length > (1 << 20) or len(buf) < 4 + length:
                    break
                body, buf = buf[4:4 + length], buf[4 + length:]
                with open(sentry_log, "a") as handle:
                    handle.write(body.decode("utf-8", "replace") + "\n")
                    handle.flush()
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def attestor():
    """The host's side of vsock 5840, so a boot can be asked the one question
    that matters most: did the attestor ever connect?

    It went unasked for sixteen rounds because attestd hardcoded CID 2, which
    nothing in a guest can bind -- so every boot test ran with no attestor and
    could not tell. Without the attestor the host fails closed on every
    binary-scoped network rule, which is a workspace where `curl` simply does
    not work and nothing says why.
    """
    if not attest_log:
        return
    listener = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        listener.bind((VMADDR_CID_ANY, ATTEST_PORT))
    except OSError as exc:
        with open(attest_log, "a") as handle:
            handle.write(json.dumps({"bind_failed": str(exc)}) + "\n")
        return
    listener.listen(8)
    while True:
        try:
            conn, _ = listener.accept()
        except OSError:
            return
        threading.Thread(target=read_attestor, args=(conn,), daemon=True).start()


def read_attestor(conn):
    with open(attest_log, "a") as handle:
        handle.write(json.dumps({"connected": time.time()}) + "\n")
        handle.flush()
    buf = b""
    try:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                with open(attest_log, "a") as handle:
                    handle.write(line.decode("utf-8", "replace") + "\n")
                    handle.flush()
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


import time  # noqa: E402 -- used by the attestor log above

threading.Thread(target=acceptor, daemon=True).start()
threading.Thread(target=attestor, daemon=True).start()
threading.Thread(target=sentry_listener, daemon=True).start()
control()
PY

# Is there a session? Asked as the SERVER's uid, and by reading the output.
# `has-session` exits 0 even when the server refuses the client, so the exit
# status alone reports a session that is not there.
session_present() {
    local runas="${1:-}" out sock="$WORK/run/server/tmux.sock"
    if [ -n "$runas" ]; then
        out=$(sudo -u "#$runas" env HOME=/home/sandbox \
                tmux -S "$sock" has-session -t bromure 2>&1)
    else
        out=$(tmux -S "$sock" has-session -t bromure 2>&1)
    fi
    [ -z "$out" ]
}

# The supervisor's reason for refusing one exec. This is the legibility the
# `run_as_user` round asked for: a command that cannot run must answer with the
# operation, the path and the errno, not a bare 127.
exec_reason() {
    python3 - "$1" <<'PY'
import json, os, socket, sys
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.settimeout(30)
try:
    c.connect(os.environ["CTL"])
except OSError as exc:
    print("connect:%s" % exc); sys.exit(0)
r, w = os.pipe()
dn = os.open(os.devnull, os.O_RDONLY)
socket.send_fds(c, [json.dumps({"op": "exec", "argv": json.loads(sys.argv[1]),
                                "cwd": os.environ.get("PROBE_CWD") or None,
                                "env": {}, "pty": False}).encode()], [dn, w, w])
os.close(w); os.close(dn)
data = b""
while b"\n" not in data:
    chunk = c.recv(65536)
    if not chunk:
        break
    data += chunk
print((json.loads(data.decode() or "{}") or {}).get("reason") or "")
PY
}

# Run a shell command inside the sandbox, exactly as a pane runs one: through the
# supervisor's `exec` op, so it is confined by the same `confine_self` the tmux
# server went through. Prints the command's output; exits non-zero if the
# supervisor refused it.
sandbox_sh() {
    python3 - "$1" <<'PY'
import json, os, socket, sys
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.settimeout(60)
try:
    c.connect(os.environ["CTL"])
except OSError as exc:
    sys.stderr.write("connect: %s\n" % exc); sys.exit(2)
r, w = os.pipe()
dn = os.open(os.devnull, os.O_RDONLY)
socket.send_fds(c, [json.dumps({"op": "exec", "argv": ["/bin/sh", "-c", sys.argv[1]],
                                "cwd": None, "env": {}, "pty": False}).encode()],
                [dn, w, w])
os.close(w); os.close(dn)
data = b""
while b"\n" not in data:
    chunk = c.recv(65536)
    if not chunk:
        break
    data += chunk
out = b""
while True:
    piece = os.read(r, 65536)
    if not piece:
        break
    out += piece
sys.stdout.write(out.decode("utf-8", "replace"))
reply = json.loads(data.decode() or "{}")
if not reply.get("ok"):
    sys.stderr.write("refused: %s\n" % reply.get("reason"))
    sys.exit(2)
sys.exit(int(reply.get("exit", 1)))
PY
}

exec_reason_cwd() {
    sudo mkdir -p "$1"; sudo chmod 0700 "$1"; sudo chown root:root "$1"
    PROBE_CWD="$1" exec_reason '["/usr/bin/id"]'
}

# `vm exec`, over vsock, exactly as the host does it. Prints the guest's reply as
# JSON. This is the path every earlier version of this test skipped.
host_exec() {
    # host_exec <json-request-fields...>  e.g. host_exec '"argv":["/bin/echo","hi"]'
    python3 - "$1" <<'PY'
import json, os, socket, sys
body = "{" + sys.argv[1] + "}"
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
c.settimeout(180)
try:
    c.connect(os.environ["HOSTCTL"])
except OSError as exc:
    print(json.dumps({"error": "fake host control: %s" % exc})); sys.exit(0)
c.sendall((body + "\n").encode())
data = b""
while b"\n" not in data:
    chunk = c.recv(65536)
    if not chunk:
        break
    data += chunk
sys.stdout.write(data.decode("utf-8", "replace").strip() or '{"error":"no reply"}')
PY
}

# One field out of the guest's reply.
host_exec_field() {
    host_exec "$1" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read() or '{}')
except ValueError:
    d = {}
print(d.get('$2', ''))"
}

run_case() {
    # run_case <name> <spec-json> <expect-session: yes|no> [run-as-uid]
    # ONLY=<substring> runs just the matching cases. Each case is a two-minute
    # real boot, so iterating on one of them without this means waiting on three
    # that already pass.
    local name="$1" spec="$2" expect="$3" runas="${4:-}"
    if [ -n "${ONLY:-}" ] && [ "${name#*$ONLY}" = "$name" ]; then
        printf '\n=== %s ===\n  SKIP (ONLY=%s)\n' "$name" "$ONLY"
        return 0
    fi
    # Counted, because ONLY is a plain substring match -- no regex, no
    # alternation -- and a pattern that matches nothing skipped every case and
    # exited 0, which reads exactly like a pass. A filter that can silently run
    # no tests is a filter that will eventually hide a failure.
    matched_cases=$((matched_cases + 1))
    # REPEAT=N boots the same case N times. Intermittent failures are the only
    # kind a single boot cannot rule out, and "attestd sometimes never connects"
    # is exactly that shape -- so the harness has to be able to ask the question
    # twenty times, not once.
    local repeat="${REPEAT:-1}" iteration=1
    while [ "$iteration" -le "$repeat" ]; do
        if [ "$repeat" -gt 1 ]; then
            printf '\n--- %s: boot %d of %d ---\n' "$name" "$iteration" "$repeat"
        fi
        run_case_once "$name" "$spec" "$expect" "$runas"
        iteration=$((iteration + 1))
    done
    return 0
}


run_case_once() {
    local name="$1" spec="$2" expect="$3" runas="${4:-}"
    say "$name"

    sudo rm -rf "$WORK/meta" "$WORK/run" "$WORK/home" "$WORK/nosudo" "$WORK/sudo1" \
                "$WORK/etc" "$WORK/strict-run"
    mkdir -p "$WORK/meta" "$WORK/run" "$WORK/home" "$WORK/nosudo" "$WORK/sudo1" \
             "$WORK/workdir"
    # The literal NONE stages no spec at all: a strict-only workspace, which is
    # the Phase-4 sandbox that predates this work and has no supervisor.
    if [ "$spec" = "NONE" ]; then
        rm -f "$WORK/meta/openshell-sandbox.json"
    else
        printf '%s' "$spec" > "$WORK/meta/openshell-sandbox.json"
    fi
    # advisor.json is the host's signal that this workspace has an advisor, and
    # it is INDEPENDENT of the spec -- a policy with nothing but network rules
    # gets one and no spec at all. Staged by default, because that is what an
    # OpenShell-policy workspace looks like; NO_ADVISOR=1 is the workspace that
    # has none.
    if [ -n "${NO_ADVISOR:-}" ]; then
        rm -f "$WORK/meta/advisor.json"
    else
        printf '{"host":"policy.local","address":"192.0.2.254"}' \
            > "$WORK/meta/advisor.json"
    fi
    touch "$WORK/meta/strict-sandbox"
    # agentd reads these from the meta share; absent ones are simply skipped.
    : > "$WORK/meta/proxy.env"
    # And STAGE THE GUEST SCRIPTS, exactly as the host does. agentd resolves
    # every root helper as $META/<name>, and sandboxd imports its modules from
    # its own directory -- so a meta share holding only the spec produces a boot
    # where the root script silently starts nothing. Which is what the first run
    # of this test showed.
    # The sentry's prebuilt, for the cases that switch it on. The TESTABLE build,
    # which is identical except that it has an exit path: the shipped module
    # refuses to unload by design, and a test that loads it leaves this machine
    # carrying it until reboot.
    if [ -n "${WITH_SENTRY:-}" ]; then
        mkdir -p "$WORK/meta/sentry"
        make -C "$ROOT/sentry" EXTRA_CFLAGS=-DBROMURE_SENTRY_TESTABLE \
            >/dev/null 2>&1
        cp "$ROOT/sentry/bromure_sentry.ko" \
           "$WORK/meta/sentry/bromure_sentry-$(uname -r).ko"
    fi
    cp "$ROOT/bromure-sandboxd" "$ROOT/bromure-sentryd" "$ROOT/bromure-strict.py" \
       "$ROOT/bromure_openshell.py" "$ROOT/bromure_idmap.py" \
       "$ROOT/bromure_sandbox_status.py" "$ROOT/patched/bromure-attestd.py" \
       "$WORK/meta/"

    local marker="$WORK/host-connected"
    rm -f "$marker"
    export HOSTCTL="$WORK/hostctl.sock"
    rm -f "$HOSTCTL"
    ATTEST_LOG="$WORK/attestd-frames.jsonl"
    SENTRY_LOG="$WORK/sentry-frames.jsonl"
    rm -f "$ATTEST_LOG" "$SENTRY_LOG"
    python3 "$WORK/fake_host.py" "$SHELL_PORT" "$marker" "$HOSTCTL" "$ATTEST_LOG" \
        "$SENTRY_LOG" > "$WORK/host.log" 2>&1 &
    FAKE_HOST=$!
    for _ in $(seq 1 40); do [ -S "$HOSTCTL" ] && break; sleep 0.1; done

    # INCARNATION 1's sudo. The root script must really run -- it is what starts
    # attestd, the sentry loader and the supervisor, and what touches
    # STRICT_DONE -- but it must not revoke THIS machine's sudo or kill this
    # session. So the stub strips exactly those lines and passes the rest to the
    # real sudo. Everything under test stays real.
    # A throwaway /etc for the revocation to act on. It must still really run --
    # it is what the second incarnation depends on having happened -- but aimed
    # at copies, not at the machine running the test. The first version of this
    # test did not redirect it and revoked the test machine's own sudo.
    mkdir -p "$WORK/etc/sudoers.d"
    cp /etc/group "$WORK/etc/group"
    sudo cp /etc/gshadow "$WORK/etc/gshadow" 2>/dev/null || : > "$WORK/etc/gshadow"
    sudo chown "$(id -u)" "$WORK/etc/gshadow" 2>/dev/null
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$(id -un)" > "$WORK/etc/sudoers.d/90-ubuntu"

    cat > "$WORK/sudo1/sudo" <<STUB
#!/usr/bin/env python3
import os, sys
FAKE_ETC = "$WORK/etc"
REDIRECT = ("env BROMURE_SUDOERS_D=%s/sudoers.d BROMURE_GROUP_FILE=%s/group "
            "BROMURE_GSHADOW_FILE=%s/gshadow BROMURE_STRICT_RUN=$WORK/strict-run "
            % (FAKE_ETC, FAKE_ETC, FAKE_ETC))
argv = sys.argv[1:]
if len(argv) >= 4 and argv[0] == "-n" and argv[1] == "sh" and argv[2] == "-c":
    kept = []
    for line in argv[3].splitlines():
        if any(t in line for t in ("loginctl terminate-user", "getty@tty1")):
            continue
        # The revocation runs for real, against the copies above.
        if "bromure-strict.py" in line:
            line = REDIRECT + line
        kept.append(line)
    argv = ["-n", "sh", "-c", "\n".join(kept)]
elif any("poweroff" in a for a in argv):
    sys.exit(0)
os.execvp("/usr/bin/sudo", ["/usr/bin/sudo", *argv])
STUB
    chmod +x "$WORK/sudo1/sudo"

    # INCARNATION 2's sudo: gone. A stub that always fails is a faithful stand-in
    # for `ubuntu ALL=(ALL) !ALL`, and it fails loudly rather than silently.
    printf '#!/bin/sh\necho "sudo: a password is required" >&2\nexit 1\n' \
        > "$WORK/nosudo/sudo"
    chmod +x "$WORK/nosudo/sudo"

    export CTL="$WORK/run/ctl.sock"
    local common="HOME=$WORK/home BROMURE_META=$WORK/meta"
    common="$common BROMURE_RUN_DIR=$WORK/run"
    common="$common BROMURE_STRICT_DONE=$WORK/run/strict.done BROMURE_HOST_CID=1"
    # attestd is started by the root script as a systemd unit; without the CID
    # in _OVERRIDE_ENV it would dial CID 2 and never reach this fake host.
    common="$common BROMURE_SANDBOXD_NO_POWEROFF=1 BROMURE_AGENTD_PID=$$"
    # A throwaway /etc/hosts for the advisor task. Never the real one: agentd
    # rewrites it, and a test that edits /etc/hosts can stop this machine
    # resolving its own name.
    printf '127.0.0.1\tlocalhost\n127.0.1.1\tbox\n' > "$WORK/etc-hosts"
    common="$common BROMURE_HOSTS_FILE=$WORK/etc-hosts"
    # Never let a test raise lockdown. It is one-way for the boot, and
    # `integrity` refuses unsigned modules -- so the first run would be the last
    # one this VM could do. That happened here before this line existed.
    common="$common BROMURE_SENTRY_NO_LOCKDOWN=1"

    # --- incarnation 1: runs the root script, then exits 75 -------------------
    ( cd "$WORK" && env PATH="$WORK/sudo1:$PATH" $common \
        timeout 120 /usr/bin/python3 "$AGENTD" > "$WORK/agentd1.log" 2>&1 )
    local rc1=$?
    if [ "$rc1" = "75" ]; then
        ok "incarnation 1 ran the root script and exited 75"
    else
        bad "incarnation 1 exited $rc1, expected 75"
        tail -12 "$WORK/agentd1.log" | sed 's/^/       /'
    fi
    # The advisor mapping has to be written in the REAL boot sequence: after the
    # hostname task (which rewrites /etc/hosts wholesale) and before the strict
    # revocation (after which there is no sudo). Asserting it here is asserting
    # the ordering, which is the part a unit test cannot reach.
    # THE ATTESTOR. Without it the host fails closed on every binary-scoped
    # network rule, so a boot where it never connects is a workspace where curl
    # silently does not work -- and nothing in the guest says why.
    # WITHIN A FEW SECONDS, not merely eventually. The failure this replaced was
    # an attestor that connected ~80 s into a spec-less boot: every binary-scoped
    # network rule failed closed for that minute and a quarter, twenty denied
    # connections deep, and a test that only asked "did it connect at all?" called
    # that a pass. The host waits 8 s; anything slower is a broken workspace.
    local attest_deadline=8
    local attest_waited=0 attest_ok=no
    while [ "$attest_waited" -lt 25 ]; do
        if [ -s "$ATTEST_LOG" ] && grep -q '"connected"' "$ATTEST_LOG" 2>/dev/null; then
            attest_ok=yes; break
        fi
        sleep 1
        attest_waited=$((attest_waited + 1))
    done
    if [ "$attest_ok" = yes ] && [ "$attest_waited" -le "$attest_deadline" ]; then
        ok "the attestor connected on 5840 after ${attest_waited}s (budget ${attest_deadline}s)"
    elif [ "$attest_ok" = yes ]; then
        bad "the attestor connected only after ${attest_waited}s -- binary rules failed closed for all of it"
    else
        bad "NO attestor connection within 25s -- binary rules fail closed all boot"
        printf '     attestd unit:\n'
        sudo systemctl status bromure-attestd --no-pager -n 15 2>/dev/null \
            | sed 's/^/       /'
        sudo journalctl -u bromure-attestd --no-pager -n 20 2>/dev/null \
            | sed 's/^/       /'
    fi
    # And it must actually SAY something: a connection with no sandbox_status is
    # a host that knows the VM is alive and nothing else.
    local status_waited=0 status_ok=no
    while [ "$status_waited" -lt 20 ]; do
        if grep -q '"event": "sandbox_status"\|"event":"sandbox_status"' \
             "$ATTEST_LOG" 2>/dev/null; then
            status_ok=yes; break
        fi
        sleep 1
        status_waited=$((status_waited + 1))
    done
    if [ "$status_ok" = yes ]; then
        ok "and sent a sandbox_status"
        if [ "$spec" = "NONE" ]; then
            # A status with no spec: `requested` is null (the host never asked
            # for anything) and the revocation is still reported.
            if python3 -c "
import json, sys
for line in open('$ATTEST_LOG'):
    try: d = json.loads(line)
    except ValueError: continue
    if d.get('event') == 'sandbox_status':
        sys.exit(0 if d.get('requested') is None else 1)
sys.exit(1)"; then
                ok "with requested=null, as a workspace that staged no spec"
            else
                bad "a no-spec workspace reported a non-null 'requested'"
            fi
        fi
    else
        bad "the attestor connected but sent no sandbox_status in 20s"
        head -5 "$ATTEST_LOG" 2>/dev/null | sed 's/^/       /'
    fi

    # Keyed on advisor.json, NOT on the spec. A workspace whose policy is only
    # network rules has no spec and still needs the mapping.
    if [ -n "${NO_ADVISOR:-}" ]; then
        # The converge-both-ways half a unit test cannot show: a real boot of a
        # workspace with no advisor leaves nothing behind.
        if grep -q "policy.local" "$WORK/etc-hosts" 2>/dev/null; then
            bad "an advisor mapping was written for a workspace with no advisor"
        else
            ok "no advisor.json, no mapping (nothing left behind)"
        fi
    elif grep -q "192.0.2.254.*policy.local" "$WORK/etc-hosts" 2>/dev/null; then
        ok "the advisor mapping was written during boot, before the revocation"
    else
        bad "no advisor mapping in the hosts file after incarnation 1: $(cat "$WORK/etc-hosts" 2>/dev/null | tr '\n' ' ')"
    fi
    if grep -q "127.0.1.1" "$WORK/etc-hosts" 2>/dev/null; then
        ok "and the existing hosts entries survived"
    else
        bad "the hosts file lost its existing entries"
    fi

    if [ -f "$WORK/run/strict.done" ]; then
        ok "the strict marker was written, so incarnation 2 will skip the "\
"privileged tasks"
    else
        bad "no strict marker; incarnation 2 would redo the privileged tasks"
    fi
    # The guard that would have caught the test revoking its own machine.
    if mountpoint -q /etc/sudoers.d || mountpoint -q /etc/group; then
        bad "THE TEST REVOKED ITS OWN MACHINE -- the revocation was not redirected"
        sudo umount /etc/sudoers.d /etc/group /etc/gshadow 2>/dev/null
    else
        ok "the real /etc was left alone"
    fi
    if grep -q "$(id -un)" "$WORK/etc/group" 2>/dev/null && \
       ! grep -qE "^(docker|sudo):.*$(id -un)" "$WORK/strict-run/group" 2>/dev/null; then
        ok "the revocation really ran, against the throwaway /etc"
    fi

    if [ -n "${EXPECT_NO_SUPERVISOR:-}" ]; then
        # A workspace with no spec must not get one, and -- the regression this
        # case exists for -- must not WAIT for one either.
        if [ -S "$WORK/run/ctl.sock" ]; then
            bad "a supervisor came up for a workspace with no openshell spec"
        else
            ok "no spec, no supervisor (correct)"
        fi
    elif [ -S "$WORK/run/ctl.sock" ]; then
        ok "the root script left the supervisor running"
    else
        bad "the root script did not leave a supervisor; see $WORK/agentd1.log"
        tail -12 "$WORK/agentd1.log" | sed 's/^/       /'
    fi
    SUPERVISOR=$(pgrep -f "python3 $ROOT/bromure-sandboxd" | head -1)

    # --- incarnation 2: systemd's restart, with no sudo left ------------------
    ( cd "$WORK" && env PATH="$WORK/nosudo:$PATH" $common \
        timeout $((DEADLINE + 20)) /usr/bin/python3 "$AGENTD" \
        > "$WORK/agentd.log" 2>&1 ) &
    AGENTD_PID=$!

    local waited=0 connected=no
    while [ "$waited" -lt "$DEADLINE" ]; do
        if [ -f "$marker" ]; then connected=yes; break; fi
        if ! kill -0 "$AGENTD_PID" 2>/dev/null; then break; fi
        sleep 1
        waited=$((waited + 1))
    done

    if [ "$connected" = yes ]; then
        ok "the host got its shell connection after ${waited}s"
    else
        bad "NO shell connection within ${DEADLINE}s -- this is the blocker"
        printf '     last agentd log lines:\n'
        sed -n '$!d;=' /dev/null 2>/dev/null
        tail -18 "$WORK/agentd.log" | sed 's/^/       /'
    fi

    # And the session, which is the other half: a reachable agentd with no panes
    # is better than an unreachable one, but it is still not a working workspace.
    #
    # Asked AS THE SERVER'S UID, and by reading the output rather than the exit
    # status. tmux refuses a client whose uid is not the server's and then exits
    # **0** after printing "access not allowed" -- so a plain `has-session` from
    # the test's own uid reported a healthy session on the very configuration
    # where there was none. That is the same lie agentd's own probe was told.
    local session=no
    if [ -n "${EXPECT_NO_SUPERVISOR:-}" ]; then
        # The sandboxed socket is the supervisor's; a strict-only workspace runs
        # agentd's own tmux server on its default socket, exactly as it did
        # before any of this existed. Nothing to check here.
        session="$expect"
    else
        for _ in $(seq 1 20); do
            if session_present "$runas"; then session=yes; break; fi
            sleep 0.5
        done
    fi
    if [ "$session" = "$expect" ]; then
        ok "session present=$session (expected $expect)"
    else
        bad "session present=$session, expected $expect"
        # The session-relevant lines, not just the tail: the tail is usually a
        # port-conflict traceback from a previous case and says nothing.
        grep -aE "sandbox|session|tabs|tmux|supervisor" "$WORK/agentd.log" \
            | tail -14 | sed 's/^/       /'
        printf '     the supervisor said:\n'
        sudo tail -8 "$WORK/run/../sup.log" 2>/dev/null | sed 's/^/       /'
        sudo journalctl -u bromure-sandboxd --no-pager -n 12 2>/dev/null \
            | sed 's/^/       /'
    fi

    # --- what `run_as_user` has to get right ----------------------------------
    if [ -n "$runas" ]; then
        local sock="$WORK/run/server/tmux.sock"
        # 1. The control socket. This is the one that made every command 127.
        local ctlgid
        ctlgid=$(sudo stat -c '%g' "$WORK/run/ctl.sock" 2>/dev/null)
        if [ "$ctlgid" = "$(id -g)" ]; then
            ok "ctl.sock carries the WORKSPACE group ($ctlgid), so agentd can reach it"
        else
            bad "ctl.sock is gid $ctlgid, not the workspace group $(id -g) -- agentd cannot connect and every command will be 127"
        fi
        # 2. A home, and NOT the project folder -- which is what it fell back to
        #    when the account had none, putting the agent's dotfiles in the user's
        #    repository. WHICH home, and why, is asserted in 8 below.
        local home home_via
        home=$(sudo python3 -c "
import json; print((json.load(open('$WORK/run/status.json')).get('run_as') or {}).get('home',''))" 2>/dev/null)
        home_via=$(sudo python3 -c "
import json; print((json.load(open('$WORK/run/status.json')).get('run_as') or {}).get('home_via',''))" 2>/dev/null)
        if [ -n "$home" ] && [ "$home" != "$WORKDIR_UNDER_TEST" ]; then
            ok "the run_as user has a home ($home, via $home_via) that is not the project folder"
        else
            bad "run_as home is '$home', which is the project folder or empty"
        fi
        # 4. A real shell, or every pane exits the instant it starts.
        local shell
        shell=$(getent passwd "$runas" | cut -d: -f7)
        case "$shell" in
            */nologin|*/false|"") bad "the run_as account's shell is '$shell'; panes will exit at once" ;;
            *) ok "the run_as account has a usable shell ($shell)" ;;
        esac
        # 5. A direct client from the test's uid must be REFUSED -- this is the
        #    fact the routing exists for, asserted so it cannot silently change.
        local direct
        direct=$(tmux -S "$sock" has-session -t bromure 2>&1)
        case "$direct" in
            *"access not allowed"*)
                ok "tmux refuses a cross-uid client (so agentd must route through the supervisor)" ;;
            *"no server running"*)
                bad "no server to test the cross-uid refusal against" ;;
            *)
                bad "expected tmux to refuse a client from uid $(id -u) against a uid-$runas server, got '$direct'" ;;
        esac
        # 6. And the failure of an exec has to SAY something.
        local reason
        reason=$(exec_reason '["/nonexistent/binary"]')
        case "$reason" in
            *nonexistent*ENOENT*) ok "a failed exec reports the operation, path and errno: $reason" ;;
            *) bad "a failed exec gave no usable reason: '$reason'" ;;
        esac
        reason=$(exec_reason_cwd "$WORK/forbidden")
        case "$reason" in
            *chdir*EACCES*) ok "an exec that cannot enter its cwd says so: $reason" ;;
            *) bad "an unreachable cwd gave no usable reason: '$reason'" ;;
        esac

        # 7a. OpenShell's baseline, end to end. The policy below lists neither
        #     /dev/urandom nor /var/log, and has a network rule, so OpenShell
        #     would enrich both -- and its own e2e test reads /dev/urandom.
        if sandbox_sh "head -c 16 /dev/urandom > /dev/null" >/dev/null 2>&1; then
            ok "/dev/urandom is readable from inside the sandbox"
        else
            bad "head -c 16 /dev/urandom failed inside the sandbox: $(sandbox_sh 'head -c 16 /dev/urandom' 2>&1 | tail -1)"
        fi
        # Only the case whose policy omits it AND carries a network rule can
        # assert it came from the enrichment; the other case lists it outright.
        if [ -z "${EXPECT_BASELINE:-}" ]; then
            :
        elif sudo python3 -c "
import json, sys
d = json.load(open('$WORK/run/status.json'))
adds = (d.get('additions') or {})
why = adds.get('why') or {}
sys.exit(0 if why.get('/dev/urandom', '').startswith('OpenShell baseline') else 1)"; then
            ok "and it is reported as an OpenShell baseline addition"
        else
            bad "/dev/urandom is not reported as a baseline addition: $(sudo python3 -c "
import json;print(json.dumps((json.load(open('$WORK/run/status.json')).get('additions') or {}).get('why')))")"
        fi

        # 7. The share, end to end, from inside the confinement -- the same
        #    `confine_self` a pane goes through. This is the claim that cannot be
        #    reasoned about: virtiofs reports the host's ids and does not enforce
        #    the guest's DAC, so only an attempt settles it.
        local wd="${WORKDIR_UNDER_TEST:-$WORK/workdir}"
        if sandbox_sh "cat '$wd/host.txt'" 2>/dev/null | grep -q "from the host"; then
            ok "the sandbox can READ a host-created file in the share"
        else
            bad "the sandbox could not read $wd/host.txt: $(sandbox_sh "cat '$wd/host.txt'" 2>&1 | tail -1)"
        fi
        if sandbox_sh "printf 'appended by the sandbox\n' >> '$wd/host.txt'" >/dev/null 2>&1 \
           && grep -q "appended by the sandbox" "$wd/host.txt" 2>/dev/null; then
            ok "the sandbox can EDIT a host-created file, and the edit is visible outside"
        else
            bad "the sandbox could not append to $wd/host.txt: $(sandbox_sh "printf x >> '$wd/host.txt'" 2>&1 | tail -1)"
        fi
        if sandbox_sh "echo made-in-the-sandbox > '$wd/guest.txt'" >/dev/null 2>&1 \
           && [ -f "$wd/guest.txt" ]; then
            ok "the sandbox can CREATE a file in the share (owner outside: uid $(stat -c '%u' "$wd/guest.txt"))"
        else
            bad "the sandbox could not create a file in $wd: $(sandbox_sh "echo x > '$wd/guest.txt'" 2>&1 | tail -1)"
        fi
        # 8. The home. It must be the WORKSPACE user's home through the idmapped
        #    mount, because that is where Bromure seeds the agent's configuration:
        #    a workload with a home of its own starts unconfigured. See §1.12.
        local owner_home
        owner_home=$(getent passwd "$(id -un)" | cut -d: -f6)
        if [ -n "${EXPECT_FALLBACK_HOME:-}" ]; then
            # The policy does not grant the workspace home, so the supervisor must
            # decline it rather than hand the workload a home it cannot enter.
            if [ "$home" != "$owner_home" ] && [ "$home_via" = "supervisor-created fallback" ]; then
                ok "the policy does not grant $owner_home, so HOME fell back to $home"
            else
                bad "HOME is $home via '$home_via'; expected a fallback, not the ungranted $owner_home"
            fi
            if [ "$(sudo stat -c '%u %a' "$home" 2>/dev/null)" = "$runas 700" ]; then
                ok "the fallback home is owned by uid $runas, mode 0700"
            else
                bad "$home is $(sudo stat -c '%u %a' "$home" 2>/dev/null), expected '$runas 700'"
            fi
            if sudo python3 -c "
import json, sys
d = json.load(open('$WORK/run/status.json'))
sys.exit(0 if '$home' in (d.get('additions') or {}).get('read_write', []) else 1)"; then
                ok "and the ruleset grants it, so it is a home the workload can use"
            else
                bad "the fallback home is not in the Landlock additions"
            fi
            if sandbox_sh "cd ~ && touch .bashrc && pwd" 2>/dev/null | grep -q "^$home$"; then
                ok "a pane really gets HOME=$home and can write it"
            else
                bad "the workload could not use the fallback home: $(sandbox_sh 'cd ~ && touch .bashrc' 2>&1 | tail -1)"
            fi
            # And it must NOT have reached the ungranted home.
            if sandbox_sh "ls '$owner_home' > /dev/null" >/dev/null 2>&1; then
                bad "the workload can list $owner_home, which the policy does not grant"
            else
                ok "and the ungranted $owner_home stays out of reach"
            fi
        elif [ "$home" = "$owner_home" ]; then
            ok "HOME is the workspace user's home ($home), not a home of its own"
        else
            bad "HOME is $home, expected the idmapped $owner_home (home_via=$home_via)"
        fi
        if [ -n "${EXPECT_FALLBACK_HOME:-}" ]; then
            :
        else
        if [ "$(sandbox_sh 'printf %s "$HOME"' 2>/dev/null)" = "$owner_home" ]; then
            ok "and a pane really gets HOME=$owner_home"
        else
            bad "a pane's \$HOME is '$(sandbox_sh 'printf %s "$HOME"' 2>&1)'"
        fi
        # The seeded configuration has to be readable through the remap. Any file
        # Bromure actually seeds will do; .bashrc exists on every image.
        local seeded="" candidate
        for candidate in .claude/settings.json .gitconfig .bashrc .profile; do
            [ -e "$owner_home/$candidate" ] && { seeded="$candidate"; break; }
        done
        if [ -n "$seeded" ]; then
            if sandbox_sh "cat ~/'$seeded' > /dev/null" >/dev/null 2>&1; then
                ok "the workload can read the seeded ~/$seeded through the remap"
            else
                bad "the workload could not read ~/$seeded: $(sandbox_sh "cat ~/'$seeded'" 2>&1 | tail -1)"
            fi
        else
            printf '  SKIP nothing seeded in %s to read\n' "$owner_home"
        fi
        # And the direction that proves the remap is real: the workload sees the
        # home as its OWN uid, while what it writes lands on disk owned by the
        # workspace user -- so nothing it creates needs a chown afterwards.
        local probe=".bromure-boottest-idmap-$$"
        if sandbox_sh "echo written-by-the-workload > ~/'$probe'" >/dev/null 2>&1; then
            local inside outside
            inside=$(sandbox_sh "stat -c %u ~/'$probe'" 2>/dev/null | tr -d '[:space:]')
            outside=$(stat -c %u "$owner_home/$probe" 2>/dev/null)
            if [ "$inside" = "$runas" ] && [ "$outside" = "$(id -u)" ]; then
                ok "a file the workload writes in ~ is uid $inside inside the remap and uid $outside on disk"
            else
                bad "idmap direction wrong: inside=$inside (want $runas), on disk=$outside (want $(id -u))"
            fi
            rm -f "$owner_home/$probe"
        else
            bad "the workload could not write its own home: $(sandbox_sh "echo x > ~/'$probe'" 2>&1 | tail -1)"
        fi
        fi
    fi

    # --- `vm exec`, over vsock, the way the host actually does it ------------
    #
    # EVERY configuration, not just the run_as ones: this is the channel the user
    # reaches the workspace through, and until now nothing here exercised it. Two
    # rounds of "run_as_user: sandbox fails with a silent 127" got through because
    # the assertions all called `_ws_run` in this shell instead.
    say "$name -- vm exec over vsock 5800"
    local reply rc out
    reply=$(host_exec '"argv":["/bin/echo","hi"],"timeout":60')
    rc=$(printf '%s' "$reply" | python3 -c "
import json,sys
try: print(json.loads(sys.stdin.read() or '{}').get('exit_code','?'))
except ValueError: print('?')")
    out=$(printf '%s' "$reply" | python3 -c "
import json,sys
try: print((json.loads(sys.stdin.read() or '{}').get('stdout') or '').strip())
except ValueError: print('')")
    if [ "$rc" = "0" ] && [ "$out" = "hi" ]; then
        ok "vm exec /bin/echo hi -> rc 0, stdout 'hi'"
    else
        bad "vm exec /bin/echo hi -> rc=$rc stdout='$out'; full reply: $reply"
    fi

    reply=$(host_exec '"argv":["/usr/bin/id"],"timeout":60')
    rc=$(printf '%s' "$reply" | python3 -c "
import json,sys
try: print(json.loads(sys.stdin.read() or '{}').get('exit_code','?'))
except ValueError: print('?')")
    out=$(printf '%s' "$reply" | python3 -c "
import json,sys
try: print((json.loads(sys.stdin.read() or '{}').get('stdout') or '').strip())
except ValueError: print('')")
    if [ "$rc" = "0" ] && [ -n "$out" ]; then
        ok "vm exec id -> rc 0, $out"
        if [ -n "$runas" ] && ! printf '%s' "$out" | grep -q "uid=$runas"; then
            bad "the command ran as $out, expected uid=$runas"
        fi
    else
        bad "vm exec id -> rc=$rc stdout='$out'; full reply: $reply"
    fi

    # A shell pipeline, which takes the other branch (`cmd`, use_shell=True).
    reply=$(host_exec '"cmd":"echo one; echo two | tr a-z A-Z","timeout":60')
    out=$(printf '%s' "$reply" | python3 -c "
import json,sys
try: print((json.loads(sys.stdin.read() or '{}').get('stdout') or '').replace(chr(10),'|').strip())
except ValueError: print('')")
    out=${out%|}
    if [ "$out" = "one|TWO" ]; then
        ok "a shell pipeline keeps its semantics (stdout '$out')"
    else
        bad "a shell pipeline gave '$out'; full reply: $reply"
    fi

    # A command that genuinely fails must report the failure, not a bare 127 with
    # nothing on stderr -- which is what two rounds of this blocker looked like.
    reply=$(host_exec '"argv":["/nonexistent/binary"],"timeout":60')
    if printf '%s' "$reply" | grep -qE "not found|No such file|ENOENT|cannot run"; then
        ok "a failing command comes back with a reason, not an empty 127"
    else
        bad "a failing command gave no reason: $reply"
    fi

    # A strict-only workspace: the revocation really happened, and commands run
    # anyway. Both halves matter -- "exec works" without "sudo is gone" would mean
    # the gate had simply been removed.
    if [ -n "${EXPECT_NO_SUPERVISOR:-}" ]; then
        # `sudo` by NAME, so PATH resolution applies: incarnation 2 runs with the
        # harness's failing stub ahead of the real binary, which is this test's
        # stand-in for the revoked sudoers. The revocation itself is aimed at a
        # throwaway /etc on purpose -- an earlier version of this test revoked the
        # test machine's own sudo -- so /usr/bin/sudo really does still work here,
        # and asserting on the absolute path would be asserting on the harness.
        reply=$(host_exec '"cmd":"sudo -n true","timeout":60')
        rc=$(printf '%s' "$reply" | python3 -c "
import json,sys
try: print(json.loads(sys.stdin.read() or '{}').get('exit_code','?'))
except ValueError: print('?')")
        if [ "$rc" != "0" ]; then
            ok "sudo fails inside the workspace (rc=$rc), as after a revocation"
        else
            bad "sudo succeeded; the workspace is not in the post-revocation state"
        fi
        # And the revocation's own report, which is what the gate keys off.
        if sudo python3 -c "
import json, sys
d = json.load(open('$WORK/run/bromure-sandbox/strict.json'))
sys.exit(0 if d.get('applied') else 1)" 2>/dev/null; then
            ok "strict.json reports applied=true, so the gate had its answer"
        elif [ -f "$WORK/run/strict.done" ]; then
            ok "the strict marker is present (strict.json not staged in this run)"
        else
            bad "neither strict.json nor the marker says the revocation happened"
        fi
    fi

    # DNS, from the host's own exec path. Every hostname-based network rule is
    # unusable without it, and the failure reads as a network denial rather than
    # the filesystem one it is -- so it is asserted for every configuration, not
    # just the ones that happen to grant /etc.
    reply=$(host_exec '"argv":["/usr/bin/getent","hosts","one.one.one.one"],"timeout":60')
    rc=$(printf '%s' "$reply" | python3 -c "
import json,sys
try: print(json.loads(sys.stdin.read() or '{}').get('exit_code','?'))
except ValueError: print('?')")
    if [ "$rc" = "0" ]; then
        ok "getent hosts resolves inside the sandbox (DNS works)"
    else
        bad "getent hosts failed (rc=$rc) -- DNS is broken in the sandbox: $reply"
    fi
    reply=$(host_exec '"argv":["/bin/cat","/etc/resolv.conf"],"timeout":60')
    if printf '%s' "$reply" | grep -q "nameserver"; then
        ok "and /etc/resolv.conf is readable through the symlink"
    else
        bad "/etc/resolv.conf is not readable in the sandbox: $(printf '%s' "$reply" | head -c 300)"
    fi

    # And an interactive attach, which is the OTHER path: a pty the supervisor
    # runs on agentd's behalf.
    reply=$(host_exec '"op":"attach","request":{"cmd":"/bin/bash -i"},"send":"echo ATTACH_OK_MARKER\n","expect":"ATTACH_OK_MARKER","timeout":60')
    if printf '%s' "$reply" | grep -q "ATTACH_OK_MARKER"; then
        ok "an interactive attach reaches a live shell"
    else
        bad "the interactive attach produced nothing usable: $(printf '%s' "$reply" | head -c 400)"
    fi

    # --- an idle workspace must be silent -----------------------------------
    #
    # The noise that hides the signal. agentd's status loops ran through
    # `_capture` -> `_ws_run`, so `df -kP /`, the docker polls and `ss` executed
    # INSIDE the sandbox and were denied every couple of seconds, forever --
    # 33 of the first 59 timeline rows after a boot were Bromure asking itself
    # how much disk was left, and they fed the host's drift score. A user who
    # learns to ignore those rows has been taught to ignore the real one.
    if [ -n "${WITH_SENTRY:-}" ]; then
        local sentry_waited=0
        while [ "$sentry_waited" -lt 40 ]; do
            [ -s "$SENTRY_LOG" ] && break
            sleep 1; sentry_waited=$((sentry_waited + 1))
        done
        if [ -s "$SENTRY_LOG" ]; then
            ok "the sentry connected on 5841 after ${sentry_waited}s"
        else
            bad "the sentry never connected; the idle assertion cannot run"
            printf '       staged prebuilts: %s\n' "$(ls "$WORK/meta/sentry" 2>&1 | tr '\n' ' ')"
            printf '       sentry.json: %s\n' "$(sudo cat "$WORK/run/sentry.json" 2>&1 | head -c 400)"
            printf '       loaded: %s\n' "$(lsmod | grep -c bromure_sentry)"
        fi
        printf '     idling for %ss with the status loops running...\n' "$IDLE_SECONDS"
        local before_denials
        before_denials=$(grep -c '"kind":"sandbox_denied"' "$SENTRY_LOG" 2>/dev/null || echo 0)
        sleep "$IDLE_SECONDS"
        [ -s "$SENTRY_LOG" ] || : > "$SENTRY_LOG"
        python3 - "$SENTRY_LOG" "$before_denials" <<'PY'
import json, sys, collections
log, before = sys.argv[1], int(sys.argv[2])
rows = []
for line in open(log):
    try:
        rows.append(json.loads(line))
    except ValueError:
        pass
# Denials that arrived DURING the idle window, not since boot. Session creation
# legitimately produces a few one-shot reads; the failure this guards against is
# the steady drip from status loops, which is what `before` separates out.
den = [r for r in rows if r.get("kind") == "sandbox_denied"][before:]
sudo_gain = [r for r in rows if r.get("kind") == "cred_gain"
             and "sudo" in (r.get("path") or "") and r.get("sandboxed")]
print("  info %d denial(s) before the idle window (session start), %d during"
      % (before, len(den)))
if den:
    by = collections.Counter("%s %s %s" % (r.get("comm"), r.get("op"), r.get("path"))
                             for r in den)
    print("  FAIL an idle workspace produced %d sandbox_denied event(s):" % len(den))
    for what, n in by.most_common(8):
        print("         %s  x%d" % (what, n))
    sys.exit(1)
print("  ok   an idle workspace produced ZERO sandbox_denied events")
if sudo_gain:
    print("  FAIL %d sudo cred_gain from SANDBOXED tasks while idle" % len(sudo_gain))
    sys.exit(1)
print("  ok   and zero sudo cred_gain from workload tasks")
PY
        rc=$?; [ $rc -eq 0 ] || fails=$((fails + 1))
    fi

    # --- the pre-sandbox exec window -------------------------------------
    # Round 7 moved the shell service ahead of the session work so a hung sandbox
    # step could not cost the host its way in. That was right, and it opened a
    # window: `vm exec` answered at uptime 4.4s, before the root script had run,
    # so host commands were served unconfined with sudo still present -- and
    # `bash -lc` sources an agent-writable ~/.bashrc from the PERSISTENT home.
    #
    # The connection must still be accepted at once. What must wait is anything
    # that runs workspace content.
    if grep -aq "refusing a workspace request\|shell.*starting" "$WORK/agentd.log" 2>/dev/null; then
        :
    fi
    printf 'echo PRE_SANDBOX_PWNED > %s/pwned\n' "$WORK" > "$WORK/home/.bashrc"
    rm -f "$WORK/pwned"
    python3 - <<PY > "$WORK/exec-result.txt" 2>&1
import json, socket, struct, sys, time
# The host's own exec path, fired the way the host fires it.
s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
s.settimeout(60)
try:
    s.connect((1, $SHELL_PORT))
except OSError as exc:
    print("connect-failed:%s" % exc); sys.exit(0)
PY
    # The pool must survive being gated: several execs at boot each hold a
    # connection for as long as the sandbox takes, and the pool is small.
    for _ in 1 2 3 4; do
        ( python3 - <<PY >/dev/null 2>&1 &
import socket
s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
s.settimeout(5)
try:
    s.connect((1, $SHELL_PORT))
except OSError:
    pass
PY
        ) 2>/dev/null
    done
    sleep 2
    if grep -acq "failed to replenish pool" "$WORK/agentd.log" 2>/dev/null; then
        bad "the connection pool was starved by gated requests"
    else
        ok "the pool survived four concurrent gated requests"
    fi

    if [ -f "$WORK/pwned" ]; then
        bad "a host exec ran ~/.bashrc OUTSIDE the sandbox (the pre-sandbox window)"
        sudo rm -f "$WORK/pwned"
    else
        ok "no host exec ran workspace content before the sandbox was up"
    fi

    # And agentd must not exec sudo once strict has taken it away: a FAILED sudo
    # is still a credential gain, because the binary is setuid root and the exec
    # raises euid to 0 before the policy refuses. ports_loop_service ran one
    # every three seconds.
    if grep -aqE "sudo: a password is required" "$WORK/agentd.log" 2>/dev/null; then
        bad "agentd execed sudo after the revocation ($(grep -ac 'password is required' "$WORK/agentd.log") times)"
    else
        ok "agentd never execed sudo after the revocation"
    fi

    # The shell service must be up BEFORE the session work, so that a hung
    # session step can never take the host's control channel with it.
    if grep -aq "shell.*starting" "$WORK/agentd.log" 2>/dev/null; then
        local shell_line session_line
        shell_line=$(grep -an "shell.*starting" "$WORK/agentd.log" | head -1 | cut -d: -f1)
        session_line=$(grep -anE "sandbox.*(filesystem|launcher)|session:" "$WORK/agentd.log" \
            | head -1 | cut -d: -f1)
        if [ -z "$session_line" ] || [ "$shell_line" -lt "$session_line" ]; then
            ok "the shell service started before any session work"
        else
            bad "session work was logged before the shell service started"
        fi
    fi

    # Kill the whole process group: AGENTD_PID is the subshell, and `timeout`
    # plus the python underneath it survive a kill of the subshell alone -- which
    # left the previous case's agentd holding the vsock and TCP ports, so the next
    # case logged "Address already in use" for two services and looked broken.
    if [ -n "$AGENTD_PID" ]; then
        kill -9 "-$AGENTD_PID" 2>/dev/null
        kill -9 "$AGENTD_PID" 2>/dev/null
    fi
    pkill -9 -f "python3 $AGENTD" 2>/dev/null
    AGENTD_PID=""
    kill -9 "$FAKE_HOST" 2>/dev/null; FAKE_HOST=""
    # Undo the revocation's bind mounts. A reboot does this for free -- it is the
    # entire reason the revocation is runtime-only (§1.10) -- but this test puts
    # several "boots" in one namespace, so without it the next case inherits the
    # previous one's read-only /etc and cannot even stage its own.
    for m in "$WORK/etc/sudoers.d" "$WORK/etc/group" "$WORK/etc/gshadow"; do
        mountpoint -q "$m" 2>/dev/null && sudo umount "$m" 2>/dev/null
    done
    sudo tmux -S "$WORK/run/server/tmux.sock" kill-server 2>/dev/null
    # Stop the UNIT, not just the process: systemd owns the name, and a
    # still-active or failed unit makes the next case's systemd-run fail with
    # "unit already exists" -- which looks exactly like the bug under test.
    sudo systemctl stop bromure-sandboxd bromure-attestd 2>/dev/null
    sudo systemctl reset-failed bromure-sandboxd bromure-attestd 2>/dev/null
    for pid in $(pgrep -f "bromure-sandboxd"); do sudo kill -9 "$pid" 2>/dev/null; done
    sudo pkill -9 -f "bromure-attestd.py" 2>/dev/null
    SUPERVISOR=""
    sleep 1
}

SYSTEM_RO='"/usr","/bin","/lib","/etc","/proc","/dev/urandom","/dev/tty","/run/utmp"'
# The same list WITHOUT /dev/urandom, for the case that proves OpenShell's
# baseline enrichment supplies it rather than the policy.
SYSTEM_RO_NO_URANDOM='"/usr","/bin","/lib","/etc","/proc","/dev/tty","/run/utmp"'
SYSTEM_RW='"/dev/null"'

run_case "sentry-only (no Landlock, no seccomp)" "$(cat <<EOF
{"version":1,"filesystem_policy":null,"landlock":null,"process":null,
 "strict_sandbox":true,
 "workdirs":["$WORK/workdir"],"sentry":{"enabled":false}}
EOF
)" yes

run_case "landlock-only (Landlock, no process layer)" "$(cat <<EOF
{"version":1,
 "filesystem_policy":{"read_only":[$SYSTEM_RO],
                      "read_write":[$SYSTEM_RW,"$WORK/run","$WORK/home","/tmp"],
                      "include_workdir":true},
 "landlock":{"compatibility":"best_effort"},"process":null,
 "workdirs":["$WORK/workdir"],"sentry":{"enabled":false}}
EOF
)" yes

run_case "strict (Landlock + seccomp + run_as)" "$(cat <<EOF
{"version":1,
 "filesystem_policy":{"read_only":[$SYSTEM_RO],
                      "read_write":[$SYSTEM_RW,"$WORK/run","$WORK/home","/tmp"],
                      "include_workdir":true},
 "landlock":{"compatibility":"hard_requirement"},
 "process":{"run_as_user":"1000","run_as_group":"1000"},
 "strict_sandbox":true,
 "workdirs":["$WORK/workdir"],"sentry":{"enabled":false}}
EOF
)" yes

# A filesystem-policy workspace WITH the sentry, idled. This is the only
# configuration that can answer "does Bromure's own housekeeping look like an
# agent?", because it needs a real boot, real status loops and a real sentry.
# Every real OpenShell template grants the workspace user's home read-write; a
# policy that does not is one where the shell cannot read its own profile, which
# is the user's choice and not Bromure's noise.
HOME_REAL=$(getent passwd "$(id -un)" | cut -d: -f6)
# Lockdown refuses unsigned modules at `integrity` and above, and it is one-way
# for the life of the boot. SKIPPED LOUDLY rather than failed: the code is fine,
# the VM cannot run the check. Never quietly, because a skip that reads as a pass
# is the failure this project keeps paying for.
LOCKDOWN_NOW=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/security/lockdown 2>/dev/null)
if [ -n "$LOCKDOWN_NOW" ] && [ "$LOCKDOWN_NOW" != "none" ]; then
    say "landlock + sentry, idled"
    printf '  SKIP this VM is at lockdown=%s, which refuses unsigned modules.\n' \
        "$LOCKDOWN_NOW"
    printf '       The idle-noise assertion needs a fresh VM. NOT A PASS.\n'
    skipped_cases=$((skipped_cases + 1))
elif [ -r "$ROOT/sentry/Makefile" ]; then
    WITH_SENTRY=1 run_case "landlock + sentry, idled for ${IDLE_SECONDS}s" "$(cat <<EOF
{"version":1,
 "filesystem_policy":{"read_only":[$SYSTEM_RO],
                      "read_write":[$SYSTEM_RW,"$WORK/run","$WORK/home","/tmp",
                                    "$HOME_REAL"],
                      "include_workdir":true},
 "landlock":{"compatibility":"best_effort"},"process":null,
 "network_policies":[{"host":"example.com"}],
 "workdirs":["$WORK/workdir"],"sentry":{"enabled":true}}
EOF
)" yes
    sudo rmmod bromure_sentry 2>/dev/null
else
    say "landlock + sentry, idled"
    printf '  SKIP no sentry source tree\n'
fi

# Strict, and nothing else. The host stages the strict marker and NO
# `openshell-sandbox.json`, because no section is configured and the sentry is
# off -- so no supervisor runs, which is correct. Round 9's `sandbox_gate()`
# nevertheless waited for one, and every exec answered
# `rc 75, sandbox unavailable ... (still starting)` forever. This is the plain
# Phase-4 strict sandbox that predates all of this work, and it was dead on every
# boot until round 15.
export EXPECT_NO_SUPERVISOR=1
NO_ADVISOR=1 run_case "strict only (revocation, no spec, no advisor)" "NONE" no

# And the shape that exposed the advisor's own trigger: an OpenShell policy whose
# rules are ALL network rules. The host stages no spec -- there is nothing for a
# supervisor to enforce -- but it is still an OpenShell-policy workspace, the
# advisor still serves it, and keying the mapping off the spec left exactly these
# workspaces unable to reach policy.local.
run_case "strict + network-only policy (advisor.json, no spec)" "NONE" no
unset EXPECT_NO_SUPERVISOR

# The configuration that shipped broken. The workdir is a REAL virtiofs mount --
# the same driver the host's shared folders use -- because every wrong conclusion
# in this round came from reasoning about virtiofs instead of measuring it: it
# cannot be idmapped (mount_setattr returns EINVAL), and it does not enforce the
# guest's DAC, so a share that stats as uid 1000 mode 0755 is nonetheless
# writable by uid 999. A tmpfs stand-in would have supported idmapping and hidden
# both facts.
VIRTIOFS_WORKDIR=""
for candidate in /mnt/bromure-outbox /mnt/bromure-share-1; do
    if [ "$(findmnt -no FSTYPE --target "$candidate" 2>/dev/null)" = virtiofs ] \
       && [ -w "$candidate" ]; then
        VIRTIOFS_WORKDIR="$candidate/.bromure-boottest-$$"
        break
    fi
done
if [ -n "$VIRTIOFS_WORKDIR" ]; then
    mkdir -p "$VIRTIOFS_WORKDIR"
    printf 'from the host\n' > "$VIRTIOFS_WORKDIR/host.txt"
    RUNAS_UID=$(getent passwd sandbox | cut -d: -f3)
    if [ -z "$RUNAS_UID" ]; then
        # The supervisor creates it on first use; do one throwaway launch so the
        # assertions below have a uid to check against.
        sudo useradd --system --no-create-home --shell /bin/bash --user-group \
            sandbox 2>/dev/null
        RUNAS_UID=$(getent passwd sandbox | cut -d: -f3)
    fi
    export WORKDIR_UNDER_TEST="$VIRTIOFS_WORKDIR"
    export EXPECT_BASELINE=1
    # The real OpenShell template grants the workspace user's home read-write, and
    # HOME can only be there if the ruleset covers it -- so this grants it too.
    # Without it the supervisor correctly declines to put HOME there and falls back
    # to a home of the run_as user's own, which the unit suite covers separately.
    HOME_UNDER_TEST=$(getent passwd "$(id -un)" | cut -d: -f6)
    run_case "strict + run_as_user: sandbox, on a real virtiofs workdir" "$(cat <<EOF
{"version":1,
 "filesystem_policy":{"read_only":[$SYSTEM_RO_NO_URANDOM],
                      "read_write":[$SYSTEM_RW,"$WORK/run","$WORK/home","/tmp",
                                    "$HOME_UNDER_TEST","$VIRTIOFS_WORKDIR"],
                      "include_workdir":true},
 "landlock":{"compatibility":"hard_requirement"},
 "process":{"run_as_user":"sandbox","run_as_group":"sandbox"},
 "network_policies":[{"host":"one.one.one.one"}],
 "strict_sandbox":true,
 "workdirs":["$VIRTIOFS_WORKDIR"],"sentry":{"enabled":false}}
EOF
)" yes "$RUNAS_UID"

    # And the SAME configuration with one thing removed: a policy that does not
    # grant the workspace user's home. That is the path taken on any image whose
    # /home/ubuntu is virtiofs -- where the remap is impossible -- so it can ship,
    # and until now nothing asserted it boots. The supervisor must decline to put
    # HOME there, create one of the run_as user's own, grant it, and still produce
    # a session.
    export WORKDIR_UNDER_TEST="$VIRTIOFS_WORKDIR"
    unset EXPECT_BASELINE
    export EXPECT_FALLBACK_HOME=1
    run_case "strict + run_as_user with the workspace home NOT in the policy" "$(cat <<EOF
{"version":1,
 "filesystem_policy":{"read_only":[$SYSTEM_RO],
                      "read_write":[$SYSTEM_RW,"$WORK/run","$WORK/home","/tmp",
                                    "$VIRTIOFS_WORKDIR"],
                      "include_workdir":true},
 "landlock":{"compatibility":"hard_requirement"},
 "process":{"run_as_user":"sandbox","run_as_group":"sandbox"},
 "strict_sandbox":true,
 "workdirs":["$VIRTIOFS_WORKDIR"],"sentry":{"enabled":false}}
EOF
)" yes "$RUNAS_UID"
    unset EXPECT_FALLBACK_HOME

    # And the share, end to end: what the sandbox writes must be visible outside
    # it with the ownership the host expects, and what the host wrote must be
    # readable and writable from inside.
    say "the virtiofs share, from inside the sandbox"
    if [ -f "$VIRTIOFS_WORKDIR/host.txt" ]; then
        ok "the host-created file survived the run"
    else
        bad "host.txt disappeared"
    fi
    sudo rm -rf "$VIRTIOFS_WORKDIR"
else
    say "strict + run_as_user: sandbox"
    printf '  SKIP no writable virtiofs mount in this guest to use as a workdir\n'
fi

if [ "$matched_cases" -eq 0 ]; then
    printf '\n  FAIL ONLY=%s matched no case (it is a substring match, not a regex)\n' \
        "${ONLY:-}"
    fails=$((fails + 1))
fi

if [ "$skipped_cases" -gt 0 ]; then
    printf '\n!! %d CASE(S) SKIPPED for environment reasons -- not a pass\n' \
        "$skipped_cases"
fi

if [ "$fails" -ne 0 ]; then
    printf '\n%d CHECK(S) FAILED\n' "$fails"
    exit 1
fi
if [ "$skipped_cases" -gt 0 ]; then
    # Not 0: the cases that ran passed, but one did not run, and the exit status
    # has to say so or the skip notice above is decoration.
    printf '\nTHE BOOT CASES THAT RAN PASSED -- but %d did NOT RUN (above)\n' \
        "$skipped_cases"
    exit 77
fi
printf '\nALL BOOT TESTS PASSED\n'
exit 0
