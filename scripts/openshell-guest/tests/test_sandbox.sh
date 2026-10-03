#!/usr/bin/env bash
# End-to-end test of bromure-sandboxd: a real root supervisor, a real tmux server
# behind a real Landlock ruleset and a real seccomp filter, driven against a
# throwaway meta share instead of the workspace's read-only one.
#
# Sections 1-7 cover the policy semantics. Sections 8-11 cover the two things
# review found after the first delivery, and exist because the first version of
# this suite proved the sandbox worked while missing both:
#
#   8.  the supervisor needs no sudo after the strict sandbox revokes it.
#       The original ran sandboxd with sudo directly and never crossed the
#       revocation, so it could not see that every strict workspace would get
#       no session at all.
#   9.  nothing outside the sandbox can create a tmux server on the sandbox's
#       socket -- the escape: kill-server from inside, leave a detached process
#       alive, let something outside start an unconfined replacement.
#   10. the control socket refuses a peer that is not agentd.
#   11. the supervisor does NOT resurrect the server on its own, so the existing
#       last-window-close poweroff behavior is unchanged.
#
# Run: tests/test_sandbox.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
WORK=$(mktemp -d /tmp/sandboxtest-XXXXXX)
# 0755, not mktemp's 0700. Sections 13 and 14 run things as a DIFFERENT uid, and
# that uid cannot traverse a 0700 parent -- which is the same trap that made the
# first `run_as_user` boot test fail three directories from its cause. The real
# run directory lives under /run, which every uid can traverse.
chmod 0755 "$WORK"
SUPERVISOR=""
fails=0

say() { printf '\n=== %s ===\n' "$1"; }
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

SOCK="$WORK/run/server/tmux.sock"
CTL="$WORK/run/ctl.sock"

# Every `launch` in this suite now moves net.ipv4.ping_group_range, because
# sandboxd grants it to the workload's gid at startup. Saved here, before the
# first one runs, and put back on the way out -- otherwise the value section 25
# "restores" is just whatever the previous section happened to set.
# Kill every tmux server whose socket lives under a directory this suite made.
#
# `sudo find`, not `find`: the server directory is mode 0771 (root:bromure-tmux),
# so "others" may traverse it but may not LIST it -- an unprivileged find
# enumerates nothing and silently reports no sockets. Measured: the first
# version of this ran without sudo, found nothing, and left a server per run
# with its socket directory deleted out from under it.
kill_tmux_under() {
    local dir="$1"
    [ -n "$dir" ] || return 0
    for sock in $(sudo find "$dir" -name 'tmux.sock' 2>/dev/null); do
        sudo tmux -S "$sock" kill-server 2>/dev/null
    done
}

PING_RANGE=/proc/sys/net/ipv4/ping_group_range
PING_SAVED=$(cat "$PING_RANGE" 2>/dev/null || echo "1	0")

cleanup() {
    [ -n "$SUPERVISOR" ] && sudo kill "$SUPERVISOR" 2>/dev/null
    # EVERY socket under $WORK, not just $SOCK. Sections that use a second run
    # directory (`run15/` for the run_as_user case) left their server running
    # with its socket directory deleted under it -- one survivor per run, which
    # is how this VM accumulated 39 of them.
    kill_tmux_under "$WORK"
    # LAST, after the supervisor is dead -- the same ordering bug that was in
    # test_boot.sh. Restoring first lets a sandboxd that is still running grant
    # the range again after the restore, and a full suite run ended at
    # `1000 1000` with the restore here at the top. Stop the writer, then
    # restore the state.
    for pid in $(pgrep -f "python3 $ROOT/bromure-sandboxd" 2>/dev/null); do
        sudo kill "$pid" 2>/dev/null
    done
    sudo sh -c "printf '%s' '$PING_SAVED' > $PING_RANGE" 2>/dev/null
    sudo rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/meta" "$WORK/run" "$WORK/scratch" "$WORK/allowed" "$WORK/denied" "$WORK/workdir"
echo "allowed-content"  > "$WORK/allowed/file"
echo "denied-content"   > "$WORK/denied/file"
echo "workdir-content"  > "$WORK/workdir/file"

# A usable runtime, listed explicitly the way a real OpenShell policy lists it
# (see EMPTY_NETWORK_POLICY in openshell/policy_behavior.rs). Bromure adds none
# of this; a policy that omits it is a policy that cannot exec.
#
# NOTE /dev/null is READ-WRITE, not read-only. The tmux server opens it O_RDWR
# while daemonizing, so a policy that lists it under read_only starts no session
# at all.
#
# Landlock is ADDITIVE, not most-specific-wins: a read_write rule on a parent
# grants write to everything beneath it, including a subtree separately listed
# as read_only. (Verified against OpenShell's own crates in differential/diff.py,
# case "read_only nested inside a read_write parent".) So this suite must never
# put a broad writable path above its fixtures -- an earlier version listed /tmp
# as read_write and every "denied" assertion silently passed through it.
# The agent's HOME is granted, because a real workspace grants it: sandboxd
# adds `run_as_home` to every launch (see note_addition in bromure-sandboxd).
# Without it `git init` dies rc=128 -- measured, from outside the pane:
#
#   warning: unable to access '/home/ubuntu/.gitconfig': Permission denied
#   fatal: unknown error occurred while reading the configuration files
#
# which is not a sandbox finding at all, it is this fixture granting less than
# production does. Section 12's plant step was hiding that behind a 2>/dev/null
# and reporting "planted" with no repository; the host measured `git init`
# working fine in a real strict workspace.
SYSTEM_RO='"/usr","/bin","/lib","/etc","/proc","/dev/urandom","/dev/tty","'"$HOME"'"'
SYSTEM_RW='"/dev/null"'

full_spec() {
    # full_spec <compatibility> <process-json> <extra-json-fragment>
    cat <<EOF
{"version":1,
 "filesystem_policy":{"read_only":[$SYSTEM_RO,"$WORK/allowed"],
                      "read_write":[$SYSTEM_RW,"$WORK/scratch"],
                      "include_workdir":true},
 "landlock":{"compatibility":"$1"},
 "process":$2,
 $3
 "workdirs":["$WORK/workdir"],"sentry":{"enabled":false}}
EOF
}

# One-shot: start the server, publish status, exit. For the policy-semantics
# sections, where a long-lived supervisor would just be something to clean up.
launch() {
    printf '%s' "$1" > "$WORK/meta/openshell-sandbox.json"
    sudo rm -f "$WORK/run/status.json"
    sudo env BROMURE_META="$WORK/meta" BROMURE_RUN_DIR="$WORK/run" \
        BROMURE_STRICT_DONE="$WORK/scratch/strict.done" \
        BROMURE_SANDBOXD_ONESHOT=1 BROMURE_AGENTD_PID="$$" \
        /usr/bin/python3 "$ROOT/bromure-sandboxd" 2>"$WORK/launch.log"
}

# Persistent: the real thing, serving the control socket. For sections 8-11.
start_supervisor() {
    printf '%s' "$1" > "$WORK/meta/openshell-sandbox.json"
    sudo rm -f "$WORK/run/status.json"
    sudo env BROMURE_META="$WORK/meta" BROMURE_RUN_DIR="$WORK/run" \
        BROMURE_STRICT_DONE="$WORK/scratch/strict.done" \
        BROMURE_AGENTD_PID="$$" BROMURE_SANDBOXD_NO_POWEROFF=1 \
        /usr/bin/python3 "$ROOT/bromure-sandboxd" > "$WORK/sup.log" 2>&1 &
    SUPERVISOR=$!
    for _ in $(seq 1 120); do [ -S "$CTL" ] && break; sleep 0.1; done
    # And for the initial server, not just the socket: the supervisor publishes
    # ctl.sock before that start has necessarily finished, and a test that races
    # it reports a failure that is only a race.
    for _ in $(seq 1 120); do
        tmux -S "$SOCK" has-session -t bromure 2>/dev/null && break
        sleep 0.1
    done
    [ -S "$CTL" ]
}

stop_supervisor() {
    [ -n "$SUPERVISOR" ] && sudo kill "$SUPERVISOR" 2>/dev/null
    SUPERVISOR=""
}

ctl() {
    # ctl <op> -> the supervisor's JSON reply
    python3 - "$1" <<PY
import json, socket, sys
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
c.settimeout(25)
c.connect("$CTL")
c.sendall((json.dumps({"op": sys.argv[1]}) + "\n").encode())
print(c.recv(65536).decode().strip())
PY
}

status_field() { python3 -c "
import json,sys
print(json.load(open('$WORK/run/status.json')).get(sys.argv[1]))" "$1" 2>/dev/null; }

# Probes run inside a pane are written to a script file and invoked by path.
# Inlining them into `tmux new-window "sh -c '...'"` means three levels of
# quoting, and a probe that dies on a quoting mistake looks exactly like a probe
# the sandbox blocked -- the one confusion this suite cannot afford.
in_pane() {
    local out="$WORK/scratch/pane.out"
    rm -f "$out"
    tmux -S "$SOCK" new-window -d \
        "sh -c '. $WORK/scratch/probe.sh' > $out 2>&1; echo __done__ >> $out" 2>/dev/null
    for _ in $(seq 1 60); do
        grep -q __done__ "$out" 2>/dev/null && break
        sleep 0.1
    done
    grep -v __done__ "$out" 2>/dev/null
}

probe_pane() {
    # probe_pane <name> <expected>; the script body comes from stdin.
    cat > "$WORK/scratch/probe.sh"
    check "$1" "$(in_pane)" "$2"
}

kill_server() {
    [ -S "$SOCK" ] && tmux -S "$SOCK" kill-server 2>/dev/null
    sleep 0.3
    sudo rm -f "$SOCK" "$SOCK.lock"
}

# --------------------------------------------------------------------------
say "1. no spec at all"
rm -f "$WORK/meta/openshell-sandbox.json"
sudo env BROMURE_META="$WORK/meta" BROMURE_RUN_DIR="$WORK/run" \
    BROMURE_SANDBOXD_ONESHOT=1 \
    /usr/bin/python3 "$ROOT/bromure-sandboxd" > /dev/null 2>&1
check "exits 0 and does nothing" "$?" "0"
[ -f "$WORK/run/status.json" ] && bad "wrote a status with no spec" || ok "wrote no status"

# --------------------------------------------------------------------------
say "2. absent sections are a no-op (Bromure divergence)"
launch "$(cat <<EOF
{"version":1,"filesystem_policy":null,"landlock":null,"process":null,
 "workdirs":["$WORK/workdir"],"sentry":{"enabled":false}}
EOF
)" > /dev/null
check "filesystem" "$(status_field filesystem)" "off"
check "seccomp"    "$(status_field seccomp)" "off"
check "a server still exists" \
    "$(tmux -S "$SOCK" has-session -t bromure 2>/dev/null && echo yes || echo no)" "yes"
kill_server

# --------------------------------------------------------------------------
say "2b. a sentry-only workspace is indistinguishable from pre-sandbox"
# The shipping blocker the first end-to-end run found. A workspace that switches
# ONLY the kernel sentry on has no filesystem_policy, no process section and no
# strict sandbox -- so it must get no process layer at all. The first version
# called the enforcement with child_hardening=False, which still set
# no_new_privs and still installed the main seccomp filter, so every pane got
# NoNewPrivs 1 / Seccomp 2 and a dead sudo while status.json truthfully said
# seccomp: off. That would have hit every user who merely enabled the sentry.
launch "$(cat <<EOF
{"version":1,"filesystem_policy":null,"landlock":null,"process":null,
 "strict_sandbox":false,
 "workdirs":["$WORK/workdir"],"sentry":{"enabled":true,"requirement":"hard"}}
EOF
)" > /dev/null
check "status still says seccomp off" "$(status_field seccomp)" "off"
check "status still says filesystem off" "$(status_field filesystem)" "off"

probe_pane "pane has NO no_new_privs" "0" <<'PROBE'
awk '/^NoNewPrivs:/ {print $2}' /proc/self/status
PROBE

probe_pane "pane has NO seccomp filter" "0" <<'PROBE'
awk '/^Seccomp:/ {print $2}' /proc/self/status
PROBE

probe_pane "pane keeps its capability bounding set" "yes" <<'PROBE'
awk '/^CapBnd:/ {print ($2 == "0000000000000000" ? "no" : "yes")}' /proc/self/status
PROBE

probe_pane "sudo still works in a pane" "sudo-ok" <<'PROBE'
sudo -n true 2>&1 && echo sudo-ok || echo "sudo-broken: $(sudo -n true 2>&1 | head -1)"
PROBE

probe_pane "AF_VSOCK is NOT blocked (no seccomp at all)" "ok" <<'PROBE'
python3 -c '
import socket
socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
print("ok")
'
PROBE

# The same must hold for a command run through the supervisor's exec op, since
# host `vm exec` and agentd's git both go that way.
start_supervisor "$(cat <<EOF
{"version":1,"filesystem_policy":null,"landlock":null,"process":null,
 "strict_sandbox":false,
 "workdirs":["$WORK/workdir"],"sentry":{"enabled":true,"requirement":"hard"}}
EOF
)" > /dev/null
python3 - <<PY
import json, os, socket, sys
out_r, out_w = os.pipe()
devnull = os.open(os.devnull, os.O_RDONLY)
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
c.settimeout(30)
c.connect("$CTL")
payload = json.dumps({"op": "exec",
                      "argv": ["/bin/sh", "-c",
                               "awk '/^NoNewPrivs:|^Seccomp:/ {print \$1 \$2}' /proc/self/status"],
                      "cwd": None, "env": {}, "pty": False}).encode()
socket.send_fds(c, [payload], [devnull, out_w, out_w])
for fd in (out_w, devnull):
    os.close(fd)
c.recv(65536)
c.close()
chunks = []
while True:
    b = os.read(out_r, 65536)
    if not b:
        break
    chunks.append(b)
os.close(out_r)
text = b"".join(chunks).decode().strip()
good = "NoNewPrivs:0" in text and "Seccomp:0" in text
print("  %s an exec-op child is unconfined too (%s)"
      % ("ok  " if good else "FAIL", text.replace("\n", " ")))
sys.exit(0 if good else 1)
PY
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s (see stderr)\n" "$rc"; }
stop_supervisor
kill_server

# --------------------------------------------------------------------------
say "3. Landlock WITHOUT strict: enforced, but no process layer"
# The middle configuration, and the one neither §2b (sentry only) nor §4 (strict)
# covers: a filesystem_policy with no process section and no strict sandbox. It
# has to enforce the ruleset AND leave sudo alone, which is only possible because
# `restrict_self` runs while still root -- the kernel wants nnp OR CAP_SYS_ADMIN,
# and nnp is exactly what must not be set here.
launch "$(full_spec hard_requirement null '')" > /dev/null
check "launcher exit" "$?" "0"
check "filesystem" "$(status_field filesystem)" "enforced"
check "landlock_abi" "$(status_field landlock_abi)" "4"
check "tmux_socket" "$(status_field tmux_socket)" "$SOCK"
check "server_restarts starts at 0" "$(status_field server_restarts)" "0"

probe_pane "pane reads an allowed path" "allowed-content" <<PROBE
cat $WORK/allowed/file
PROBE

probe_pane "pane reads the workdir (include_workdir)" "workdir-content" <<PROBE
cat $WORK/workdir/file
PROBE

probe_pane "pane cannot read a path outside the policy" "denied" <<PROBE
cat $WORK/denied/file 2>&1 | grep -q "Permission denied" && echo denied || echo LEAKED
PROBE

probe_pane "pane cannot write a read_only path" "denied" <<PROBE
{ echo x > $WORK/allowed/newfile ; } 2>&1 | grep -q "Permission denied" && echo denied || echo WROTE
PROBE

probe_pane "pane can write the workdir" "wrote" <<PROBE
echo y > $WORK/workdir/w && echo wrote
PROBE

probe_pane "pane cannot truncate a read_only file" "denied" <<PROBE
python3 -c "
import os
try:
    os.truncate('$WORK/allowed/file', 0)
    print('TRUNCATED')
except PermissionError:
    print('denied')
"
PROBE

probe_pane "pane cannot write the control socket's directory" "denied" <<PROBE
{ echo x > $WORK/run/escape ; } 2>&1 | grep -q "Permission denied" && echo denied || echo WROTE
PROBE

probe_pane "no no_new_privs (so sudo survives)" "0" <<'PROBE'
awk '/^NoNewPrivs:/ {print $2}' /proc/self/status
PROBE

probe_pane "no seccomp filter" "0" <<'PROBE'
awk '/^Seccomp:/ {print $2}' /proc/self/status
PROBE

probe_pane "sudo still works" "sudo-ok" <<'PROBE'
sudo -n true 2>&1 && echo sudo-ok || echo "sudo-broken: $(sudo -n true 2>&1 | head -1)"
PROBE

# Landlock holds even against that surviving root -- measured in DESIGN.md §1.7,
# asserted here so it stays true.
probe_pane "Landlock holds against root" "denied" <<'PROBE'
sudo -n sh -c 'echo x > /etc/landlock-probe' 2>&1     | grep -q "Permission denied" && echo denied || echo LEAKED
PROBE

probe_pane "mount is denied even as root (Landlock, not DAC)" "denied" <<'PROBE'
sudo -n mount -t tmpfs tmpfs /mnt 2>&1     | grep -qiE "permission denied|operation not permitted" && echo denied || echo MOUNTED
PROBE

check "additions include the meta share" \
    "$(python3 -c "
import json;print('$WORK/meta' in json.load(open('$WORK/run/status.json'))['additions']['read_only'])")" \
    "True"
check "additions include /run/utmp" \
    "$(python3 -c "
import json;print('/run/utmp' in json.load(open('$WORK/run/status.json'))['additions']['read_write'])")" \
    "True"
probe_pane "login records work (no utempter noise in this mode)" "recorded" <<'PROBE'
who 2>/dev/null | grep -q . && echo recorded || echo empty
PROBE
kill_server

# --------------------------------------------------------------------------
say "4. seccomp + supervisor protection (with strict sandbox)"
touch "$WORK/scratch/strict.done"
launch "$(full_spec best_effort '{"run_as_user":"ubuntu"}' '"strict_sandbox":true,')" > /dev/null
check "seccomp" "$(status_field seccomp)" "enforced"
check "run_as uid" "$(python3 -c "
import json;print(json.load(open('$WORK/run/status.json'))['run_as']['uid'])")" "$(id -u)"

probe_pane "AF_VSOCK is blocked in a pane" "EPERM" <<'PROBE'
python3 -c '
import socket, errno
try:
    socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    print("ALLOWED")
except OSError as exc:
    print(errno.errorcode.get(exc.errno, exc.errno))
'
PROBE

probe_pane "AF_INET still works in a pane" "ok" <<'PROBE'
python3 -c '
import socket
socket.socket(socket.AF_INET, socket.SOCK_STREAM)
print("ok")
'
PROBE

probe_pane "ptrace is blocked in a pane" "EPERM" <<'PROBE'
python3 -c '
import ctypes, errno
libc = ctypes.CDLL("libc.so.6", use_errno=True)
ctypes.set_errno(0)
libc.syscall(117, 0, 0, 0, 0)
print(errno.errorcode.get(ctypes.get_errno()))
'
PROBE

probe_pane "no_new_privs is set in a pane" "1" <<'PROBE'
awk '/^NoNewPrivs:/ {print $2}' /proc/self/status
PROBE

probe_pane "capability bounding set is empty in a pane" "0000000000000000" <<'PROBE'
awk '/^CapBnd:/ {print $2}' /proc/self/status
PROBE

probe_pane "setuid is blocked in a pane" "EPERM" <<'PROBE'
python3 -c '
import ctypes, errno
libc = ctypes.CDLL("libc.so.6", use_errno=True)
ctypes.set_errno(0)
libc.syscall(146, 0)
print(errno.errorcode.get(ctypes.get_errno()))
'
PROBE

probe_pane "the pane holds the bromure-tmux group" "yes" <<'PROBE'
id -Gn | tr ' ' '\n' | grep -qx bromure-tmux && echo yes || echo no
PROBE

# Job control must still work: this is the whole reason the child filter's
# blanket kill(0) / kill(<negative>) rule was narrowed.
probe_pane "killpg on the pane's own group works" "killpg-ok" <<'PROBE'
python3 -c '
import os, signal, time
pid = os.fork()
if pid == 0:
    os.setpgid(0, 0)
    time.sleep(30)
    os._exit(0)
time.sleep(0.2)
os.killpg(os.getpgid(pid), signal.SIGKILL)
os.waitpid(pid, 0)
print("killpg-ok")
'
PROBE

probe_pane "kill(-1) is blocked in a pane" "EPERM" <<'PROBE'
python3 -c '
import ctypes, errno
libc = ctypes.CDLL("libc.so.6", use_errno=True)
ctypes.set_errno(0)
libc.syscall(129, -1, 0)
print(errno.errorcode.get(ctypes.get_errno()))
'
PROBE

probe_pane "clone3 returns ENOSYS (not EPERM) in a pane" "ENOSYS" <<'PROBE'
python3 -c '
import ctypes, errno
libc = ctypes.CDLL("libc.so.6", use_errno=True)
ctypes.set_errno(0)
libc.syscall(435, 0, 0)
print(errno.errorcode.get(ctypes.get_errno()))
'
PROBE
kill_server
rm -f "$WORK/scratch/strict.done"

# --------------------------------------------------------------------------
say "5. hard_requirement with a missing path fails closed"
launch "$(cat <<EOF
{"version":1,
 "filesystem_policy":{"read_only":["$WORK/does-not-exist"],"include_workdir":false},
 "landlock":{"compatibility":"hard_requirement"},
 "sentry":{"enabled":false}}
EOF
)" > /dev/null
check "launcher exit" "$?" "1"
check "filesystem" "$(status_field filesystem)" "failed"
tmux -S "$SOCK" has-session -t bromure 2>/dev/null \
    && bad "started a session anyway" || ok "started no session"

# --------------------------------------------------------------------------
say "6. best_effort with the same missing path degrades instead"
launch "$(cat <<EOF
{"version":1,
 "filesystem_policy":{"read_only":["$WORK/does-not-exist"],"include_workdir":false},
 "landlock":{"compatibility":"best_effort"},
 "sentry":{"enabled":false}}
EOF
)" > /dev/null
check "launcher exit" "$?" "0"
check "filesystem" "$(status_field filesystem)" "degraded"
[ -n "$(status_field degraded_reason)" ] && ok "carries a reason" || bad "no reason given"
kill_server

# --------------------------------------------------------------------------
say "7. the status line attestd would send"
# `pending` is not `off`. attestd connects within seconds of boot and sends the
# first status BEFORE the supervisor has published; saying `off` there put a
# misleading "no filesystem policy" row in every timeline, and if the sentry won
# the race and connected on 5841 first, the host's cross-check scored
# "connected while the guest says the sentry is off" as tampering, weight 20.
python3 - <<PY
import json, sys
sys.path.insert(0, "$ROOT")
import bromure_sandbox_status as s

pending = s.build("/nonexistent", "/nonexistent", "/nonexistent",
                  "$WORK/meta/openshell-sandbox.json")
if pending["filesystem"] != "pending" or pending["sentry"] not in ("pending", "off"):
    print("  FAIL before anything is published: filesystem=%s sentry=%s"
          % (pending["filesystem"], pending["sentry"]))
    sys.exit(1)
print("  ok   before the supervisor publishes: filesystem=pending (not off)")
if pending.get("requested") is None:
    print("  FAIL the status does not say what was requested")
    sys.exit(1)
print("  ok   and it says what the host asked for: %s"
      % json.dumps(pending["requested"], sort_keys=True))

status = s.build("$WORK/run/status.json", "$WORK/run/sentry.json")
required = {"event", "landlock_abi", "filesystem", "degraded_reason", "run_as",
            "seccomp", "additions", "sentry", "sentry_digest"}
missing = required - set(status)
print("  %s status line has every contracted field%s"
      % ("ok  " if not missing else "FAIL", "" if not missing else ": missing %s" % missing))
sys.exit(1 if missing else 0)
PY
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s (see stderr)\n" "$rc"; }

# ==========================================================================
# What review found after the first delivery.
# ==========================================================================

say "8. no sudo is needed once the strict sandbox has revoked it"
touch "$WORK/scratch/strict.done"
if start_supervisor "$(full_spec best_effort null '"strict_sandbox":true,')"; then
    ok "supervisor came up and is serving the control socket"
else
    bad "supervisor did not come up"
fi
check "a server exists" \
    "$(tmux -S "$SOCK" has-session -t bromure 2>/dev/null && echo yes || echo no)" "yes"

# From here on, everything agentd does must work with NO sudo. A stub earlier in
# PATH that always fails is a faithful stand-in for `ubuntu ALL=(ALL) !ALL`, and
# it fails loudly rather than silently.
mkdir -p "$WORK/nosudo"
printf '#!/bin/sh\necho "sudo: a password is required" >&2\nexit 1\n' > "$WORK/nosudo/sudo"
chmod +x "$WORK/nosudo/sudo"
check "the sudo stub really does refuse" \
    "$(PATH="$WORK/nosudo:$PATH" sudo -n true 2>/dev/null && echo worked || echo failed)" \
    "failed"

kill_server
reply=$(PATH="$WORK/nosudo:$PATH" ctl start 2>&1)
case "$reply" in
    *'"ok": true'*) ok "the supervisor started a server on request, with sudo unavailable" ;;
    *) bad "the supervisor refused with sudo unavailable: ${reply:-<no reply>}" ;;
esac
for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.1; done
check "the server socket appeared" \
    "$(tmux -S "$SOCK" has-session -t bromure 2>/dev/null && echo yes || echo no)" "yes"
check "server_restarts counts it" "$(status_field server_restarts)" "1"

# --------------------------------------------------------------------------
say "9. nothing outside the sandbox can create a server on that socket"
# The escape: kill the server from inside the sandbox, leave a detached process
# alive, and let something OUTSIDE start an unconfined replacement on the same
# socket for the survivor to send-keys into.
cat > "$WORK/scratch/probe.sh" <<'PROBE'
setsid sh -c 'sleep 120' < /dev/null > /dev/null 2>&1 &
echo survivor=$!
PROBE
survivor=$(in_pane | sed -n 's/^survivor=//p')
if [ -n "$survivor" ]; then
    ok "a detached process survives inside the sandbox (pid $survivor)"
else
    bad "could not create a survivor"
fi

tmux -S "$SOCK" kill-server 2>/dev/null
sleep 0.5
check "the server is gone" \
    "$(tmux -S "$SOCK" has-session -t bromure 2>/dev/null && echo up || echo down)" "down"

# As the workspace user WITHOUT the bromure-tmux group -- i.e. as agentd, or as
# anything else outside the sandbox.
out=$(sudo setpriv --reuid="$(id -u)" --regid="$(id -g)" --clear-groups \
      sh -c "cd /tmp && tmux -S '$SOCK' new-session -d -s escape 2>&1")
case "$out" in
    *"Permission denied"*|*"Address already in use"*|*"error creating"*)
        ok "creating a server there is refused: $(echo "$out" | head -1)" ;;
    *) bad "an UNSANDBOXED server was created: ${out:-<no error>}" ;;
esac
check "no session exists after that attempt" \
    "$(sudo setpriv --reuid="$(id -u)" --regid="$(id -g)" --clear-groups \
        tmux -S "$SOCK" has-session -t escape 2>/dev/null && echo up || echo down)" "down"
check "the socket directory is still root:bromure-tmux 0771" \
    "$(stat -c '%U:%G %a' "$WORK/run/server")" "root:bromure-tmux 771"
check "the run directory is still root-owned and unwritable" \
    "$(stat -c '%U:%G %a' "$WORK/run")" "root:root 755"
kill "$survivor" 2>/dev/null

# --------------------------------------------------------------------------
say "10. the control socket refuses a peer inside the sandbox"
# The peer check is identified by CGROUP, not by a pinned pid. An earlier version
# pinned agentd's pid at supervisor start, which meant that after agentd was
# killed and systemd restarted it, every legitimate request was refused and the
# workspace stayed broken until the VM restarted -- an availability bug worse
# than the thing the check was for.
#
# So the threat to test is a peer INSIDE the sandbox, not merely one that is not
# a descendant of agentd.
#
# Section 9 left the server dead on purpose; the panes below need one.
ctl start > /dev/null
for _ in $(seq 1 100); do
    tmux -S "$SOCK" has-session -t bromure 2>/dev/null && break
    sleep 0.1
done
check "a server is available for the pane probes" \
    "$(tmux -S "$SOCK" has-session -t bromure 2>/dev/null && echo yes || echo no)" "yes"

cat > "$WORK/scratch/probe.sh" <<PROBE
python3 -c '
import json, socket
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
c.settimeout(10)
try:
    c.connect("$CTL")
    c.sendall(b"{\"op\":\"start\"}\n")
    print(c.recv(65536).decode().strip())
except OSError as exc:
    print("connect-failed:%s" % exc)
'
PROBE
out=$(in_pane)
case "$out" in
    *'"ok": false'*|*'"ok":false'*|*connect-failed*)
        ok "a peer inside the sandbox is refused: $(echo "$out" | head -c 110)" ;;
    *) bad "a sandboxed peer was allowed to drive the supervisor: $out" ;;
esac
check "the sandboxed tree is in its own cgroup" \
    "$(python3 -c "
import json
s = json.load(open('$WORK/run/status.json'))
print('yes' if s.get('sandbox_cgroup') else 'no')")" "yes"

# And agentd itself -- a different cgroup -- is still allowed, which is the half
# the pinned-pid version broke.
reply=$(ctl status)
case "$reply" in
    *'"ok": true'*) ok "agentd (outside the sandbox cgroup) is still allowed" ;;
    *) bad "agentd was refused: $reply" ;;
esac

# --------------------------------------------------------------------------
say "10b. the sandbox cannot signal agentd or the supervisor"
# Landlock only scopes signals from ABI 6 (kernel 6.12); this kernel is ABI 4,
# so the seccomp child filter is the only thing that narrows them. `tkill` is
# denied OUTRIGHT because it takes a TID, not a TGID -- agentd is multi-threaded
# and SIGKILL to any one of its threads kills the whole group, so the
# supervisor-TGID rule could not see it.
cat > "$WORK/scratch/probe.sh" <<PROBE
python3 -c '
import ctypes, errno, os
libc = ctypes.CDLL("libc.so.6", use_errno=True)
def sc(nr, *a):
    ctypes.set_errno(0)
    libc.syscall(ctypes.c_long(nr), *[ctypes.c_long(x) for x in a])
    return errno.errorcode.get(ctypes.get_errno(), "ok")
AGENTD = $$
print("kill_agentd=%s" % sc(129, AGENTD, 0))
print("tgkill_agentd=%s" % sc(131, AGENTD, AGENTD, 0))
print("tkill_any=%s" % sc(130, AGENTD, 0))
print("kill_minus1=%s" % sc(129, -1, 0))
print("ptrace_agentd=%s" % sc(117, 16, AGENTD, 0, 0))
try:
    open("/proc/%d/mem" % AGENTD, "rb").read(1); print("proc_mem=READABLE")
except OSError as e:
    print("proc_mem=%s" % errno.errorcode.get(e.errno, e.errno))
'
PROBE
out=$(in_pane)
printf '  info %s\n' "$(echo "$out" | tr '\n' ' ')"
for expect in "kill_agentd=EPERM" "tgkill_agentd=EPERM" "tkill_any=EPERM" \
              "kill_minus1=EPERM" "ptrace_agentd=EPERM" "proc_mem=EACCES"; do
    if echo "$out" | grep -qx "$expect"; then
        ok "$expect"
    else
        bad "$expect (got: $(echo "$out" | grep "^${expect%%=*}=" || echo missing))"
    fi
done

# --------------------------------------------------------------------------
say "11. the supervisor does not resurrect the server on its own"
# Today's product behavior: the user closing their last window ends the session
# and session_monitor powers the VM off. An auto-restarting supervisor would
# break that, and could not tell it apart from `kill-server` anyway.
ctl start > /dev/null
for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.1; done
sleep 2.5    # past START_MIN_INTERVAL, so a restart would have been possible
before=$(status_field server_restarts)
tmux -S "$SOCK" kill-server 2>/dev/null
sleep 3
check "no server came back" \
    "$(tmux -S "$SOCK" has-session -t bromure 2>/dev/null && echo yes || echo no)" "no"
check "server_restarts did not move" "$(status_field server_restarts)" "$before"

# --------------------------------------------------------------------------
say "11b. a fatal misconfiguration reports itself instead of dying"
# The supervisor used to exit non-zero on an unusable spec. Under
# `Restart=always` that burns systemd's start limit within five attempts, and
# the unit is then dead for the rest of the boot AND blocks its own name -- so
# agentd waited out its full timeout for a control socket that would never
# appear, and the host was told nothing. Measured as
# `bromure-sandboxd.service: start-limit-hit`.
stop_supervisor
sleep 0.5
sudo rm -rf "$WORK/run"
mkdir -p "$WORK/run"
printf 'this is not json' > "$WORK/meta/openshell-sandbox.json"
sudo env BROMURE_META="$WORK/meta" BROMURE_RUN_DIR="$WORK/run" \
    BROMURE_STRICT_DONE="$WORK/scratch/strict.done" BROMURE_AGENTD_PID="$$" \
    BROMURE_SANDBOXD_NO_POWEROFF=1 \
    /usr/bin/python3 "$ROOT/bromure-sandboxd" > "$WORK/sup-bad.log" 2>&1 &
SUPERVISOR=$!
for _ in $(seq 1 100); do [ -S "$CTL" ] && break; sleep 0.1; done
check "it still opens the control socket" \
    "$([ -S "$CTL" ] && echo yes || echo no)" "yes"
check "the socket is not world-accessible" \
    "$(stat -c %a "$CTL" 2>/dev/null)" "660"
reply=$(ctl status 2>&1)
case "$reply" in
    *'"ok": false'*) ok "it answers with the reason: $(echo "$reply" | head -c 100)" ;;
    *) bad "no failure reason from the degraded supervisor: $reply" ;;
esac
check "it is still running (not exited, so systemd never restart-loops)" \
    "$(kill -0 "$SUPERVISOR" 2>/dev/null && echo yes || echo no)" "yes"
stop_supervisor

# --------------------------------------------------------------------------
say "12. agentd does not execute workspace content unconfined"
# The confused-deputy family: the sandbox confines the agent, but agentd is
# unconfined and then runs things the agent controls THROUGH FILES --
# ~/.bashrc via `bash -l`, and repository config via `git -C <workdir>`
# (core.fsmonitor, hooks, filters). Each would run the agent's code outside the
# ruleset.
#
# The marker is a path the POLICY DENIES, so only a process outside Landlock can
# create it. Its existence is the escape; its absence is the proof.
MARKER="$WORK/denied/pwned"
sudo rm -f "$MARKER"
sudo rm -rf "$WORK/run"
mkdir -p "$WORK/run"
start_supervisor "$(full_spec best_effort null '"strict_sandbox":true,')" > /dev/null

ctl start > /dev/null
for _ in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.1; done

# The agent, from inside the sandbox, plants both payloads.
cat > "$WORK/scratch/probe.sh" <<PROBE
mkdir -p $WORK/workdir/repo
cd $WORK/workdir/repo
git init -q . 2>/dev/null
printf 'echo pwned-by-bashrc > $MARKER\n' >> $WORK/workdir/bashrc-payload
git config core.fsmonitor "sh -c 'echo pwned-by-fsmonitor > $MARKER'" 2>/dev/null
mkdir -p .git/hooks
printf '#!/bin/sh\necho pwned-by-hook > $MARKER\n' > .git/hooks/post-checkout
chmod +x .git/hooks/post-checkout 2>/dev/null
# "planted" only if there is a REAL repo. `git init`'s failure used to be
# swallowed by 2>/dev/null, and `mkdir -p .git/hooks` then fabricated a .git
# directory -- so this step reported success while leaving no repository, and
# the only symptom was the unconfined control failing later with "not a git
# repository", eighty lines away from the cause. It had been green for rounds.
#
# WHY the repo is not created is still open, and three attempts to instrument it
# from in here all failed, each differently: /tmp is not in the policy, a file
# under $WORK/scratch came back empty, and a `$( )` in this heredoc runs on the
# HOST at write time because the heredoc is deliberately unquoted so $WORK
# expands. Diagnose it from outside the pane instead of from inside it.
if [ -f .git/HEAD ]; then
    echo planted
else
    echo NO-REPO
fi
PROBE
check "the agent can plant its payloads inside the sandbox" "$(in_pane)" "planted"

# Now agentd runs the very commands those payloads target. _ws_run is what
# agentd uses for all of them.
python3 - <<PY
import os, sys
sys.path.insert(0, "$ROOT")
import json, socket, subprocess, threading

SANDBOX = json.load(open("$WORK/run/status.json"))
CTL = SANDBOX["control_socket"]

def ws_run(argv, cwd=None):
    """The same shape as agentd's _ws_run: hand it to the supervisor."""
    out_r, out_w = os.pipe()
    err_r, err_w = os.pipe()
    devnull = os.open(os.devnull, os.O_RDONLY)
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(30)
    c.connect(CTL)
    payload = json.dumps({"op": "exec", "argv": argv, "cwd": cwd,
                          "env": {}, "pty": False}).encode()
    socket.send_fds(c, [payload], [devnull, out_w, err_w])
    for fd in (out_w, err_w, devnull):
        os.close(fd)
    data = c.recv(65536)
    c.close()
    for fd in (out_r, err_r):
        os.close(fd)
    return json.loads(data.decode().strip() or "{}")

repo = "$WORK/workdir/repo"
ws_run(["git", "-C", repo, "status", "--porcelain"])
ws_run(["git", "-C", repo, "rev-parse", "--abbrev-ref", "HEAD"])
ws_run(["bash", "-lc", "true"])
ws_run(["bash", "-li"], cwd=repo)
PY

if [ -e "$MARKER" ]; then
    bad "workspace content executed outside the sandbox: $(cat "$MARKER" 2>/dev/null)"
else
    ok "git and a login shell ran without escaping ($(basename "$MARKER") absent)"
fi

# And the same commands run unconfined WOULD have created it -- otherwise this
# section proves nothing at all.
sudo rm -f "$MARKER"
( cd "$WORK/workdir/repo" && git -c core.fsmonitor="sh -c 'echo proof > $MARKER'" \
    status --porcelain > /tmp/fsmon-control.log 2>&1 )
if [ -e "$MARKER" ]; then
    ok "the same payload DOES fire when git is run unconfined (the test is real)"
else
    # Say WHY, not just that it failed. "This section proves nothing" sends the
    # next reader looking at the sandbox when the cause is usually the
    # control's own setup -- a missing repo, an unwritable marker directory, or
    # a git that declined the hook. Verified separately that the payload does
    # fire in a fresh repo on this image, in every variation of prior-config
    # and populated-index, so the interesting information is the state here.
    bad "the unconfined control did not fire; this section proves nothing"
    printf '       repo dir:      %s\n' \
        "$([ -d "$WORK/workdir/repo" ] && echo present || echo MISSING)"
    printf '       marker parent: %s (writable: %s)\n' \
        "$(dirname "$MARKER")" \
        "$([ -w "$(dirname "$MARKER")" ] && echo yes || echo NO)"
    printf '       git said:      %s\n' \
        "$(tr '\n' ' ' < /tmp/fsmon-control.log 2>/dev/null | cut -c1-140)"
fi
rm -f /tmp/fsmon-control.log
sudo rm -f "$MARKER"

# Defense in depth: agentd's own git flags must neutralize it even unconfined.
python3 - <<PY
import subprocess, sys
sys.path.insert(0, "$ROOT")
FLAGS = ["-c", "core.fsmonitor=", "-c", "core.hooksPath=/dev/null",
         "-c", "protocol.file.allow=never", "-c", "core.sshCommand=/bin/false",
         "-c", "diff.external=", "-c", "credential.helper="]
subprocess.run(["git", *FLAGS, "-C", "$WORK/workdir/repo", "status", "--porcelain"],
               capture_output=True, env={"GIT_CONFIG_NOSYSTEM": "1",
                                         "GIT_TERMINAL_PROMPT": "0",
                                         "PATH": "/usr/bin:/bin", "HOME": "$WORK"})
PY
if [ -e "$MARKER" ]; then
    bad "agentd's git hardening flags did not neutralize core.fsmonitor"
else
    ok "agentd's git hardening flags neutralize it even without a sandbox"
fi

# The interactive flavor: agentd allocates the pty and keeps the master, exactly
# as pty.fork left it; only the slave crosses to the supervisor. This is the
# path a host attach and `vm exec -it` take.
python3 - <<PY
import json, os, pty, select, socket, sys, threading, time
CTL = "$CTL"
master, slave = pty.openpty()
result = {}

def run():
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(40)
    c.connect(CTL)
    payload = json.dumps({"op": "exec", "argv": ["/bin/bash", "-li"],
                          "cwd": None, "env": {"TERM": "xterm-256color"},
                          "pty": True}).encode()
    socket.send_fds(c, [payload], [slave])
    result["reply"] = c.recv(65536).decode().strip()
    c.close()

threading.Thread(target=run, daemon=True).start()
time.sleep(0.5)
os.close(slave)
os.write(master, b"id -Gn; grep NoNewPrivs /proc/self/status; tty; exit\n")
buf = b""
deadline = time.time() + 15
while time.time() < deadline:
    if not select.select([master], [], [], 0.5)[0]:
        continue
    try:
        chunk = os.read(master, 65536)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
os.close(master)
text = buf.decode("utf-8", "replace")
good = ("bromure-tmux" in text and "NoNewPrivs:\t1" in text
        and "/dev/pts/" in text)
print("  %s an interactive shell runs confined on agentd's own pty"
      % ("ok  " if good else "FAIL"))
sys.exit(0 if good else 1)
PY
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s (see stderr)\n" "$rc"; }

# Fail closed: a command _ws_run cannot route into the sandbox must RAISE and
# must not execute. Logging and running unconfined was the second wrong answer
# here; an exception is how the author of a new call site finds out on the first
# run of their own test rather than after an incident.
python3 - <<PY
import os, re, subprocess, sys, threading
src = open("$ROOT/patched/bromure-agentd.py").read()
ns = {"os": os, "subprocess": subprocess, "json": __import__("json"),
      "socket": __import__("socket"), "threading": threading,
      "log": lambda *a: None,
      "_SANDBOX": {"control_socket": "$CTL"},
      "_GIT_SAFE_FLAGS": [], "_GIT_SAFE_ENV": {}}
# _CA_TRUST_ENV and _ca_trust_for_exec are dependencies of _ws_run: it supplies
# the CA paths itself now, because a confined exec reads neither /etc/profile.d
# nor /etc/environment and proxy.env is no longer there to carry them.
m = re.search(r"\n_CA_TRUST_ENV = \{.*?\n\}", src, re.S)
exec(compile(m.group(0), "ca", "exec"), ns)
ns["_CA_TRUST_FOR_EXEC"] = None
for name in ("SandboxRoutingError", "_run_unconfined", "_harden_argv",
             "_ca_trust_for_exec", "_drain", "_ws_run", "_sandbox_exec"):
    kind = "class" if name[0].isupper() else "def"
    m = re.search(r"\n%s %s\b.*?(?=\n(?:def |class |# ---))" % (kind, name),
                  src, re.S)
    exec(compile(m.group(0), name, "exec"), ns)

witness = "$WORK/scratch/must-not-exist"
try:
    os.unlink(witness)
except OSError:
    pass
try:
    ns["_ws_run"](["/bin/sh", "-c", "touch " + witness], preexec_fn=None)
    print("  FAIL an unroutable command did not raise")
    sys.exit(1)
except ns["SandboxRoutingError"] as exc:
    if os.path.exists(witness):
        print("  FAIL it raised but the command ran anyway")
        sys.exit(1)
    print("  ok   an unsupported argument raises and does not execute")
    if "_run_unconfined" not in str(exc):
        print("  FAIL the message does not point at the escape hatch")
        sys.exit(1)
    print("  ok   the message names _run_unconfined as the explicit way out")
PY
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s (see stderr)\n" "$rc"; }
stop_supervisor

# --------------------------------------------------------------------------
say "13. run_as_user: the pieces, individually"
# The integration case lives in tests/test_boot.sh, which does a real two-boot
# run with a real virtiofs workdir. These are the units under it, because the
# `run_as_user: sandbox` round cost four rounds of guessing and every one of the
# four causes was cheap to assert once named.
sudo python3 - <<PY
import importlib.machinery, importlib.util, os, pwd, sys
loader = importlib.machinery.SourceFileLoader("sb", "$ROOT/bromure-sandboxd")
spec = importlib.util.spec_from_loader("sb", loader)
sb = importlib.util.module_from_spec(spec)
sys.argv = ["bromure-sandboxd"]
loader.exec_module(sb)

fails = 0
def ok(msg):    print("  ok   %s" % msg)
def bad(msg):
    global fails
    print("  FAIL %s" % msg); fails += 1

UID = 999
try:
    record = pwd.getpwnam("sandbox")
    UID, GID = record.pw_uid, record.pw_gid
except KeyError:
    print("  SKIP no sandbox account to test against"); sys.exit(0)

# 1. Writability is MEASURED, not inferred from the mode bits. The old version
#    inferred, and was wrong about virtiofs in the direction that produces a
#    confident false warning.
probe = "$WORK/measured"
os.makedirs(probe, exist_ok=True)
os.chmod(probe, 0o700)
os.chown(probe, 0, 0)
if sb.check_workdir_access(UID, GID, [probe]):
    ok("a root-owned 0700 directory is reported unwritable, with the errno")
else:
    bad("a root-owned 0700 directory was reported writable")
os.chmod(probe, 0o777)
if not sb.check_workdir_access(UID, GID, [probe]):
    ok("and a writable one is not reported")
else:
    bad("a 0777 directory was reported unwritable")
if any("not a directory" in r for r in sb.check_workdir_access(UID, GID, ["$WORK/nope"])):
    ok("a missing workdir says so rather than guessing")
else:
    bad("a missing workdir was not reported")

# 2. The home. Not the owner's, not the project folder, owned by the run_as uid.
home, problem = sb.ensure_run_as_home(UID, GID, "sandbox", 1000)
if problem:
    bad("ensure_run_as_home refused: %s" % problem)
elif home == pwd.getpwuid(1000).pw_dir:
    bad("the run_as home is the WORKSPACE user's home (%s)" % home)
else:
    info = os.stat(home)
    if info.st_uid == UID and (info.st_mode & 0o777) == 0o700:
        ok("the run_as home is %s, owned by uid %d, mode 0700" % (home, UID))
    else:
        bad("%s is uid %d mode %o" % (home, info.st_uid, info.st_mode & 0o777))

# 3. A host-backed parent is refused rather than chowned: those ids come from
#    the host and cannot be changed from in here.
for mount in ("/mnt/bromure-meta", "/mnt/bromure-outbox"):
    if sb.fstype_of(mount) in sb.HOST_BACKED_FSTYPES:
        ok("%s is recognised as host-backed (%s), so a home is never put there"
           % (mount, sb.fstype_of(mount)))
        break
else:
    print("  SKIP no host-backed mount in this guest")

# 4. Reachability is explained, not timed out on.
deep = "$WORK/locked/inner"
os.makedirs(deep, exist_ok=True)
os.chmod("$WORK/locked", 0o700)
os.chown("$WORK/locked", 0, 0)
why = sb.describe_reachability(UID, GID, deep)
if why and "traverse" in why:
    ok("an unreachable socket directory names the component: %s" % why)
else:
    bad("an unreachable path gave no usable reason: %r" % why)
os.chmod("$WORK/locked", 0o755)
# The caller passes the socket DIRECTORY, which tmux has to bind in, so the probe
# checks write on the leaf as well as traversal on the way down.
os.chmod(deep, 0o777)
if sb.describe_reachability(UID, GID, deep) is None:
    ok("and a reachable one reports nothing")
else:
    bad("a reachable path was reported unreachable")

# 5. The home is the workspace user's home through an idmapped mount -- but ONLY
#    when the ruleset grants it. A policy that does not cover it must fall back,
#    not hand the workload a home it cannot enter. This is the same bug as the
#    original one, in the shape it would come back in.
class FS(object):
    def __init__(self, rw, present=True, include_workdir=False):
        self.read_write, self.read_only = rw, []
        self.present, self.include_workdir = present, include_workdir
class Pol(object):
    def __init__(self, fs):
        self.filesystem = fs

owner_home = pwd.getpwuid(1000).pw_dir
granted, why = sb.policy_grants_write(Pol(FS([owner_home])), [], owner_home)
if granted:
    ok("a policy naming the workspace home grants it")
else:
    bad("a policy naming %s did not grant it: %s" % (owner_home, why))
granted, why = sb.policy_grants_write(Pol(FS(["/tmp"])), [], owner_home)
if not granted and "does not grant" in (why or ""):
    ok("a policy that does not cover it says so, so the home falls back")
else:
    bad("a policy granting only /tmp was read as granting %s" % owner_home)
granted, _ = sb.policy_grants_write(Pol(FS(["/home"])), [], owner_home)
if granted:
    ok("and a grant on a PARENT covers it, because Landlock is path-based")
else:
    bad("a grant on /home did not cover %s" % owner_home)
granted, _ = sb.policy_grants_write(Pol(FS([], present=False)), [], owner_home)
if granted:
    ok("with no filesystem policy there is no ruleset, so the question does not arise")
else:
    bad("an absent filesystem policy was treated as denying the home")

# 6. And the remap itself is probed with the code that will perform it, so the
#    answer cannot disagree with what happens in the confined child.
usable, why = sb.can_idmap(owner_home, 1000, UID, 1000, GID)
print("  info can_idmap(%s) -> %s%s" % (owner_home, usable,
                                        "" if usable else " (%s)" % why))
for mount in ("/mnt/bromure-meta", "/mnt/bromure-outbox"):
    if sb.fstype_of(mount) == "virtiofs":
        usable, why = sb.can_idmap(mount, 1000, UID, 1000, GID)
        if not usable and "idmapped mounts" in (why or ""):
            ok("virtiofs is correctly reported as not idmappable: %s" % why)
        elif usable:
            bad("virtiofs reported idmappable -- §1.12 says it is not on this kernel")
        else:
            bad("virtiofs probe failed for another reason: %s" % why)
        break

# 7. The failure message shape the whole round turned on.
try:
    with sb.stage("chdir", "/nope"):
        os.chdir("/nope")
except sb.StageError as exc:
    text = str(exc)
    if "chdir" in text and "/nope" in text and "ENOENT" in text:
        ok("a staged failure carries the operation, the path and the errno: %s" % text)
    else:
        bad("StageError text is not usable: %s" % text)
else:
    bad("stage() did not raise")

sys.exit(1 if fails else 0)
PY
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s (see stderr)\n" "$rc"; }

# --------------------------------------------------------------------------
say "14. tmux will not serve a client whose uid is not the server's"
# The fact that made `run_as_user` unusable, asserted here so a tmux upgrade that
# changes it does not silently change what Bromure has to do about it.
if ! id sandbox >/dev/null 2>&1; then
    printf '  SKIP no sandbox account\n'
else
    TD=$WORK/tmuxuid
    sudo rm -rf "$TD"; mkdir -p "$TD"; chmod 0777 "$TD"
    sudo -u sandbox env HOME=/tmp SHELL=/bin/bash \
        tmux -S "$TD/s.sock" new-session -d -s t -c /tmp 'sleep 300' 2>/dev/null
    sleep 1
    sudo chmod 0666 "$TD/s.sock" 2>/dev/null
    if sudo -u sandbox env HOME=/tmp tmux -S "$TD/s.sock" has-session -t t 2>&1 \
        | grep -q .; then
        printf '  FAIL the server did not come up for its own uid\n'
        fails=$((fails + 1))
    else
        ok "a uid-999 server answers a uid-999 client"
    fi
    OUT=$(tmux -S "$TD/s.sock" has-session -t t 2>&1)
    if printf '%s' "$OUT" | grep -q "access not allowed"; then
        ok "and REFUSES uid $(id -u), on a 0666 socket -- so permissions cannot fix it"
    else
        printf '  FAIL expected a refusal, got: %s\n' "$OUT"
        fails=$((fails + 1))
    fi
    # And the detail that made it invisible: it exits 0 anyway.
    tmux -S "$TD/s.sock" has-session -t t >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        ok "the refusal still exits 0, which is why the probe must read stderr"
    else
        ok "the refusal exits non-zero on this tmux (the stderr check is then belt-and-braces)"
    fi
    sudo -u sandbox env HOME=/tmp tmux -S "$TD/s.sock" kill-server 2>/dev/null
fi

# --------------------------------------------------------------------------
say "15. a workspace with no session says why"
# The host saw "filesystem enforced, runs as sandbox, seccomp enforced, sentry
# running" on a workspace that had no session at all, forever, with nothing
# anywhere saying the word "permission". A workspace that cannot produce a shell
# must not also be silent about it.
#
# BROMURE_SESSION_GRACE keeps this to a few seconds instead of the production
# minute. Nothing here sends `session_ready` -- that is agentd's job and there is
# no agentd -- so the diagnosis is due.
SUP15=$WORK/run15
sudo rm -rf "$SUP15"; mkdir -p "$SUP15"
printf '%s' "$(full_spec best_effort '{"run_as_user":"sandbox","run_as_group":"sandbox"}' '"strict_sandbox":true,')" \
    > "$WORK/meta/openshell-sandbox.json"
sudo setsid env BROMURE_META="$WORK/meta" BROMURE_RUN_DIR="$SUP15" \
    BROMURE_STRICT_DONE="$WORK/scratch/strict.done" BROMURE_AGENTD_PID=$$ \
    BROMURE_SANDBOXD_NO_POWEROFF=1 BROMURE_SESSION_GRACE=2 \
    /usr/bin/python3 "$ROOT/bromure-sandboxd" > "$WORK/sup15.log" 2>&1 < /dev/null &
for _ in $(seq 1 100); do [ -S "$SUP15/ctl.sock" ] && break; sleep 0.1; done
sleep 6
DIAG=$(sudo python3 -c "
import json
d = json.load(open('$SUP15/status.json'))
print(next((w for w in d.get('warnings') or [] if w.startswith('no session')), ''))" 2>/dev/null)
case "$DIAG" in
    *"no session"*"uid 999"*)
        ok "the status says why there is no session: $DIAG" ;;
    "")
        bad "no session, and no warning explaining it"
        fails=$((fails + 1)) ;;
    *)
        bad "the diagnosis does not name the workload: $DIAG"
        fails=$((fails + 1)) ;;
esac
# It must not fire once a session IS reported -- a diagnostic that cries wolf on a
# healthy workspace is one the host learns to drop.
python3 - <<PY
import json, socket
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.settimeout(10)
c.connect("$SUP15/ctl.sock")
c.sendall((json.dumps({"op": "session_ready"}) + "\n").encode())
c.recv(4096)
PY
sleep 2
STILL=$(sudo python3 -c "
import json
d = json.load(open('$SUP15/status.json'))
print('yes' if d.get('session_ready') else 'no')" 2>/dev/null)
check "session_ready is recorded once agentd reports one" "$STILL" "yes"
for pid in $(pgrep -f "python3 $ROOT/bromure-sandbox""d" 2>/dev/null); do
    sudo kill -9 "$pid" 2>/dev/null
done
sudo tmux -S "$SUP15/server/tmux.sock" kill-server 2>/dev/null

# --------------------------------------------------------------------------
say "16. the status line carries what the host needs to stop guessing"
# Two rounds were lost to questions the status line could not answer: "is the fix
# actually deployed in this guest?" and "why is there no session?". The first is
# now a field; the second was already written into status.json and never SENT,
# because `warnings` was not part of the resend fingerprint.
python3 - <<PY
import json, sys
sys.path.insert(0, "$ROOT")
import bromure_sandbox_status as s

fails = 0
def ok(m): print("  ok   %s" % m)
def bad(m):
    global fails
    print("  FAIL %s" % m); fails += 1

# A new warning must change the fingerprint, or nothing the supervisor says after
# the first frame ever reaches the host.
base = {"filesystem": "enforced", "warnings": ["a"]}
same = {"filesystem": "enforced", "warnings": ["a"]}
more = {"filesystem": "enforced", "warnings": ["a", "no session 60s after ..."]}
reordered = {"filesystem": "enforced", "warnings": ["b", "a"]}
if s.fingerprint(base) == s.fingerprint(same):
    ok("an unchanged status does not resend")
else:
    bad("an identical status changed the fingerprint")
if s.fingerprint(base) != s.fingerprint(more):
    ok("a NEW warning resends -- this is how the no-session diagnosis gets out")
else:
    bad("adding a warning did not change the fingerprint; the host would never see it")
two = {"filesystem": "enforced", "warnings": ["a", "b"]}
if s.fingerprint(two) == s.fingerprint(reordered):
    ok("but reordering does not, so warnings cannot cause a resend storm")
else:
    bad("reordering warnings changed the fingerprint")

# The build marker, and the measured writability, have to survive into the line.
st = s.build("/nonexistent", "/nonexistent", "/nonexistent")
for key in ("build", "idmap", "session_ready"):
    if key in st:
        ok("the status line carries %r" % key)
    else:
        bad("the status line drops %r" % key)
sys.exit(1 if fails else 0)
PY
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s (see stderr)\n" "$rc"; }

# And the marker must name the files actually running, not a constant.
BUILD=$(sudo python3 - <<PY
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("sb", "$ROOT/bromure-sandboxd")
spec = importlib.util.spec_from_loader("sb", loader)
sb = importlib.util.module_from_spec(spec); sys.argv = ["x"]
loader.exec_module(sb)
print(json.dumps(sb.build_marker(), sort_keys=True))
PY
)
REAL=$(sha256sum "$ROOT/bromure-sandboxd" | cut -c1-12)
if printf '%s' "$BUILD" | grep -q "$REAL"; then
    ok "the build marker is the real hash of the running supervisor ($REAL)"
else
    bad "the build marker does not match sha256(bromure-sandboxd): $BUILD vs $REAL"
fi

# --------------------------------------------------------------------------
say "17. a command the sandbox cannot run says so, with a distinct exit code"
# The failure mode that survived two rounds: `_sandbox_exec` returned None, the
# reason was dropped, and the caller got exit 127 with empty stdout AND stderr --
# indistinguishable from "command not found", for what was really EACCES on
# ctl.sock. So a refusal must carry the errno, name the socket, and use 126.
python3 - <<PY
import os, re, subprocess, sys, threading
src = open("$ROOT/patched/bromure-agentd.py").read()
ns = {"os": os, "subprocess": subprocess, "json": __import__("json"),
      "socket": __import__("socket"), "threading": threading,
      "log": lambda *a: None,
      # A socket that is not there, which is the shape of the real failure.
      "_SANDBOX": {"control_socket": "$WORK/no-such-ctl.sock"},
      "SANDBOX_CTL": "$WORK/no-such-ctl.sock",
      "_GIT_SAFE_FLAGS": [], "_GIT_SAFE_ENV": {}}
m = re.search(r"\n_CA_TRUST_ENV = \{.*?\n\}", src, re.S)
exec(compile(m.group(0), "ca", "exec"), ns)
ns["_CA_TRUST_FOR_EXEC"] = None
for name in ("SandboxRoutingError", "_run_unconfined", "_harden_argv",
             "_ca_trust_for_exec", "_sandbox_reason", "_drain", "_ws_run",
             "_sandbox_exec"):
    kind = "class" if name[0].isupper() else "def"
    m = re.search(r"\n%s %s\b.*?(?=\n(?:def |class |# ---))" % (kind, name),
                  src, re.S)
    exec(compile(m.group(0), name, "exec"), ns)
ns["SANDBOX_REFUSED_EXIT"] = int(
    re.search(r"SANDBOX_REFUSED_EXIT = (\d+)", src).group(1))

fails = 0
def ok(m): print("  ok   %s" % m)
def bad(m):
    global fails
    print("  FAIL %s" % m); fails += 1

result = ns["_ws_run"](["/bin/echo", "hi"], capture_output=True, text=True)
if result.returncode == 126:
    ok("a refusal exits 126, not 127 -- a support log can tell them apart")
else:
    bad("a refusal exited %d, expected 126" % result.returncode)
if result.stderr.startswith("bromure sandbox: "):
    ok("and stderr carries the prefix the host greps for")
else:
    bad("stderr does not carry the prefix: %r" % result.stderr)
if "no reply from the supervisor" in result.stderr and "ctl.sock" in result.stderr:
    ok("the reason names the socket: %s" % result.stderr.strip())
else:
    bad("the reason does not name the socket: %r" % result.stderr)
# The errno is the whole point: EACCES vs ENOENT is what would have named the
# real bug on sight.
if "No such file" in result.stderr or "ENOENT" in result.stderr:
    ok("and the errno, so EACCES and ENOENT are distinguishable on sight")
else:
    bad("the reason carries no errno: %r" % result.stderr)
# A refusal must never be mistaken for success.
if result.stdout == "":
    ok("and no output is invented")
else:
    bad("a refused command produced stdout %r" % result.stdout)
sys.exit(1 if fails else 0)
PY
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s (see stderr)\n" "$rc"; }

# --------------------------------------------------------------------------
say "18. DNS works under a filesystem_policy"
# DNS was dead in EVERY sandboxed workspace and nothing said so. /etc/resolv.conf
# is a symlink into /run, Landlock checks the resolved path, and a policy granting
# /etc therefore does not grant the file. Every hostname lookup failed with
# "Temporary failure in name resolution" -- which reads as a network-policy denial,
# not a filesystem one, so it pointed at the wrong layer.
sudo python3 - <<PY
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("sb", "$ROOT/bromure-sandboxd")
sb = importlib.util.module_from_spec(importlib.util.spec_from_loader("sb", loader))
sys.argv = ["x"]; loader.exec_module(sb)
sys.path.insert(0, "$ROOT")
import bromure_openshell as osh

fails = 0
def ok(m): print("  ok   %s" % m)
def bad(m):
    global fails
    print("  FAIL %s" % m); fails += 1

# The addition has to name a real path, and the DIRECTORY when resolv.conf is a
# symlink out of /etc -- granting the file breaks when the resolver rewrites it
# by rename, which it does on any DHCP renewal.
adds = sb.resolver_additions()
target = os.path.realpath("/etc/resolv.conf")
if not adds:
    bad("no resolver addition at all (realpath %s)" % target)
else:
    path, why = adds[0]
    if os.path.isdir(path) and os.path.dirname(target) == path:
        ok("the resolver addition is the DIRECTORY %s, so a rewrite cannot break it" % path)
    elif path == target:
        ok("resolv.conf is a real file here; granted by name (%s)" % path)
    else:
        bad("the resolver addition is %r, which is neither %s nor its directory"
            % (path, target))
    if "DNS resolver configuration" in why:
        ok("and it is reported as DNS resolver configuration")
    else:
        bad("the why text does not say what it is: %r" % why)

def resolves(read_only, read_write, extra_ro=()):
    """Can a landlocked child resolve a name? Returns (resolv_conf, getaddrinfo)."""
    pol = osh.SandboxPolicy.from_json({
        "filesystem_policy": {"read_only": list(read_only),
                              "read_write": list(read_write),
                              "include_workdir": False},
        "landlock": {"compatibility": "best_effort"}})
    prepared, outcome = osh.prepare(pol, workdir=None,
                                    path_open_mode=osh.PRIVILEGED,
                                    extra_read_only=list(extra_ro))
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        try:
            osh.enforce_landlock_privileged(prepared, outcome)
        except Exception as exc:
            os.write(w, ("enforce:%s" % exc).encode()); os._exit(1)
        try:
            open("/etc/resolv.conf").read(1); conf = "read"
        except OSError as exc:
            conf = exc.strerror
        import socket
        try:
            socket.getaddrinfo("one.one.one.one", 80); dns = "resolved"
        except Exception as exc:
            dns = str(exc)[:38]
        os.write(w, ("%s|%s" % (conf, dns)).encode()); os._exit(0)
    os.close(w)
    got = os.read(r, 4096).decode(); os.close(r); os.waitpid(pid, 0)
    if prepared: prepared.close()
    return got.split("|") if "|" in got else (got, got)

# OpenShell's L7 template, WITHOUT the addition: the bug, reproduced.
L7_RO = ["/usr", "/lib", "/proc", "/dev/urandom", "/etc", "/var/log"]
L7_RW = ["/tmp", "/dev/null"]
conf, dns = resolves(L7_RO, L7_RW)
if conf != "read" and "resolved" not in dns:
    ok("without the addition the bug reproduces (resolv.conf=%s, dns=%s)" % (conf, dns))
else:
    bad("expected DNS to fail without the addition, got resolv.conf=%s dns=%s"
        % (conf, dns))

# With it: DNS works.
conf, dns = resolves(L7_RO, L7_RW, [p for p, _ in adds])
if conf == "read" and dns == "resolved":
    ok("with the addition, resolv.conf is readable and a name resolves")
else:
    bad("DNS still broken WITH the addition: resolv.conf=%s dns=%s" % (conf, dns))

# And it does not secretly depend on /etc: measured, glibc's built-in NSS default
# is enough, which is why the /etc NSS files are deliberately NOT added.
conf, dns = resolves(["/usr", "/lib", "/proc"], ["/tmp", "/dev/null"],
                     [p for p, _ in adds])
if dns == "resolved":
    ok("a policy with no /etc at all still resolves, so no /etc file is added")
else:
    bad("DNS needs something under /etc after all: %s" % dns)
sys.exit(1 if fails else 0)
PY
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s (see stderr)\n" "$rc"; }

# --------------------------------------------------------------------------
say "19. OpenShell's baseline enrichment (parity)"
# OpenShell adds read-only /usr /lib /etc /app /var/log /proc /dev/urandom and
# read-write /tmp /dev/null when the policy has >= 1 network rule, for paths that
# exist and are not already listed. Its own e2e test
# `hard_requirement_accepts_enriched_device_path` depends on it. We had decided
# "no baseline"; parity with documented upstream behaviour wins.
sudo python3 - <<PY
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("sb", "$ROOT/bromure-sandboxd")
sb = importlib.util.module_from_spec(importlib.util.spec_from_loader("sb", loader))
sys.argv = ["x"]; loader.exec_module(sb)
sys.path.insert(0, "$ROOT")
import bromure_openshell as osh

fails = 0
def ok(m): print("  ok   %s" % m)
def bad(m):
    global fails
    print("  FAIL %s" % m); fails += 1

def enrich(spec_extra, ro, rw, include_workdir=False, workdirs=()):
    spec = dict({"version": 1}, **spec_extra)
    pol = osh.SandboxPolicy.from_json({
        "filesystem_policy": {"read_only": ro, "read_write": rw,
                              "include_workdir": include_workdir},
        "landlock": {"compatibility": "hard_requirement"}})
    status = {"warnings": []}
    a, b = sb.openshell_baseline_additions(spec, pol, list(workdirs), status)
    return [p for p, _ in a], [p for p, _ in b], status["warnings"]

# The verbatim landlock.rs scenario.
ro, rw, warns = enrich({"network_policies": [{"host": "example.com"}]},
                       ["/usr", "/lib", "/etc", "/proc"], ["/sandbox", "/tmp"])
if "/dev/urandom" in ro:
    ok("with a network rule, /dev/urandom is enriched in read-only")
else:
    bad("/dev/urandom was not enriched: ro=%s" % ro)
for already in ("/usr", "/lib", "/etc", "/proc"):
    if already in ro:
        bad("%s was enriched although the policy already lists it" % already)
        break
else:
    ok("and paths the policy already lists are not duplicated")
if "/tmp" not in rw:
    ok("/tmp is already listed, so it is not enriched")
else:
    bad("/tmp was enriched although the policy lists it")
if "/dev/null" in rw:
    ok("/dev/null is enriched in read-write")
else:
    bad("/dev/null was not enriched: rw=%s" % rw)

# No network rules: no enrichment at all. This is the condition, not a default.
ro, rw, warns = enrich({"network_policies": []}, ["/usr"], ["/tmp"])
if not ro and not rw:
    ok("with zero network rules there is no enrichment")
else:
    bad("enriched without a network rule: ro=%s rw=%s" % (ro, rw))
if not warns:
    ok("and an empty list is a definite answer, so nothing is warned about")
else:
    bad("an empty network_policies warned: %s" % warns)

# The host not staging them at all is DIFFERENT from zero, and must be visible.
ro, rw, warns = enrich({}, ["/usr"], ["/tmp"])
if not ro and not rw and warns and "network_policies" in warns[0]:
    ok("a spec with no network rules at all warns instead of guessing")
else:
    bad("a missing network_policies key was silently treated as zero: %s" % warns)

# A path that does not exist is never enriched.
ro, _, _ = enrich({"network_policies": [1]}, ["/usr"], ["/tmp"])
if "/app" in ro and not os.path.exists("/app"):
    bad("/app was enriched although it does not exist here")
else:
    ok("only paths that exist are enriched")

# And the whole point: hard_requirement must ACCEPT the device node.
pol = osh.SandboxPolicy.from_json({
    "filesystem_policy": {"read_only": ["/usr", "/lib", "/etc", "/proc"],
                          "read_write": ["/tmp"], "include_workdir": False},
    "landlock": {"compatibility": "hard_requirement"}})
prepared, outcome = osh.prepare(pol, workdir=None, path_open_mode=osh.PRIVILEGED,
                                extra_read_only=["/dev/urandom"],
                                extra_read_write=["/dev/null"])
if prepared is None:
    bad("hard_requirement refused the enriched policy: %s" % outcome.reason)
else:
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        try:
            osh.enforce_landlock_privileged(prepared, outcome)
            with open("/dev/urandom", "rb") as h:
                n = len(h.read(16))
            os.write(w, ("read %d" % n).encode())
        except Exception as exc:
            os.write(w, ("FAILED %s" % exc).encode())
        os._exit(0)
    os.close(w)
    got = os.read(r, 4096).decode(); os.close(r); os.waitpid(pid, 0)
    prepared.close()
    if got == "read 16":
        ok("hard_requirement accepts the device node and the workload reads it")
    else:
        bad("head -c 16 /dev/urandom under hard_requirement: %s" % got)
sys.exit(1 if fails else 0)
PY
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s (see stderr)\n" "$rc"; }

# --------------------------------------------------------------------------
say "20. the policy advisor resolves, and the CA paths reach a confined exec"
# http://policy.local used to be reachable only through the cooperative proxy.
# OpenShell-policy workspaces no longer get proxy env vars (deliberate, matches
# upstream), so the host intercepts 192.0.2.254:80 transparently and the guest
# only has to make the name resolve.
#
# BROMURE_HOSTS_FILE, not the real /etc/hosts. An earlier test in this project
# applied the strict revocation to the real /etc and took this machine's sudo with
# it; a test that edits /etc/hosts can stop the machine resolving its own name.
python3 - <<PY
import os, re, subprocess, sys, threading
src = open("$ROOT/patched/bromure-agentd.py").read()
FAKE = "$WORK/etc-hosts"
SPEC = "$WORK/meta/openshell-sandbox.json"
open(FAKE, "w").write("127.0.0.1\tlocalhost box\n127.0.1.1\tbox\n")
ADVISOR = "$WORK/meta/advisor.json"
ns = {"os": os, "subprocess": subprocess, "json": __import__("json"),
      "socket": __import__("socket"), "threading": threading,
      "log": lambda *a: None, "_DEVNULL": subprocess.DEVNULL,
      "HOSTS_FILE": FAKE, "OPENSHELL_SPEC": SPEC, "ADVISOR_CONFIG": ADVISOR,
      "_sudo": lambda *a, **k: True}
for name in ("_sudo_write", "_advisor_identity", "task_openshell_advisor_host"):
    m = re.search(r"\ndef %s\b.*?(?=\n(?:def |class |# ---|_[A-Z]))" % name, src, re.S)
    exec(compile(m.group(0), name, "exec"), ns)
for const in ("ADVISOR_HOST_DEFAULT", "ADVISOR_ADDRESS_DEFAULT",
              "ADVISOR_HOSTS_MARKER"):
    ns[const] = re.search(r'%s = "([^"]+)"' % const, src).group(1)
ns["openshell_requested"] = lambda: os.path.exists(SPEC)

fails = 0
def ok(m): print("  ok   %s" % m)
def bad(m):
    global fails
    print("  FAIL %s" % m); fails += 1

# advisor.json alone -- no spec at all. This is the case the trigger exists for:
# a policy with nothing but network rules gets no openshell-sandbox.json, and is
# still an OpenShell-policy workspace the advisor serves.
for stale in (SPEC, ADVISOR):
    if os.path.exists(stale):
        os.unlink(stale)
open(ADVISOR, "w").write('{"host":"policy.local","address":"192.0.2.254"}')
ns["task_openshell_advisor_host"]()
body = open(FAKE).read()
if body.count("policy.local") == 1 and "192.0.2.254" in body:
    ok("advisor.json alone triggers the mapping, with no spec present")
else:
    bad("advisor.json did not trigger the mapping: %r" % body)

# The spec's advisor block still works on its own, so a host that has not moved
# over yet does not lose a workspace that works today.
os.unlink(ADVISOR)
open(SPEC, "w").write(
    '{"version":1,"advisor":{"host":"policy.local","address":"192.0.2.254"}}')
ns["task_openshell_advisor_host"]()
body = open(FAKE).read()
if body.count("policy.local") == 1:
    ok("and the spec's advisor block still triggers it (no deploy ordering trap)")
else:
    bad("the spec advisor block stopped working: %r" % body)

# advisor.json wins on the values when both are present.
open(ADVISOR, "w").write('{"host":"policy.local","address":"192.0.2.99"}')
ns["task_openshell_advisor_host"]()
body = open(FAKE).read()
if "192.0.2.99\tpolicy.local" in body and "192.0.2.254" not in body:
    ok("advisor.json wins over the spec block when both are present")
else:
    bad("advisor.json did not win: %r" % body)
os.unlink(ADVISOR)

# A spec with NO advisor block and no advisor.json must leave no mapping -- this
# is the round-15 strict-only case, where a mapping would be stale state.
open(SPEC, "w").write('{"version":1}')
ns["task_openshell_advisor_host"]()
body = open(FAKE).read()
if "policy.local" not in body:
    ok("a spec with no advisor block leaves no mapping")
else:
    bad("a bare spec still wrote a mapping: %r" % body)

# Back to the baseline the rest of this block expects.
open(SPEC, "w").write(
    '{"version":1,"advisor":{"host":"policy.local","address":"192.0.2.254"}}')
ns["task_openshell_advisor_host"]()
body = open(FAKE).read()
if body.count("policy.local") == 1 and "192.0.2.254" in body:
    ok("the advisor line is added when the host says there is an advisor")
else:
    bad("hosts file is %r" % body)
if "127.0.0.1\tlocalhost box" in body and "127.0.1.1\tbox" in body:
    ok("and the existing entries are byte-identical")
else:
    bad("existing hosts entries were disturbed: %r" % body)

# Idempotent: running it again changes nothing at all.
before = body
ns["task_openshell_advisor_host"]()
ns["task_openshell_advisor_host"]()
if open(FAKE).read() == before:
    ok("running it twice more is a no-op (idempotent on every boot)")
else:
    bad("not idempotent: %r" % open(FAKE).read())

# The address comes from the host's configuration, not a constant.
open(SPEC, "w").write(
    '{"version":1,"advisor":{"host":"advisor.internal","address":"192.0.2.9"}}')
ns["task_openshell_advisor_host"]()
body = open(FAKE).read()
if "192.0.2.9\tadvisor.internal" in body and "policy.local" not in body:
    ok("a staged advisor.host/address is used, and the old line replaced")
else:
    bad("staged advisor not honoured: %r" % body)

# And it converges the OTHER way: nothing staged, no mapping left behind.
os.unlink(SPEC)
ns["task_openshell_advisor_host"]()
body = open(FAKE).read()
if "advisor.internal" not in body and "127.0.0.1\tlocalhost box" in body:
    ok("with no spec the mapping is removed, leaving no state behind")
else:
    bad("a stale mapping survived: %r" % body)

# A malformed hosts file must not be "repaired" into something unusable.
open(FAKE, "w").write("garbage-line\n\n# comment\n")
open(ADVISOR, "w").write('{"host":"policy.local","address":"192.0.2.254"}')
ns["task_openshell_advisor_host"]()
body = open(FAKE).read()
if body.startswith("garbage-line\n\n# comment\n") and "policy.local" in body:
    ok("lines it does not understand are passed through untouched")
else:
    bad("a malformed hosts file was rewritten: %r" % body)
sys.exit(1 if fails else 0)
PY
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s (see stderr)\n" "$rc"; }

# The resolver additions must cover the hosts file and the switch file, or a
# hosts-only name depends on systemd-resolved being the resolver.
sudo python3 - <<PY
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("sb", "$ROOT/bromure-sandboxd")
sb = importlib.util.module_from_spec(importlib.util.spec_from_loader("sb", loader))
sys.argv = ["x"]; loader.exec_module(sb)
paths = {p for p, _ in sb.resolver_additions()}
missing = {"/etc/hosts", "/etc/nsswitch.conf"} - paths
print("  ok   the resolver additions cover the hosts and switch files"
      if not missing else "  FAIL missing %s (have %s)" % (missing, paths))
why = dict(sb.resolver_additions())
tagged = [p for p in ("/etc/hosts", "/etc/nsswitch.conf")
          if "name resolution" in why.get(p, "")]
print("  ok   and both are reported as name resolution"
      if len(tagged) == 2 else "  FAIL why texts: %s" % why)
sys.exit(1 if missing or len(tagged) != 2 else 0)
PY
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s (see stderr)\n" "$rc"; }

# CA trust: the sandboxed non-interactive exec reads neither /etc/profile.d nor
# /etc/environment, so with proxy.env gone the CA paths had no carrier at all --
# and the failure is PARTIAL (curl fine, node and python-requests not), which is
# the hardest kind to attribute.
python3 - <<PY
import os, re, subprocess, sys, threading
src = open("$ROOT/patched/bromure-agentd.py").read()
ns = {"os": os, "subprocess": subprocess, "json": __import__("json"),
      "socket": __import__("socket"), "threading": threading,
      "log": lambda *a: None}
m = re.search(r"\n_CA_TRUST_ENV = \{.*?\n\}", src, re.S)
exec(compile(m.group(0), "ca", "exec"), ns)
for name in ("_ca_trust_for_exec",):
    m = re.search(r"\ndef %s\b.*?(?=\n(?:def |class |# ---))" % name, src, re.S)
    exec(compile(m.group(0), name, "exec"), ns)
ns["_CA_TRUST_FOR_EXEC"] = None
got = ns["_ca_trust_for_exec"]()
fails = 0
if got and all(os.path.exists(v) for v in got.values()):
    print("  ok   %d CA-trust vars, every one pointing at a file that exists"
          % len(got))
else:
    print("  FAIL CA trust env is %r" % got); fails += 1
# A var naming a missing file is worse than none: requests RAISES on it.
if "REQUESTS_CA_BUNDLE" in got and os.path.exists(got["REQUESTS_CA_BUNDLE"]):
    print("  ok   REQUESTS_CA_BUNDLE is present and real (python-requests)")
else:
    print("  FAIL REQUESTS_CA_BUNDLE missing or dangling: %r" % got.get("REQUESTS_CA_BUNDLE"))
    fails += 1
sys.exit(1 if fails else 0)
PY
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s (see stderr)\n" "$rc"; }

# And the property the additions exist for: a hosts-only name resolving under a
# policy that grants NO /etc at all. This is the one check that needs a real
# /etc/hosts entry, so it takes a hash before and after and asserts the file came
# back byte-identical -- the same discipline test_strict.sh uses, for the same
# reason: an earlier test in this project damaged the real /etc.
HOSTS_SHA_BEFORE=$(sudo sha256sum /etc/hosts | cut -d' ' -f1)
restore_hosts() {
    sudo sed -i '/# bromure-test-advisor$/d' /etc/hosts 2>/dev/null
}
# COMPOSED with `cleanup`, not substituted for it. `trap 'restore_hosts' EXIT`
# REPLACES the suite's EXIT trap, so from here on `cleanup` was never
# registered -- and `trap - EXIT` below then removed the trap altogether. Every
# section after this point therefore ran with no teardown at all: measured, the
# suite left `ping_group_range` moved, six `/tmp/sandboxtest-*` directories and
# a tmux server per run behind it. This is why the sysctl restore added two
# rounds ago appeared to do nothing -- the function holding it was never called.
trap 'restore_hosts; cleanup' EXIT
printf '192.0.2.254\tpolicy.local\t# bromure-test-advisor\n' \
    | sudo tee -a /etc/hosts > /dev/null
sudo python3 - <<PY
import importlib.machinery, importlib.util, os, sys
sys.path.insert(0, "$ROOT")
import bromure_openshell as osh
loader = importlib.machinery.SourceFileLoader("sb", "$ROOT/bromure-sandboxd")
sb = importlib.util.module_from_spec(importlib.util.spec_from_loader("sb", loader))
sys.argv = ["x"]; loader.exec_module(sb)

fails = 0
def ok(m): print("  ok   %s" % m)
def bad(m):
    global fails
    print("  FAIL %s" % m); fails += 1

def resolve_in_sandbox(extra_ro):
    pol = osh.SandboxPolicy.from_json({
        "filesystem_policy": {"read_only": ["/usr", "/lib", "/proc"],
                              "read_write": ["/tmp", "/dev/null"],
                              "include_workdir": False},
        "landlock": {"compatibility": "hard_requirement"}})
    prepared, outcome = osh.prepare(pol, workdir=None,
                                    path_open_mode=osh.PRIVILEGED,
                                    extra_read_only=list(extra_ro))
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        try:
            osh.enforce_landlock_privileged(prepared, outcome)
        except Exception as exc:
            os.write(w, ("enforce:%s" % exc).encode()); os._exit(1)
        import socket
        try:
            os.write(w, socket.gethostbyname("policy.local").encode())
        except Exception as exc:
            os.write(w, ("unresolved:%s" % str(exc)[:40]).encode())
        os._exit(0)
    os.close(w)
    got = os.read(r, 4096).decode(); os.close(r); os.waitpid(pid, 0)
    if prepared: prepared.close()
    return got

adds = [p for p, _ in sb.resolver_additions()]
got = resolve_in_sandbox(adds)
if got == "192.0.2.254":
    ok("policy.local resolves to 192.0.2.254 with NO /etc granted")
else:
    bad("policy.local did not resolve under a no-/etc policy: %s" % got)
# And the files really are reachable, which is what makes it independent of
# which daemon happens to be answering.
r, w = os.pipe()
pid = os.fork()
if pid == 0:
    os.close(r)
    pol = osh.SandboxPolicy.from_json({
        "filesystem_policy": {"read_only": ["/usr", "/lib", "/proc"],
                              "read_write": ["/tmp", "/dev/null"],
                              "include_workdir": False},
        "landlock": {"compatibility": "hard_requirement"}})
    prepared, outcome = osh.prepare(pol, workdir=None,
                                    path_open_mode=osh.PRIVILEGED,
                                    extra_read_only=adds)
    osh.enforce_landlock_privileged(prepared, outcome)
    out = []
    for path in ("/etc/hosts", "/etc/nsswitch.conf"):
        try:
            open(path).read(1); out.append("%s=read" % path)
        except OSError as exc:
            out.append("%s=%s" % (path, exc.strerror))
    os.write(w, " ".join(out).encode()); os._exit(0)
os.close(w)
seen = os.read(r, 4096).decode(); os.close(r); os.waitpid(pid, 0)
if seen.count("=read") == 2:
    ok("and both resolver files are readable inside the sandbox (%s)" % seen)
else:
    bad("a resolver file is not readable: %s" % seen)
sys.exit(1 if fails else 0)
PY
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s\n" "$rc"; }
restore_hosts
# Back to the suite's own trap, NOT `trap - EXIT`. Removing it entirely left
# every later section with no teardown.
trap cleanup EXIT
HOSTS_SHA_AFTER=$(sudo sha256sum /etc/hosts | cut -d' ' -f1)
check "the real /etc/hosts came back byte-identical" \
    "$HOSTS_SHA_AFTER" "$HOSTS_SHA_BEFORE"

# --------------------------------------------------------------------------
say "21. the gate waits for what was requested, and nothing else"
# The regression: `sandbox_gate()` waited unconditionally for a supervisor, so a
# STRICT-ONLY workspace -- strict marker, no openshell-sandbox.json, no supervisor
# by design -- answered `rc 75, sandbox unavailable ... (still starting)` on every
# exec, forever. That is the plain Phase-4 strict sandbox, dead on every boot.
python3 - <<PY
import os, re, sys, threading, time
src = open("$ROOT/patched/bromure-agentd.py").read()

def gate_with(spec, strict_requested, strict_applied, sandbox_status,
              unapplied=False, timeout=1.0):
    ns = {"os": os, "time": time, "threading": threading,
          "log": lambda *a: None,
          "STRICT_DONE": "/run/bromure-strict.done",
          "openshell_requested": lambda: spec,
          "strict_sandbox_requested": lambda: strict_requested,
          "strict_sandbox_applied": lambda: strict_applied,
          "_SANDBOX": dict(sandbox_status),
          "_load_sandbox_status": lambda: dict(sandbox_status),
          "_SANDBOX_READY": threading.Event(),
          "_STRICT_UNAPPLIED": unapplied}
    m = re.search(r"\ndef sandbox_gate\b.*?(?=\n(?:def |class |# ---))", src, re.S)
    exec(compile(m.group(0), "gate", "exec"), ns)
    started = time.time()
    ok, why = ns["sandbox_gate"](timeout=timeout)
    return ok, why, time.time() - started

fails = 0
def ok(m): print("  ok   %s" % m)
def bad(m):
    global fails
    print("  FAIL %s" % m); fails += 1

# THE REGRESSION: strict only. No spec, so no supervisor, so nothing to wait for.
got, why, took = gate_with(spec=False, strict_requested=True,
                           strict_applied=True, sandbox_status={})
if got and took < 0.5:
    ok("strict-only: the gate opens at once, with no supervisor (%.2fs)" % took)
else:
    bad("strict-only workspace was gated: ok=%s why=%r after %.1fs" % (got, why, took))

# But it still waits for the REVOCATION, which is the part that matters: before
# it, this process has sudo and so would anything it execs.
got, why, took = gate_with(spec=False, strict_requested=True,
                           strict_applied=False, sandbox_status={})
if not got and "revocation" in (why or ""):
    ok("and it still waits for the revocation, naming it: %s" % why)
else:
    bad("strict-only with no revocation was let through: ok=%s why=%r" % (got, why))

# A spec staged but no supervisor: must time out, and must SAY which half.
got, why, took = gate_with(spec=True, strict_requested=False,
                           strict_applied=False, sandbox_status={})
if not got and "supervisor" in (why or ""):
    ok("a spec with no supervisor times out and names it: %s" % why)
else:
    bad("expected a supervisor timeout, got ok=%s why=%r" % (got, why))

# A spec with a supervisor that reported a reason: the reason reaches the caller.
got, why, took = gate_with(spec=True, strict_requested=False, strict_applied=False,
                           sandbox_status={"degraded_reason": "ruleset refused"})
if not got and "ruleset refused" in (why or ""):
    ok("and a supervisor that failed passes its reason through: %s" % why)
else:
    bad("the supervisor's own reason was dropped: %r" % why)

# Both requested, both satisfied.
got, why, took = gate_with(spec=True, strict_requested=True, strict_applied=True,
                           sandbox_status={"tmux_socket": "/run/x/tmux.sock"})
if got:
    ok("spec + strict, both satisfied: the gate opens")
else:
    bad("a fully ready workspace was gated: %r" % why)

# Neither requested: no gate at all.
got, why, took = gate_with(spec=False, strict_requested=False,
                           strict_applied=False, sandbox_status={})
if got and took < 0.1:
    ok("no spec and no strict: no gate at all")
else:
    bad("an unsandboxed workspace was gated: ok=%s why=%r" % (got, why))

# A revocation that could not be applied fails FAST rather than after the full
# timeout -- the workspace is broken and the user should hear so immediately.
got, why, took = gate_with(spec=True, strict_requested=True, strict_applied=False,
                           sandbox_status={}, unapplied=True, timeout=5.0)
if not got and took < 1.0 and "could not be applied" in (why or ""):
    ok("a failed revocation refuses immediately, not after the timeout")
else:
    bad("unapplied strict: ok=%s why=%r after %.1fs" % (got, why, took))
sys.exit(1 if fails else 0)
PY
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s\n" "$rc"; }

# --------------------------------------------------------------------------
say "22. the status builder is total, whatever the spec looks like"
# attestd's watcher builds this line every second on the one connection the host
# accepts. An exception here is a host that stops hearing about the workspace --
# and `{"sentry": null}` is a perfectly ordinary way for a host to say "no
# sentry", which used to raise AttributeError because a key PRESENT with value
# null returns None rather than the .get() default.
python3 - <<PY
import json, os, sys, tempfile
sys.path.insert(0, "$ROOT")
import bromure_sandbox_status as s

d = tempfile.mkdtemp()
spec_path = os.path.join(d, "spec.json")
fails = 0
def ok(m): print("  ok   %s" % m)
def bad(m):
    global fails
    print("  FAIL %s" % m); fails += 1

CASES = [
    ("no spec file at all", None),
    ("an empty object", {}),
    ("sentry: null", {"version": 1, "sentry": None}),
    ("sentry: a string", {"version": 1, "sentry": "yes"}),
    ("sentry: a list", {"version": 1, "sentry": []}),
    ("filesystem_policy: null", {"version": 1, "filesystem_policy": None}),
    ("every section null", {"version": 1, "sentry": None, "process": None,
                            "filesystem_policy": None, "landlock": None}),
    ("the spec is a list", "[1,2,3]"),
    ("the spec is not JSON", "{{{"),
]
broke = []
for label, obj in CASES:
    if obj is None:
        if os.path.exists(spec_path):
            os.unlink(spec_path)
    elif isinstance(obj, str):
        open(spec_path, "w").write(obj)
    else:
        open(spec_path, "w").write(json.dumps(obj))
    try:
        out = s.build("/nonexistent", "/nonexistent", "/nonexistent", spec_path)
        s.fingerprint(out)
    except Exception as exc:
        broke.append("%s -> %s: %s" % (label, type(exc).__name__, exc))
if broke:
    for line in broke:
        bad("the status builder raised on %s" % line)
else:
    ok("%d spec shapes, including malformed ones, all produce a status" % len(CASES))

# And the no-spec answer is the RIGHT one, not merely an answer: a workspace that
# staged no spec asked for nothing, which is not the same as asking and not
# getting it.
if os.path.exists(spec_path):
    os.unlink(spec_path)
out = s.build("/nonexistent", "/nonexistent", "/nonexistent", spec_path)
if out["requested"] is None and out["filesystem"] == "off" and out["sentry"] == "off":
    ok("with no spec: requested=None, filesystem=off, sentry=off")
else:
    bad("no-spec status is %r" % {k: out[k] for k in
                                  ("requested", "filesystem", "sentry")})
sys.exit(1 if fails else 0)
PY
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s\n" "$rc"; }

# --------------------------------------------------------------------------
say "23. attestd connects before it has anything to say"
# The blocker: attestd imported bromure_sandbox_status at module scope, from the
# meta share. When that file was not there yet, the ImportError killed the
# process BEFORE it opened 5840; systemd restarted it a second later and the
# workspace ran with no attestor until the file appeared -- observed as a
# connection ~80s into a spec-less boot, with twenty denied connections in
# between, because the host fails closed on binary rules without an identity.
ATT=$WORK/attestd-alone
mkdir -p "$ATT"
cp "$ROOT/patched/bromure-attestd.py" "$ATT/"        # and deliberately nothing else
PORT=$((5840))
(python3 - <<PY > "$WORK/att-sink.log" 2>&1 &
import socket, time
s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((0xFFFFFFFF, $PORT))
s.listen(4)
s.settimeout(12)
try:
    c, peer = s.accept()
    print("CONNECTED", time.time())
    data = c.recv(65536)
    print("FIRST", data.decode("utf-8", "replace")[:200])
except Exception as exc:
    print("NOTHING", exc)
PY
) 2>/dev/null
sleep 1
START=$(date +%s)
sudo timeout 8 env BROMURE_HOST_CID=1 python3 "$ATT/bromure-attestd.py" \
    > "$WORK/att.log" 2>&1
sleep 1
if grep -q "CONNECTED" "$WORK/att-sink.log" 2>/dev/null; then
    ok "attestd connects with bromure_sandbox_status ABSENT"
else
    bad "attestd never connected without the status module: $(head -3 "$WORK/att.log" 2>/dev/null | tr '\n' ' ')"
fi
if grep -q '"hello": "attestd"\|"hello":"attestd"' "$WORK/att-sink.log" 2>/dev/null; then
    ok "and its first frame is the hello, so identity can be served at once"
else
    bad "the first frame was not a hello: $(grep FIRST "$WORK/att-sink.log" | head -c 200)"
fi
if grep -q "sandbox_status unavailable" "$WORK/att.log" 2>/dev/null; then
    ok "and it says the status is unavailable rather than dying of it"
else
    bad "no note about the missing status module: $(head -3 "$WORK/att.log")"
fi
# The connection must come FIRST: a log where the import failure precedes the
# connection is the old ordering.
if [ "$(grep -n 'connected to host\|sandbox_status unavailable' "$WORK/att.log" \
        | head -1 | cut -d: -f2- | grep -c 'connected to host')" = "1" ]; then
    ok "connecting happens before the status module is even looked for"
else
    bad "attestd looked for the status module before connecting"
fi

say "Bromure's own housekeeping must not look like an agent"
# The noise that hides the signal: agentd's status loops went through `_capture`
# -> `_ws_run`, so `df -kP /`, the docker polls and `ss` ran INSIDE the sandbox
# and were denied every couple of seconds, forever. Thirty-three of the first
# fifty-nine timeline rows after a boot were Bromure asking itself how much disk
# was left, and they fed the host's drift score.
#
# This asserts the split holds: the housekeeping commands are not routed into the
# sandbox, and the ones that are routed still are.
python3 - "$ROOT/patched/bromure-agentd.py" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
fails = 0
def ok(m): print("  ok   %s" % m)
def bad(m):
    global fails
    print("  FAIL %s" % m); fails += 1

# Housekeeping: reads the machine, never workspace content.
HOUSEKEEPING = ["df", "ss", "runlevel", "findmnt", "lsblk", "docker", "hostname"]
for tool in HOUSEKEEPING:
    # (?<!_sys): `_sys_capture` contains `_capture`, and matching it is how this
    # test first reported six failures against code that was already correct.
    routed = re.findall(r'(?<!_sys)_capture\(\["%s"' % tool, src)
    if routed:
        bad("%s still goes through _capture (into the sandbox): %d site(s)"
            % (tool, len(routed)))
    else:
        ok("%-9s runs as agentd, not as the workload" % tool)

# And the ones that MUST stay sandboxed, because their behaviour is
# workspace-controlled: a repository can redirect git through core.fsmonitor,
# core.hooksPath, diff.external and friends.
git_sandboxed = re.findall(r'(?<!_sys)_capture\(\["git"', src)
git_escaped = re.findall(r'_sys_capture\(\["git"', src)
if git_sandboxed and not git_escaped:
    ok("git stays sandboxed (%d site(s)) -- a repo can redirect it" % len(git_sandboxed))
else:
    bad("git routing is wrong: %d sandboxed, %d unconfined"
        % (len(git_sandboxed), len(git_escaped)))

# The privileged `ss` must not be on a timer.
if "_PORTS_CACHE" in src and 'sudo", "-n", "ss"' in src:
    body = src[src.index("def ports_loop_service"):][:3000]
    if "_PORTS_CACHE.get(\"key\")" in body:
        ok("the privileged ss runs only when the socket set changes")
    else:
        bad("the privileged ss is still unconditional")
else:
    bad("the ports loop no longer looks as expected")

# _sys_capture must demand a reason, so every escape is findable.
m = re.search(r"def _sys_capture\(([^)]*)\)", src)
if m and "reason" in m.group(1):
    ok("_sys_capture requires a reason, so every escape is greppable")
else:
    bad("_sys_capture does not require a reason: %s" % (m.group(1) if m else "?"))
sys.exit(1 if fails else 0)
PY
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s\n" "$rc"; }

# And /dev/tty, which bash probes on every `sh -c`.
python3 - "$ROOT/bromure-sandboxd" <<'PY'
import sys
src = open(sys.argv[1]).read()
if '("/dev/tty"' in src:
    print("  ok   /dev/tty is an addition, so a shell probing it is not a denial")
else:
    print("  FAIL /dev/tty is not in the additions; every vm exec will deny once")
    sys.exit(1)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

# --------------------------------------------------------------------------
say "24. the sentry asks the host for a module it does not have"
# The modules are no longer bundled: CI builds one per kernel ABI and the host
# stages the ones a workspace needs. It cannot know the kernel of a workspace it
# has never booted, nor one that just apt-upgraded -- so the guest reports what
# it has, says `waiting`, and the host fetches on seeing that.
#
# These run HERE rather than in the sentry suite because none of them loads a
# module: they are about the status the host reads and the polling around it, and
# this VM's lockdown forbids loading anyway.
SENTRY_W=$WORK/sentry-wait
mkdir -p "$SENTRY_W/meta/sentry" "$SENTRY_W/meta/sentry/src" "$SENTRY_W/run"
printf '{"version":1,"sentry":{"enabled":true}}' \
    > "$SENTRY_W/meta/openshell-sandbox.json"

# --- installed_kernels, with two kernels present ---------------------------
python3 - <<PY
import os, sys, tempfile
mod = tempfile.mkdtemp(); boot = tempfile.mkdtemp()
# Two real kernels, and one that is ONLY a headers tree -- which is not a
# hypothetical: /lib/modules/6.8.0-142-generic on this very machine contains
# nothing but a 'build' symlink, because the headers package is installed for a
# kernel that is not. A naive glob would report a phantom and have the host build
# a module nothing can load.
for k, real in (("6.8.0-139-generic", True), ("6.8.0-142-generic", True),
                ("6.8.0-150-generic", False)):
    os.makedirs(os.path.join(mod, k))
    if real:
        open(os.path.join(mod, k, "modules.dep"), "w").close()
        open(os.path.join(boot, "vmlinuz-" + k), "w").close()
    else:
        os.makedirs(os.path.join(mod, k, "build"))
os.environ["BROMURE_MODULES_DIR"] = mod
os.environ["BROMURE_BOOT_DIR"] = boot
sys.path.insert(0, "$ROOT")
import bromure_sandbox_status as s
got = s.installed_kernels()
fails = 0
if got == ["6.8.0-139-generic", "6.8.0-142-generic"]:
    print("  ok   installed_kernels reports both real kernels, sorted")
else:
    print("  FAIL installed_kernels = %r" % got); fails = 1
if "6.8.0-150-generic" not in got:
    print("  ok   and excludes a headers-only tree (no modules.dep)")
else:
    print("  FAIL a headers-only tree was reported as an installed kernel"); fails = 1
out = s.build("/nonexistent", "/nonexistent", "/nonexistent",
              "$SENTRY_W/meta/openshell-sandbox.json")
if out.get("sentry_kernel") == os.uname().release:
    print("  ok   sentry_kernel is the running release (%s)" % out["sentry_kernel"])
else:
    print("  FAIL sentry_kernel = %r" % out.get("sentry_kernel")); fails = 1
# Reported even with the sentry OFF: a workspace that switches it on tomorrow
# should already have had its module prefetched.
off = s.build("/nonexistent", "/nonexistent", "/nonexistent", "/nonexistent")
if off.get("installed_kernels") and off.get("sentry_kernel"):
    print("  ok   and both are reported with no spec and the sentry off")
else:
    print("  FAIL kernels are not reported when the sentry is off"); fails = 1
if "waiting" in s.VALID_SENTRY:
    print("  ok   'waiting' is a valid sentry state, so it is not coerced to off")
else:
    print("  FAIL 'waiting' would be coerced away, deadlocking host and guest")
    fails = 1
sys.exit(fails)
PY
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s\n" "$rc"; }

# --- best_effort: the session must NOT be held up --------------------------
# 45s is a long time to have no session, and long enough to trip the host's
# boot-phase budget. So best_effort hands the wait to a transient unit and
# returns at once; only `requirement: hard` waits inline, because a workspace
# that demanded the sentry must not get a window with nothing watching.
START=$(date +%s)
sudo env BROMURE_META="$SENTRY_W/meta" BROMURE_RUN_DIR="$SENTRY_W/run" \
    BROMURE_SENTRY_WAIT_S=20 BROMURE_SENTRY_NO_LOCKDOWN=1 \
    /usr/bin/python3 "$ROOT/bromure-sentryd" > "$SENTRY_W/bg.log" 2>&1
sudo rmmod bromure_sentry 2>/dev/null   # each sub-case starts from "not loaded"
ELAPSED=$(( $(date +%s) - START ))
if [ "$ELAPSED" -le 3 ]; then
    ok "best_effort returns in ${ELAPSED}s, so the session is not held up"
else
    bad "best_effort blocked for ${ELAPSED}s; the boot budget would notice"
fi
STATE=$(sudo python3 -c "
import json; print(json.load(open('$SENTRY_W/run/sentry.json'))['sentry'])" 2>/dev/null)
check "and leaves the status at 'waiting', which is what the host acts on" \
    "$STATE" "waiting"
REASON=$(sudo python3 -c "
import json; print(json.load(open('$SENTRY_W/run/sentry.json'))['reason'] or '')" 2>/dev/null)
case "$REASON" in
    *"asking the host"*) ok "with a reason that says what it is waiting for" ;;
    *) bad "the waiting reason is unhelpful: $REASON" ;;
esac
KERNELS=$(sudo python3 -c "
import json; d=json.load(open('$SENTRY_W/run/sentry.json'))
print(','.join(d.get('installed_kernels') or []))" 2>/dev/null)
if [ -n "$KERNELS" ]; then
    ok "and carries installed_kernels ($KERNELS), so the host knows what to fetch"
else
    bad "the waiting status does not say which kernels this guest has"
fi
sudo systemctl stop bromure-sentry-await 2>/dev/null
sudo systemctl reset-failed bromure-sentry-await 2>/dev/null

# --- requirement: hard -- the wait is INLINE, and it finds a late delivery --
rm -rf "$SENTRY_W/run"; mkdir -p "$SENTRY_W/run"
printf '{"version":1,"sentry":{"enabled":true,"requirement":"hard"}}' \
    > "$SENTRY_W/meta/openshell-sandbox.json"
KO="$SENTRY_W/meta/sentry/bromure_sentry-$(uname -r).ko"
( sleep 3
  cp "$ROOT/sentry/bromure_sentry.ko" "$KO.tmp" 2>/dev/null && mv "$KO.tmp" "$KO" ) &
DROPPER=$!
START=$(date +%s)
sudo env BROMURE_META="$SENTRY_W/meta" BROMURE_RUN_DIR="$SENTRY_W/run" \
    BROMURE_SENTRY_WAIT_S=20 BROMURE_SENTRY_NO_LOCKDOWN=1 \
    /usr/bin/python3 "$ROOT/bromure-sentryd" > "$SENTRY_W/wait.log" 2>&1
sudo rmmod bromure_sentry 2>/dev/null   # each sub-case starts from "not loaded"
ELAPSED=$(( $(date +%s) - START ))
wait $DROPPER 2>/dev/null
if grep -q "the host delivered a module" "$SENTRY_W/wait.log"; then
    ok "requirement: hard waits inline and picks up a late delivery (${ELAPSED}s)"
else
    bad "the inline wait missed the delivered module: $(tail -3 "$SENTRY_W/wait.log" | tr '\n' ' ')"
fi
# What matters for THIS test is that the file was found and handed to the
# loader, which is true whether the load then succeeds or not: at lockdown
# `integrity` insmod fails whatever the module is, and at `none` it succeeds.
# Both outcomes are accepted deliberately -- asserting the FAILURE, as an
# earlier version effectively did, encoded the machine's limitation as the
# expected result, and the assertion then broke the moment the machine could
# actually load a module.
if grep -qE "insmod failed|already loaded|running|loaded" "$SENTRY_W/wait.log"; then
    ok "and handed it to the loader (either outcome: it loads here or not)"
else
    bad "the module was never handed to the loader: $(tail -2 "$SENTRY_W/wait.log" | tr '\n' ' ')"
fi
rm -f "$KO"
printf '{"version":1,"sentry":{"enabled":true}}' \
    > "$SENTRY_W/meta/openshell-sandbox.json"

# --- the host says "none is coming" ----------------------------------------
# The 45s timeout is for a host that says NOTHING. When the host knows -- and it
# usually knows within a few seconds -- it drops a marker and the guest must stop
# at once. Measured live before this existed: the host knew in 5s and a hard-mode
# guest still waited the full 45, so the shell took 50s.
sentry_state() {
    sudo python3 -c "
import json; print(json.load(open('$SENTRY_W/run/sentry.json'))['sentry'])" 2>/dev/null
}
sentry_reason() {
    sudo python3 -c "
import json; print(json.load(open('$SENTRY_W/run/sentry.json'))['reason'] or '')" 2>/dev/null
}
rm -rf "$SENTRY_W/run" "$SENTRY_W/meta/sentry"
mkdir -p "$SENTRY_W/run" "$SENTRY_W/meta/sentry"
printf '{"version":1,"sentry":{"enabled":true,"requirement":"hard"}}' \
    > "$SENTRY_W/meta/openshell-sandbox.json"
MARKER="$SENTRY_W/meta/sentry/bromure_sentry-$(uname -r).unavailable"
( sleep 2; printf 'no module published for %s yet\n' "$(uname -r)" > "$MARKER" ) &
DROPPER=$!
START=$(date +%s)
sudo env BROMURE_META="$SENTRY_W/meta" BROMURE_RUN_DIR="$SENTRY_W/run" \
    BROMURE_SENTRY_WAIT_S=45 BROMURE_SENTRY_NO_LOCKDOWN=1 \
    /usr/bin/python3 "$ROOT/bromure-sentryd" > "$SENTRY_W/marker.log" 2>&1
sudo rmmod bromure_sentry 2>/dev/null   # each sub-case starts from "not loaded"
ELAPSED=$(( $(date +%s) - START ))
wait $DROPPER 2>/dev/null
# 45s budget, marker at +2s, then a local build attempt (which fails fast here
# because this kernel's headers ARE installed but the build is what it is). The
# claim under test is that the WAIT ended on the marker, not that the whole run
# was quick.
if grep -q "the host says none is coming after" "$SENTRY_W/marker.log"; then
    WAITED=$(sed -n 's/.*none is coming after \([0-9.]*\)s.*/\1/p' \
        "$SENTRY_W/marker.log" | head -1)
    if [ -n "$WAITED" ] && [ "${WAITED%%.*}" -le 4 ]; then
        ok "the marker ends the wait in ${WAITED}s, not 45 (total run ${ELAPSED}s)"
    else
        bad "the marker was seen but only after ${WAITED}s"
    fi
else
    bad "the marker did not end the wait: $(tail -3 "$SENTRY_W/marker.log" | tr '\n' ' ')"
fi
REASON=$(sentry_reason)
case "$REASON" in
    *"the host says: no module published for"*)
        ok "and the host's own words reach the status: $(printf '%s' "$REASON" | head -c 80)" ;;
    *) bad "the host's reason did not reach the status: $REASON" ;;
esac
check "and the state is unavailable" "$(sentry_state)" "unavailable"

# --- a marker AND a module: the module wins --------------------------------
# A host that wrote "none is coming" and then found one must not be taken at its
# earlier word. The .ko is checked first on every pass for exactly this.
rm -rf "$SENTRY_W/run"; mkdir -p "$SENTRY_W/run"
printf 'no module published yet\n' > "$MARKER"
cp "$ROOT/sentry/bromure_sentry.ko" \
   "$SENTRY_W/meta/sentry/bromure_sentry-$(uname -r).ko" 2>/dev/null
sudo env BROMURE_META="$SENTRY_W/meta" BROMURE_RUN_DIR="$SENTRY_W/run" \
    BROMURE_SENTRY_WAIT_S=10 BROMURE_SENTRY_NO_LOCKDOWN=1 \
    /usr/bin/python3 "$ROOT/bromure-sentryd" > "$SENTRY_W/both.log" 2>&1
sudo rmmod bromure_sentry 2>/dev/null   # each sub-case starts from "not loaded"
if grep -qE "insmod failed|already loaded|running \(prebuilt" "$SENTRY_W/both.log"; then
    ok "a staged module beats a stale 'none is coming' marker"
else
    bad "the marker masked a module that was there: $(tail -3 "$SENTRY_W/both.log" | tr '\n' ' ')"
fi
if grep -q "none is coming" "$SENTRY_W/both.log"; then
    bad "it consulted the marker even though the module was present"
else
    ok "and the marker was never consulted, because the .ko is checked first"
fi
rm -f "$MARKER" "$SENTRY_W/meta/sentry/bromure_sentry-$(uname -r).ko"
printf '{"version":1,"sentry":{"enabled":true}}' \
    > "$SENTRY_W/meta/openshell-sandbox.json"

# --- the timeout, inline (requirement: hard) --------------------------------
rm -rf "$SENTRY_W/run" "$SENTRY_W/meta/sentry"
mkdir -p "$SENTRY_W/run" "$SENTRY_W/meta/sentry"
printf '{"version":1,"sentry":{"enabled":true,"requirement":"hard"}}' \
    > "$SENTRY_W/meta/openshell-sandbox.json"
START=$(date +%s)
sudo env BROMURE_META="$SENTRY_W/meta" BROMURE_RUN_DIR="$SENTRY_W/run" \
    BROMURE_SENTRY_WAIT_S=3 BROMURE_SENTRY_NO_LOCKDOWN=1 \
    /usr/bin/python3 "$ROOT/bromure-sentryd" > "$SENTRY_W/timeout.log" 2>&1
sudo rmmod bromure_sentry 2>/dev/null   # each sub-case starts from "not loaded"
ELAPSED=$(( $(date +%s) - START ))
check "a timeout ends as unavailable, not waiting" "$(sentry_state)" "unavailable"
REASON=$(sentry_reason)
case "$REASON" in
    *"did not answer within"*)
        ok "and a SILENT host is described as silent, not as a refusal: $(printf '%s' "$REASON" | head -c 76)" ;;
    *) bad "the timeout reason does not distinguish a silent host: $REASON" ;;
esac
if [ "$ELAPSED" -le 120 ]; then
    ok "and the wait was bounded (${ELAPSED}s, budget 3s + a local build attempt)"
else
    bad "the wait was not bounded: ${ELAPSED}s"
fi

# --- the timeout, in the background unit -----------------------------------
# The common path: best_effort hands the wait off, so the VERDICT is written by
# the unit rather than by the process the root script called. A `waiting` status
# that is never resolved would leave the host fetching forever.
rm -rf "$SENTRY_W/run" "$SENTRY_W/meta/sentry"
mkdir -p "$SENTRY_W/run" "$SENTRY_W/meta/sentry"
printf '{"version":1,"sentry":{"enabled":true}}' \
    > "$SENTRY_W/meta/openshell-sandbox.json"
sudo systemctl reset-failed bromure-sentry-await 2>/dev/null
sudo env BROMURE_META="$SENTRY_W/meta" BROMURE_RUN_DIR="$SENTRY_W/run" \
    BROMURE_SENTRY_WAIT_S=3 BROMURE_SENTRY_NO_LOCKDOWN=1 \
    /usr/bin/python3 "$ROOT/bromure-sentryd" > "$SENTRY_W/bgtimeout.log" 2>&1
sudo rmmod bromure_sentry 2>/dev/null   # each sub-case starts from "not loaded"
waited=0
while [ "$waited" -lt 90 ]; do
    [ "$(sentry_state)" != "waiting" ] && break
    sleep 2; waited=$((waited + 2))
done
if [ "$(sentry_state)" = "unavailable" ]; then
    ok "the background unit resolves 'waiting' to unavailable too (${waited}s)"
else
    bad "the background wait left the status at '$(sentry_state)' after ${waited}s"
    sudo journalctl -u bromure-sentry-await --no-pager -n 8 2>/dev/null | sed 's/^/       /'
fi
sudo systemctl reset-failed bromure-sentry-await 2>/dev/null
sudo rm -rf "$SENTRY_W"

# --------------------------------------------------------------------------
say "25. ICMP echo sockets for the workload's group"
# Ubuntu ships `net.ipv4.ping_group_range = 1 0` -- low ABOVE high, an EMPTY
# range -- so no group may open a SOCK_DGRAM/IPPROTO_ICMP socket, and
# /usr/bin/ping falls back to SOCK_RAW on its `cap_net_raw` file capability.
# Inside the strict sandbox that fallback cannot work, because `no_new_privs` is
# irreversible and a file capability is not honoured under it. So `ping` fails
# for the agent in a way it never does for the user unless the range names the
# workload's gid -- which is what sandboxd now sets at boot, runtime only.
#
# Its OWN workspace, not $WORK: by this point the earlier sections have left a
# supervisor, a control socket and a server directory behind, and a `launch`
# into that state publishes no status (measured -- the first version of this
# section failed on exactly that and it had nothing to do with ping).
PING_W=$(mktemp -d /tmp/sandboxtest-ping-XXXXXX)
mkdir -p "$PING_W/meta" "$PING_W/run" "$PING_W/workdir"
chmod 755 "$PING_W"
MY_GID=$(id -g)
OWNER_GID=$(id -g ubuntu 2>/dev/null || echo 1000)

ping_sandboxd() {   # <spec-json-or-empty>
    sudo rm -f "$PING_W/run/status.json"
    if [ -n "$1" ]; then printf '%s' "$1" > "$PING_W/meta/openshell-sandbox.json"
    else rm -f "$PING_W/meta/openshell-sandbox.json"; fi
    sudo env BROMURE_META="$PING_W/meta" BROMURE_RUN_DIR="$PING_W/run" \
        BROMURE_STRICT_DONE="$PING_W/strict.done" \
        BROMURE_SANDBOXD_ONESHOT=1 BROMURE_AGENTD_PID="$$" \
        /usr/bin/python3 "$ROOT/bromure-sandboxd" > "$PING_W/log" 2>&1
}

# The FUNCTIONAL claim first, both directions, with no capability anywhere.
# Asserting the number in /proc would pass even if the kernel ignored it; and
# the kernel checks the caller's egid AND its supplementary groups, so what
# matters is whether the gid the agent really has falls in the range.
ping_socket_as() {   # <uid> <gid> -> yes | no
    sudo python3 -c "
import os, socket, sys
pid = os.fork()
if pid == 0:
    os.setgroups([]); os.setresgid($2, $2, $2); os.setresuid($1, $1, $1)
    try:
        socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_ICMP)
        sys.stdout.write('yes\n')
    except OSError:
        sys.stdout.write('no\n')
    sys.stdout.flush()
    os._exit(0)
os.waitpid(pid, 0)
" 2>/dev/null
}

sudo sh -c "echo '1 0' > $PING_RANGE"
check "with the shipped empty range, an unprivileged gid is refused" \
    "$(ping_socket_as 999 "$MY_GID")" "no"

# A spec with NO filesystem_policy and NO process section: the grant is not
# conditional on which policy sections a workspace happens to carry.
ping_sandboxd '{"version":1,"filesystem_policy":null,"process":null,"workdirs":["'"$PING_W"'/workdir"],"sentry":{"enabled":false}}'
check "sandboxd sets the range to the workload's gid" \
    "$(tr '\t' ' ' < "$PING_RANGE")" "$MY_GID $MY_GID"
check "and an unprivileged uid in that gid can now open a ping socket" \
    "$(ping_socket_as 999 "$MY_GID")" "yes"
# The gid is the gate, not the uid: a uid in some other group stays refused, so
# this is a grant to one group and not a hole for everybody.
check "a uid outside that gid is still refused" \
    "$(ping_socket_as 999 1)" "no"

# Reported, so the host can tell a workspace where the agent's `ping` works from
# one where it silently falls back to a raw socket it cannot have.
check "status.json reports ping_sockets" \
    "$(sudo python3 -c "
import json
print(json.load(open('$PING_W/run/status.json')).get('ping_sockets'))" 2>/dev/null)" \
    "$MY_GID"
check "the status builder reports the LIVE value, not a recorded intention" \
    "$(python3 -c "
import sys; sys.path.insert(0, '$ROOT')
import bromure_sandbox_status as s
print(s.build('/nonexistent','/nonexistent','/nonexistent','/nonexistent')['ping_sockets'])")" \
    "$MY_GID"
check "and it is in the fingerprint, so a change reaches the host" \
    "$(python3 -c "
import sys; sys.path.insert(0, '$ROOT')
import bromure_sandbox_status as s
print('yes' if 'ping_sockets' in s.fingerprint(s.build()) else 'no')")" "yes"

# An empty range reads as "none", not as "group 1": `1 0` is low above high.
sudo sh -c "echo '1 0' > $PING_RANGE"
check "an empty range is reported as none, not as group 1" \
    "$(python3 -c "
import sys; sys.path.insert(0, '$ROOT')
import bromure_sandbox_status as s; print(s.ping_sockets())")" "none"

# A workspace with NO spec gets it too. sandboxd returns early on that path --
# "nothing to do" -- so the grant has to happen BEFORE the early return, or
# `ping` would depend on whether a policy happened to be staged.
ping_sandboxd ""
check "a workspace with no spec is granted it as well" \
    "$(tr '\t' ' ' < "$PING_RANGE")" "$OWNER_GID $OWNER_GID"
check "and it still writes no status file, as before" \
    "$([ -e "$PING_W/run/status.json" ] && echo present || echo absent)" "absent"

# RUNTIME ONLY. Same lesson as the strict revocation: a boot-time change this
# daemon makes must die with the boot, so a workspace that stops asking for it
# stops having it, and nothing done here outlives the VM.
if grep -rl "ping_group_range" /etc/sysctl.conf /etc/sysctl.d 2>/dev/null | grep -q .; then
    bad "a persistent sysctl drop-in for ping_group_range was written"
else
    ok "no persistent sysctl.d drop-in exists -- the grant dies with the boot"
fi
check "the only path sandboxd writes is under /proc" \
    "$(python3 -c "
import re
src = open('$ROOT/bromure-sandboxd').read()
m = re.search(r'^PING_GROUP_RANGE = \"([^\"]+)\"', src, re.M)
print('proc' if m and m.group(1).startswith('/proc/') else (m.group(1) if m else 'missing'))")" \
    "proc"

# One sysctl, BOTH families: ICMPv6 ping sockets go through the same
# `ping_init_sock`, so there is no net.ipv6.ping_group_range to set. Measured
# rather than assumed, because "surely v6 has its own" is the obvious guess and
# it is wrong.
sudo sh -c "echo '$MY_GID $MY_GID' > $PING_RANGE"
check "the same range also opens ICMPv6 ping sockets" \
    "$(sudo python3 -c "
import os, socket, sys
pid = os.fork()
if pid == 0:
    os.setgroups([]); os.setresgid($MY_GID, $MY_GID, $MY_GID)
    os.setresuid(999, 999, 999)
    try:
        socket.socket(socket.AF_INET6, socket.SOCK_DGRAM, 58)
        sys.stdout.write('yes\n')
    except OSError:
        sys.stdout.write('no\n')
    sys.stdout.flush()
    os._exit(0)
os.waitpid(pid, 0)
" 2>/dev/null)" "yes"
check "and there is no separate v6 sysctl to forget" \
    "$([ -e /proc/sys/net/ipv6/ping_group_range ] && echo exists || echo absent)" "absent"

# Its own workspace means its own tmux server, which `cleanup` does not know
# about: $WORK is not its parent.
kill_tmux_under "$PING_W"
sudo rm -rf "$PING_W"

# --------------------------------------------------------------------------
say "26. the HTTP bridge announces its client, so a proxied flow can be joined"
# Every non-OpenShell workspace gets HTTPS_PROXY=http://127.0.0.1:<proxy_port>,
# so curl, npm, pip and git-over-https connect to LOOPBACK. The sentry reports
# that flow, but its destination is the proxy rather than the site -- on its own
# the row reads "curl -> 127.0.0.1", which is true and useless. The client's
# SOURCE PORT is the one value both sides have: the sentry puts it in the flow's
# `sport`, and agentd hands the same number to the MITM, which knows the CONNECT
# target. This section covers the guest half of that join.
#
# A real vsock listener on VMADDR_CID_LOCAL, not a mock: `_bridge` connects
# AF_VSOCK to HOST_CID, and the ordering being tested -- preamble strictly
# before the client's first byte -- is a property of that code path, not of a
# stand-in. Measured: binding a high vsock port and connecting to CID 1 needs no
# privilege.
sudo modprobe vsock_loopback 2>/dev/null
ROOT="$ROOT" python3 - <<'PYEOF'
import importlib.machinery, importlib.util, os, socket, sys, tempfile, threading, time

ROOT = os.environ["ROOT"]

fails = 0
def ok(m): print("  ok   %s" % m)
def bad(m):
    global fails
    print("  FAIL %s" % m); fails += 1

meta = tempfile.mkdtemp()
open(os.path.join(meta, "proxy_port"), "w").write("65534")
os.environ["BROMURE_META"] = meta
os.environ["BROMURE_HOST_CID"] = "1"          # VMADDR_CID_LOCAL
os.environ.pop("BROMURE_BRIDGE_PREAMBLE", None)

loader = importlib.machinery.SourceFileLoader("ad", ROOT + "/patched/bromure-agentd.py")
spec = importlib.util.spec_from_loader("ad", loader)
ad = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(ad)
except Exception as exc:
    print("  FAIL could not import agentd: %s: %s" % (type(exc).__name__, exc))
    sys.exit(1)
ok("agentd imports as a module (its work is behind a __main__ guard)")

# --- the line itself ---------------------------------------------------
line = ad._client_preamble(("127.0.0.1", 45678))
want = b"BROMURE-CLIENT 1 sport=45678 peer=127.0.0.1\n"
if line == want:
    ok("the preamble is exactly %r" % want.decode())
else:
    bad("preamble is %r, expected %r" % (line, want))
if line and line.endswith(b"\n"):
    ok("it ends with a newline, so a host that does not know it can skip it")
else:
    bad("no trailing newline: an unterminated line cannot be skipped")
if line and line.split()[1] == b"1":
    ok("it carries a version, so a field can be added later")

# A docker-bridge peer is announced too; the host gets a peer it cannot join,
# which beats a join made to the wrong process.
docker = ad._client_preamble(("172.17.0.3", 51000))
if docker == b"BROMURE-CLIENT 1 sport=51000 peer=172.17.0.3\n":
    ok("a docker-bridge peer is announced with the container's address")
else:
    bad("docker peer preamble is %r" % docker)

# --- the kill switch, and malformed input ------------------------------
os.environ["BROMURE_BRIDGE_PREAMBLE"] = "0"
if ad._client_preamble(("127.0.0.1", 1)) is None:
    ok("BROMURE_BRIDGE_PREAMBLE=0 turns it off, for a host that cannot take it")
else:
    bad("the kill switch does not disable the preamble")
os.environ.pop("BROMURE_BRIDGE_PREAMBLE")
for junk in (None, ("127.0.0.1",), ("127.0.0.1", "not-a-port")):
    if ad._client_preamble(junk) is not None:
        bad("a malformed accept() address produced a preamble: %r" % (junk,))
        break
else:
    ok("a malformed address yields no preamble rather than a broken line")

# --- ordering, over a real vsock ---------------------------------------
VMADDR_CID_ANY = 0xFFFFFFFF
PORT = 19443
listener = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
listener.bind((VMADDR_CID_ANY, PORT))
listener.listen(2)
received = {}

def serve(key, want_bytes):
    """Read until `want_bytes` have arrived, not merely until the first line.

    Stopping at the first newline was enough to see the preamble and therefore
    enough to pass -- which left "and the client's own bytes follow it" as a
    branch that never ran. Reading further makes that a real assertion instead
    of a hopeful one.
    """
    conn, _ = listener.accept()
    conn.settimeout(1)
    buf = b""
    deadline = time.time() + 4
    while len(buf) < want_bytes and time.time() < deadline:
        try:
            chunk = conn.recv(256)
        except OSError:
            continue          # the 1s timeout, not an error: keep waiting
        if not chunk:
            break
        buf += chunk
    received[key] = buf
    conn.close()

# http: the preamble must arrive BEFORE the client's first byte, so the client
# deliberately writes immediately.
t = threading.Thread(target=serve, args=("http", len(want) + 16),
                     daemon=True); t.start()
time.sleep(0.2)
a, b = socket.socketpair()
bridge = threading.Thread(target=ad._bridge,
                          args=(a, PORT, "http",
                                ad._client_preamble(("127.0.0.1", 45678))),
                          daemon=True)
bridge.start()
b.sendall(b"GET / HTTP/1.1\r\n")
t.join(6)
got = received.get("http", b"")
if got.startswith(want):
    ok("over a real vsock, the preamble is the FIRST thing the host reads")
    if got == want + b"GET / HTTP/1.1\r\n":
        ok("and the client's own bytes follow it, byte for byte, with nothing "
           "inserted between")
    else:
        bad("the stream after the preamble is %r, expected the client's bytes "
            "unmodified" % got[len(want):][:60])
else:
    bad("host first read %r, which does not start with the preamble" % got[:80])
try:
    b.close()
except OSError:
    pass

# ssh/aws/llm must NOT be prefixed: they carry their own protocol from byte one.
t = threading.Thread(target=serve, args=("ssh", 15), daemon=True); t.start()
time.sleep(0.2)
c, d = socket.socketpair()
threading.Thread(target=ad._bridge, args=(c, PORT, "ssh"), daemon=True).start()
d.sendall(b"SSH-2.0-client\n")
t.join(6)
got = received.get("ssh", b"")
if got.startswith(b"SSH-2.0-client"):
    ok("the ssh bridge is not prefixed -- _bridge defaults to no preamble")
elif b"BROMURE-CLIENT" in got:
    bad("the ssh bridge was prefixed with a preamble; only http may be")
else:
    bad("ssh bridge first read %r" % got[:60])
try:
    d.close()
except OSError:
    pass
listener.close()

# --- and sentryd exempts the same port the proxy is actually on --------
sloader = importlib.machinery.SourceFileLoader("sd", ROOT + "/bromure-sentryd")
sspec = importlib.util.spec_from_loader("sd", sloader)
sd = importlib.util.module_from_spec(sspec)
sspec.loader.exec_module(sd)
if sd.proxy_port() == ad.HTTP_PROXY_TCP_PORT:
    ok("sentryd and agentd read the same proxy port (%d) from the same file"
       % sd.proxy_port())
else:
    bad("sentryd says %d, agentd says %d -- they must not be able to disagree "
        "about which port is the proxy"
        % (sd.proxy_port(), ad.HTTP_PROXY_TCP_PORT))
open(os.path.join(meta, "proxy_port"), "w").write("8080")
if sd.proxy_port() == 8080:
    ok("and it follows the file, for a snapshot resumed under an older daemon")
else:
    bad("sentryd ignored a changed proxy_port: %d" % sd.proxy_port())

sys.exit(1 if fails else 0)
PYEOF
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s\n" "$rc"; }

# --------------------------------------------------------------------------
say "27. the build records the host's sourceHash, and records it correctly"
# `sourceHash` is the identifier the host keys a CDN-delivered module on, and
# the two sides were hashing different things for several rounds: per-file
# SHA-256s here, one derived number there, and neither could confirm the other's
# import matched the other's commit. build.sh now records the host's number.
#
# Checked against an INDEPENDENT implementation, in Python, rather than by
# re-running the same shell. The value only has to be right when it disagrees
# with the host's -- that is the whole point of it -- so a shell-quoting bug
# that silently changed the number would cost exactly the round it exists to
# save.
ROOT="$ROOT" python3 - <<'PYEOF'
import hashlib, os, re, subprocess, sys

ROOT = os.environ["ROOT"]
SENTRY = os.path.join(ROOT, "sentry")
fails = 0
def ok(m): print("  ok   %s" % m)
def bad(m):
    global fails
    print("  FAIL %s" % m); fails += 1

# The host's algorithm, implemented from its description: sha256 over Makefile,
# bromure_sentry.c, bromure_sentry.h in that order, each framed as
# `<name>\n<byte length>\n<bytes>`.
digest = hashlib.sha256()
for name in ("Makefile", "bromure_sentry.c", "bromure_sentry.h"):
    data = open(os.path.join(SENTRY, name), "rb").read()
    digest.update(("%s\n%d\n" % (name, len(data))).encode())
    digest.update(data)
want = digest.hexdigest()

# And the shell one, from build.sh itself, extracted and run on its own so this
# does not need a kernel build to check a string.
# Extracted by plain string bounds, not a regex: the first version matched on
# the exact indentation and line breaks of the assignment and broke the moment
# it was formatted differently -- a test that fails when the code is merely
# reformatted trains you to ignore it.
src = open(os.path.join(SENTRY, "build.sh")).read()
START, END = "SOURCE_HASH=$(", "| sha256sum | cut -d' ' -f1)"
if START not in src or END not in src[src.index(START):]:
    bad("could not find the SOURCE_HASH computation in build.sh")
else:
    body = src[src.index(START) + len(START):]
    body = body[:body.index(END)]
    snippet = 'HERE=%s\n%s %s\n' % (SENTRY, body, END[:-1])
    run = subprocess.run(["bash", "-c", snippet], capture_output=True, text=True)
    got = run.stdout.strip()
    if run.returncode != 0:
        bad("build.sh's snippet did not run: %s" % run.stderr.strip()[:120])
    if got == want:
        ok("build.sh's shell implementation agrees with an independent one (%s)"
           % want[:16])
    else:
        bad("build.sh computes %r, an independent implementation says %r"
            % (got, want))

# The framing is the part worth proving: without it, moving a byte from one file
# to the next would not change the hash.
def framed(parts):
    d = hashlib.sha256()
    for name, data in parts:
        d.update(("%s\n%d\n" % (name, len(data))).encode())
        d.update(data)
    return d.hexdigest()
a = framed([("a", b"xx"), ("b", b"y")])
b = framed([("a", b"x"), ("b", b"xy")])
if a != b:
    ok("the length framing makes a byte moved between files a different hash")
else:
    bad("the framing does not distinguish where a byte lives")

sys.exit(1 if fails else 0)
PYEOF
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s\n" "$rc"; }

# --------------------------------------------------------------------------
say "28. this suite's own teardown actually runs"
# A section once did `trap 'restore_hosts' EXIT` and later `trap - EXIT`, which
# REPLACED and then REMOVED the suite's EXIT trap -- so `cleanup` was never
# called for any section after it. Eight sections ran with no teardown, and the
# symptom was indirect: `ping_group_range` left moved, `/tmp/sandboxtest-*`
# directories and a tmux server accumulating per run. The sysctl restore added
# to `cleanup` two rounds earlier appeared to do nothing, because the function
# holding it was never called.
#
# Checked at the source level because a script cannot observe its own EXIT trap
# from the inside. It is the reintroduction that matters: the next person adding
# a section-local trap will reach for the same one-liner.
trap_lines=$(grep -n "^[[:space:]]*trap " "$HERE/test_sandbox.sh" || true)
if printf '%s\n' "$trap_lines" | grep -q "trap - EXIT"; then
    bad "a 'trap - EXIT' removes the suite's teardown; compose with cleanup instead"
else
    ok "no 'trap - EXIT' drops the suite's teardown"
fi
bad_traps=$(printf '%s\n' "$trap_lines" | grep "EXIT" | grep -v "cleanup" || true)
if [ -n "$bad_traps" ]; then
    bad "an EXIT trap does not run cleanup: $bad_traps"
else
    ok "every EXIT trap in this suite runs cleanup ($(printf '%s\n' "$trap_lines" | grep -c EXIT) of them)"
fi

# --------------------------------------------------------------------------
say "29. a host attach actually gets a shell"
# The gap that let a NameError reach users. `_run_interactive` was half
# converted: the `finally` branched on `proc`, the spawn bound only `pid`, and
# nothing ever constructed `_SandboxPty`. So in any workspace with an active
# spec a host attach ran `tmux attach` OUTSIDE the sandbox against the
# sandbox's own socket, it exited at once, and the `finally` raised
# `NameError: name 'proc' is not defined`. No terminal could attach, in any
# workspace with a spec, for many rounds.
#
# Nothing caught it because the coverage stopped one step short: `vm exec` is
# non-interactive and never enters this function, and the boot suite asserted
# "a session exists" rather than "an attach gets a shell". So this drives the
# interactive path itself, in BOTH shapes the host sends and BOTH workspace
# configurations, and asserts bytes come back.
ATTACH_W=$(mktemp -d /tmp/sandboxtest-attach-XXXXXX)
mkdir -p "$ATTACH_W/meta" "$ATTACH_W/run" "$ATTACH_W/workdir" "$ATTACH_W/scratch"
chmod 755 "$ATTACH_W"
ATTACH_SUP=""

attach_sup_start() {   # <spec-json>
    printf '%s' "$1" > "$ATTACH_W/meta/openshell-sandbox.json"
    sudo env BROMURE_META="$ATTACH_W/meta" BROMURE_RUN_DIR="$ATTACH_W/run" \
        BROMURE_STRICT_DONE="$ATTACH_W/scratch/strict.done" \
        BROMURE_AGENTD_PID="$$" BROMURE_SANDBOXD_NO_POWEROFF=1 \
        /usr/bin/python3 "$ROOT/bromure-sandboxd" > "$ATTACH_W/sup.log" 2>&1 &
    ATTACH_SUP=$!
    for _ in $(seq 1 150); do [ -S "$ATTACH_W/run/ctl.sock" ] && break; sleep 0.1; done
    for _ in $(seq 1 150); do
        sudo tmux -S "$ATTACH_W/run/server/tmux.sock" has-session -t bromure \
            2>/dev/null && break
        sleep 0.1
    done
}

# --- with a spec: the configuration that was broken -----------------------
attach_sup_start '{"version":1,"filesystem_policy":null,"process":null,"workdirs":["'"$ATTACH_W"'/workdir"],"sentry":{"enabled":false}}'
if [ -S "$ATTACH_W/run/ctl.sock" ]; then
    ok "a supervisor is serving ctl.sock for the spec workspace"
else
    bad "no ctl.sock; the attach test cannot distinguish its own failure"
fi

ROOT="$ROOT" ATTACH_W="$ATTACH_W" python3 - <<'PYEOF'
import importlib.machinery, importlib.util, os, socket, struct, subprocess
import sys, tempfile, threading, time

ROOT, W = os.environ["ROOT"], os.environ["ATTACH_W"]
fails = 0
def ok(m): print("  ok   %s" % m)
def bad(m):
    global fails
    print("  FAIL %s" % m); fails += 1

os.environ["BROMURE_META"] = W + "/meta"
os.environ["BROMURE_RUN_DIR"] = W + "/run"
# NO default-socket tmux server may be reachable. The first version of this
# section left TMUX_TMPDIR alone, so a bare `tmux has-session -t bromure`
# found THIS WORKSPACE'S OWN server -- which has a session called `bromure` --
# and the view attached to the real session. It passed, it printed 500 bytes of
# perfectly plausible terminal output, and it was exercising the wrong server
# entirely. A second attach bug (`_view_attach_command` hard-coding `tmux`
# instead of `_tmux_argv()`) sailed straight through it and reached the user as
# a blank window.
os.environ["TMUX_TMPDIR"] = tempfile.mkdtemp()
os.environ.pop("TMUX", None)
loader = importlib.machinery.SourceFileLoader("ad", ROOT + "/patched/bromure-agentd.py")
spec = importlib.util.spec_from_loader("ad", loader)
ad = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ad)
# Exactly what production does before it builds an attach command: the socket
# path is learned from the supervisor's status.json, not guessed.
ad._load_sandbox_status()

if ad.openshell_requested():
    ok("the workspace has an active spec, so this exercises the broken path")
else:
    bad("openshell_requested() is False; this is not the configuration that broke")

sock_path = (ad._SANDBOX or {}).get("tmux_socket")
if sock_path:
    ok("the supervisor published its tmux socket (%s)" % sock_path)
else:
    bad("no tmux_socket in status.json; the view command cannot be checked")
view_cmd = ad._view_attach_command("agent", None)
if sock_path and ("-S " + sock_path) in view_cmd:
    ok("the view command targets the supervisor's socket, not the default one")
else:
    bad("the view command does not name the supervisor's socket: %s"
        % view_cmd[:160])
# Every tmux word in it must carry -S. A single bare one is the whole bug: it
# looks for /tmp/tmux-<uid>/default, `has-session` fails, and the command
# `exit 1`s before printing a byte.
import re as _re
# `/` and `.` in the lookbehind: the socket PATH ends in `tmux.sock`, and the
# first version of this flagged that as a bare invocation -- a false positive
# on the very command it was meant to bless.
bare = [m.start() for m in _re.finditer(r'(?<![-\w/.])tmux(?! -S)', view_cmd)]
if bare:
    bad("%d bare `tmux` invocation(s) in the view command: %s"
        % (len(bare), [view_cmd[i:i + 40] for i in bare[:2]]))
else:
    ok("no bare `tmux` remains in the view command")

# And BEHAVIOURALLY, which the frame-level assertions below cannot do.
#
# `TMUX_TMPDIR` in this process does not reach the sandboxed child: it runs
# through the supervisor, which gives it an environment of its own. So with the
# bug present the child still found this workspace's real default-socket server
# and the attach "worked" -- 640 bytes of plausible output from the wrong
# server. Killing that server to force the issue is not an option; it is the
# user's session.
#
# So run the command's OWN guard -- the `has-session` that decides whether
# anything is printed at all -- in an environment where the default socket has
# no server. With the socket named it connects; with a bare `tmux` it cannot,
# `exit 1`s, and the user gets the blank window that was reported.
guard = view_cmd.split(";")[0]
empty_tmpdir = tempfile.mkdtemp()
probe = subprocess.run(["bash", "-c", guard],
                       env=dict(os.environ, TMUX_TMPDIR=empty_tmpdir),
                       capture_output=True, text=True, timeout=20)
if probe.returncode == 0:
    ok("its has-session guard succeeds with NO default-socket server in reach, "
       "so the attach gets as far as printing")
else:
    bad("the guard exits %d with no default-socket server (%s) -- this is the "
        "blank window: it fails before printing a byte"
        % (probe.returncode, (probe.stderr or "").strip()[:90]))


def attach(req, send=None, want=None, seconds=12):
    """Run one interactive request; return (error, output, exit_code)."""
    a, b = socket.socketpair()
    box = {}
    def run():
        try:
            ad._run_interactive(a, req)
        except Exception as exc:
            box["err"] = "%s: %s" % (type(exc).__name__, exc)
    t = threading.Thread(target=run, daemon=True)
    t.start()
    b.settimeout(1)
    data, code, buf = b"", None, b""
    deadline = time.time() + seconds
    sent = False
    while time.time() < deadline and code is None:
        try:
            chunk = b.recv(65536)
        except socket.timeout:
            chunk = b""
        except OSError:
            break
        if chunk:
            buf += chunk
            while len(buf) >= 5:
                ftype = buf[0]
                flen = struct.unpack(">I", buf[1:5])[0]
                if len(buf) < 5 + flen:
                    break
                payload, buf = buf[5:5 + flen], buf[5 + flen:]
                if ftype == ad.FRAME_DATA:
                    data += payload
                elif ftype == ad.FRAME_EXIT:
                    code = struct.unpack(">i", payload[:4])[0]
        if send and not sent and data:
            b.sendall(bytes([ad.FRAME_DATA]) + struct.pack(">I", len(send)) + send)
            sent = True
        if want and want in data:
            # `shutdown(SHUT_WR)`, not a FRAME_EOF. Measured: FRAME_EOF does
            # NOT end the session -- its `break` is inside the frame-PARSING
            # loop, not the pump loop, so it only stops reading the rest of
            # that batch. Half-closing is what the pump actually reacts to: the
            # recv returns b"" and it treats it as the host hanging up, which
            # is also what a real client disconnect looks like. Keeping the read
            # side open is what lets the FRAME_EXIT still be observed.
            b.shutdown(socket.SHUT_WR)
            want = None
    t.join(4)
    try:
        b.close()
    except OSError:
        pass
    return box.get("err"), data, code

# 1. A plain interactive request with a command -- the simplest shape, and the
#    one that proves `proc` is bound and waited on.
err, data, code = attach({"interactive": True, "cmd": "echo BROMURE-ATTACH-SPEC"})
if err:
    bad("plain interactive raised %s" % err)
else:
    ok("plain interactive ran with no exception (this is the NameError's home)")
if b"BROMURE-ATTACH-SPEC" in data:
    ok("and its output came back over the frame protocol")
else:
    bad("no output: %r" % data[-160:])
if code == 0:
    ok("and it ended with exit code 0")
else:
    bad("exit code was %r, expected 0" % code)

# 2. A host ATTACH -- `view`, which is what the window sends and what the user
#    saw fail. It must get a prompt, run a typed command, and exit cleanly.
err, data, code = attach({"interactive": True, "view": "agent"},
                         send=b"echo BROMURE-TYPED-OK\n",
                         want=b"BROMURE-TYPED-OK", seconds=30)
if err:
    bad("the host attach raised %s" % err)
else:
    ok("a host attach (view) ran with no exception")
if data:
    ok("the attach produced terminal output (%d bytes)" % len(data))
else:
    bad("the attach produced no bytes at all -- this is what the user saw")
if b"BROMURE-TYPED-OK" in data:
    ok("a typed command ran in the attached session and its output came back")
else:
    bad("the typed command produced no output: %r" % data[-200:])
if code is not None:
    ok("the session ended with an exit code (%d), not by hanging" % code)
else:
    bad("no FRAME_EXIT: the host would retry the attach forever")

sys.exit(1 if fails else 0)
PYEOF
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s\n" "$rc"; }

[ -n "$ATTACH_SUP" ] && sudo kill "$ATTACH_SUP" 2>/dev/null
kill_tmux_under "$ATTACH_W"

# --- and with NO spec, where `proc` was unbound on every path too ---------
rm -f "$ATTACH_W/meta/openshell-sandbox.json"
ROOT="$ROOT" ATTACH_W="$ATTACH_W" python3 - <<'PYEOF'
import importlib.machinery, importlib.util, os, socket, struct, sys, threading, time

ROOT, W = os.environ["ROOT"], os.environ["ATTACH_W"]
os.environ["BROMURE_META"] = W + "/meta"
os.environ["BROMURE_RUN_DIR"] = W + "/run"
loader = importlib.machinery.SourceFileLoader("ad", ROOT + "/patched/bromure-agentd.py")
spec = importlib.util.spec_from_loader("ad", loader)
ad = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ad)
fails = 0
if ad.openshell_requested():
    print("  FAIL a spec is still active; this is not the no-spec case"); fails += 1
else:
    print("  ok   no spec, so this takes the pty.fork path")

a, b = socket.socketpair()
box = {}
def run():
    try:
        ad._run_interactive(a, {"interactive": True, "cmd": "echo BROMURE-ATTACH-PLAIN"})
    except Exception as exc:
        box["err"] = "%s: %s" % (type(exc).__name__, exc)
t = threading.Thread(target=run, daemon=True); t.start()
b.settimeout(1)
data, code, buf = b"", None, b""
deadline = time.time() + 10
while time.time() < deadline and code is None:
    try:
        chunk = b.recv(65536)
    except socket.timeout:
        continue
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
    while len(buf) >= 5:
        ftype = buf[0]
        flen = struct.unpack(">I", buf[1:5])[0]
        if len(buf) < 5 + flen:
            break
        payload, buf = buf[5:5 + flen], buf[5 + flen:]
        if ftype == ad.FRAME_DATA:
            data += payload
        elif ftype == ad.FRAME_EXIT:
            code = struct.unpack(">i", payload[:4])[0]
t.join(4)
if box.get("err"):
    print("  FAIL no-spec interactive raised %s" % box["err"]); fails += 1
else:
    print("  ok   no-spec interactive ran with no exception")
if b"BROMURE-ATTACH-PLAIN" in data:
    print("  ok   and its output came back")
else:
    print("  FAIL no output: %r" % data[-160:]); fails += 1
if code == 0:
    print("  ok   and it exited 0")
else:
    print("  FAIL exit code %r" % code); fails += 1
sys.exit(1 if fails else 0)
PYEOF
rc=$?; [ $rc -eq 0 ] || { fails=$((fails + 1)); printf "  FAIL the block above exited %s\n" "$rc"; }
sudo rm -rf "$ATTACH_W"

# --- no shell command string in agentd starts a bare `tmux` --------------
# `_tmux_argv`'s docstring already claimed "every tmux invocation in this file
# goes through here". It was false of `_view_attach_command`, and the claim is
# what stopped anyone checking. Now the claim is checked.
#
# AST-based, not grep: the first version matched `log("tmux %s timed out ...")`
# and a docstring, so it reported four failures that were all prose. A checker
# that cries wolf gets ignored, which is worse than not having it.
if python3 "$HERE/check_tmux_socket.py" "$ROOT/patched/bromure-agentd.py" \
        > "$WORK/tmuxcheck.log" 2>&1; then
    ok "no shell command string in agentd starts a bare \`tmux\`"
else
    bad "a tmux command is built without the sandbox socket:"
    sed 's/^/       /' "$WORK/tmuxcheck.log"
fi

# --- the sentry suites must not contradict themselves --------------------
# `test_sentry.sh` listed `connect` in DRIVEN ("required to appear") while its
# own retired-kinds check required it never to appear. The suite asserted both,
# and because it cannot run on a locked-down VM the contradiction survived two
# rounds until someone else's fresh-VM run hit it.
#
# Checked HERE, in the suite that does run on this VM, precisely because the
# suite it checks cannot. Needs no module and no kernel.
if python3 "$HERE/check_kind_consistency.py" "$HERE/test_sentry.sh" \
        > "$WORK/kinds.log" 2>&1; then
    ok "the sentry suite does not require a kind to fire and to be absent"
else
    bad "the sentry suite contradicts itself:"
    sed 's/^/       /' "$WORK/kinds.log"
fi

# --- and the shape itself, so this class cannot come back silently --------
# A name read in a `finally`/`except` that the function never binds. The bug
# above is exactly that, and it is invisible until the branch runs.
if python3 "$HERE/check_unbound.py" \
        "$ROOT/patched/bromure-agentd.py" "$ROOT/patched/bromure-attestd.py" \
        "$ROOT/bromure-sandboxd" "$ROOT/bromure-sentryd" \
        "$ROOT/bromure_openshell.py" "$ROOT/bromure_sandbox_status.py" \
        > "$WORK/unbound.log" 2>&1; then
    ok "no name is read in a finally/except that its function never binds"
else
    bad "a name is read in a finally/except but never bound:"
    sed 's/^/       /' "$WORK/unbound.log"
fi

printf '\n%s\n' "$([ "$fails" -eq 0 ] && echo "ALL SANDBOX TESTS PASSED" || echo "$fails CHECK(S) FAILED")"
exit $((fails > 0))
