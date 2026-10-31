#!/bin/bash
# test-unit-kvm.sh: the daemon under real systemd, with real VMs, configured as
# bromure-ac.service is (Type=notify, KillMode=process, ExecStopPost=stop-post,
# FileDescriptorStoreMax, Restart=on-failure). A user unit can't open
# /dev/vhost-vsock until the kvm udev rule is in place, so this runs a
# transient *system* unit as this user with SupplementaryGroups=kvm (needs
# passwordless sudo for systemd-run/systemctl), removed at the end.
#
#   1. crash: SIGKILL the daemon. QEMU, passt and a TCP flow opened before
#      (one echo a second) all continue; the restarted daemon takes passt back
#      from the fd store and re-adopts the VM.
#   2. hung stop: SIGSTOP the daemon, then stop. Past TimeoutStopSec it's
#      SIGKILLed alone and stop-post ends QEMU and passt.
#   3. clean stop: the daemon's own shutdown; the cgroup is empty.
#
# Needs: the release bromure-ac (swift build -c release --product bromure-ac),
# the baked image, vsock port 5800 free. Prints PASS/FAIL lines; exit 1 on a FAIL.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
BIN=$ROOT/linux/ACLinux/.build/release/bromure-ac
U=bromure-ac-kvmtest-$$
W=$(mktemp -d /tmp/acl-uk.XXXXXX); chmod 755 "$W"
export XDG_RUNTIME_DIR=$W/run XDG_STATE_HOME=$W/state
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
STATUS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; STATUS=1; }
log() { echo "[unit-kvm $(date +%T)] $*"; }
sc() { sudo -n systemctl "$@"; }
prop() { systemctl show "$U" -p "$1" --value; }
cli() { "$BIN" "$@"; }
# The unit's cgroup, remembered while it exists (an inactive unit has none:
# "" would read the root cgroup's list).
CG=""
procs() { local c; c=$(prop ControlGroup); [ -n "$c" ] && CG=$c; [ -n "$CG" ] && cat "/sys/fs/cgroup$CG/cgroup.procs" 2>/dev/null; }
comm_of() { cat /proc/$1/comm 2>/dev/null; }
alive() { kill -0 "$1" 2>/dev/null; }

LAN=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
PORT=$((47000 + RANDOM % 2000))
python3 -c "
import socket, threading
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('$LAN', $PORT)); s.listen()
def h(c):
    while True:
        d = c.recv(64)
        if not d: return
        c.sendall(d)
while True:
    c, _ = s.accept(); threading.Thread(target=h, args=(c,), daemon=True).start()
" &
ECHO=$!
# A bulk source on PORT+1: zeros as fast as the guest takes them.
python3 -c "
import socket, threading
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('$LAN', $PORT + 1)); s.listen()
buf = bytes(1 << 16)
def h(c):
    try:
        while True: c.sendall(buf)
    except OSError: pass
while True:
    c, _ = s.accept(); threading.Thread(target=h, args=(c,), daemon=True).start()
" &
BULK=$!
cleanup() {
  sc stop "$U" 2>/dev/null; sc reset-failed "$U" 2>/dev/null
  kill $ECHO $BULK 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT

start_unit() {
  sudo -n systemd-run -q --unit="$U" --uid="$(id -u)" --gid="$(id -g)" -p SupplementaryGroups=kvm "$@" \
    -p Type=notify -p NotifyAccess=main -p KillMode=process -p TimeoutStopSec=5 \
    -p Restart=on-failure -p RestartSec=2 -p FileDescriptorStoreMax=4 \
    -p ExecStopPost="$BIN stop-post" \
    --setenv=HOME="$HOME" --setenv=XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" --setenv=XDG_STATE_HOME="$XDG_STATE_HOME" \
    --setenv=BROMURE_AGENTD="$ROOT/Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py" \
    "$BIN" daemon
}
qemu_pid() { for p in $(procs); do [[ $(comm_of $p) == qemu-system* ]] && echo $p; done | head -1; }
passt_pid() { for p in $(procs); do [[ $(comm_of $p) == passt* ]] && echo $p; done | head -1; }   # passt execs passt.avx2

# --- 1. crash
# KillSignal=SIGWINCH (ignored by the daemon) makes phase 2's stop hang for
# real: a SIGSTOPped daemon doesn't, since systemd sends SIGCONT with the
# kill signal.
start_unit -p KillSignal=SIGWINCH || { echo "systemd-run failed"; exit 1; }
[ "$(prop ActiveState)" = active ] && pass "unit active after READY" || fail "unit not active"
cli vm run --name uk >/dev/null && cli vm exec uk -- true || fail "vm run/exec"
cli vm exec uk -- sh -c "nohup python3 -c \"
import socket, time
s = socket.create_connection(('$LAN', $PORT), timeout=5); s.settimeout(5)
while True:
    try:
        s.sendall(b'x'); s.recv(1)
        open('/tmp/flow.log', 'a').write('ok %.1f\\n' % time.time())
    except Exception as e:
        open('/tmp/flow.log', 'a').write('err %s %.1f\\n' % (type(e).__name__, time.time()))
    time.sleep(1)
\" >/dev/null 2>&1 & sleep 2; tail -1 /tmp/flow.log" | grep -q ok && pass "flow up before the crash" || fail "flow not up"
# A download running across the crash: bytes received, every 0.5 s.
cli vm exec uk -- sh -c "nohup python3 -c \"
import socket, time
s = socket.create_connection(('$LAN', $PORT + 1), timeout=30); s.settimeout(30)
n, t = 0, time.time()
buf = bytearray(1 << 20)
while True:
    try:
        k = s.recv_into(buf)
    except Exception as e:
        open('/tmp/bulk.log', 'a').write('err %s %.1f\\n' % (type(e).__name__, time.time())); break
    if not k: open('/tmp/bulk.log', 'a').write('eof %.1f\\n' % time.time()); break
    n += k
    if time.time() - t >= 0.5:
        t = time.time(); open('/tmp/bulk.log', 'a').write('%d %.1f\\n' % (n, t))
\" >/dev/null 2>&1 &" >/dev/null
sleep 3
Q=$(qemu_pid); P=$(passt_pid); M=$(prop MainPID)
log "daemon $M, QEMU $Q, passt $P; fd store: $(sudo -n systemd-analyze fdstore "$U" 2>/dev/null | tail -n +2 | awk '{print $2}' | tr '\n' ' ')"
TKILL=$(date +%s.%N)
kill -9 "$M"
for _ in $(seq 100); do [ "$(prop NRestarts)" = 1 ] && [ "$(prop ActiveState)" = active ] && break; sleep 0.1; done
TBACK=$(date +%s.%N)
[ "$(prop NRestarts)" = 1 ] && pass "restarted after the crash ($(echo "$TBACK - $TKILL" | bc | cut -c1-4)s)" || fail "no restart"
alive "$Q" && pass "QEMU $Q survived" || fail "QEMU died"
alive "$P" && [ "$(passt_pid)" = "$P" ] && pass "passt $P survived and is still the uplink" || fail "passt replaced or gone (now $(passt_pid))"
journalctl -u "$U" --no-pager -o cat | grep -q 'took back passt' && pass "the new daemon took passt back from the fd store" || fail "no 'took back passt' in the journal"
journalctl -u "$U" --no-pager -o cat | grep -q 'took back the vsock :5800 listener' && pass "and the vsock listener" || fail "the vsock listener wasn't taken back"
journalctl -u "$U" --no-pager -o cat | grep -E 'took back|passt: adopted stream|stop-post:' | sed 's/^/    /'
for _ in $(seq 30); do cli vm exec uk -- true 2>/dev/null && break; sleep 0.5; done
[ "$(cli vm ls --json | python3 -c 'import json,sys; print([v["state"] for v in json.load(sys.stdin)["vms"] if v["name"]=="uk"][0])')" = running ] \
  && pass "the VM re-adopted (running)" || fail "VM not running after restart"
sleep 8
FLOW=$(cli vm exec uk -- cat /tmp/flow.log)
AFTER=$(echo "$FLOW" | awk -v t="$TKILL" '$NF > t')
echo "$AFTER" | sed 's/^/    flow after the kill: /' | head -12
OKS=$(echo "$AFTER" | grep -c '^ok'); ERRS=$(echo "$AFTER" | grep -c '^err')
LASTOK=$(echo "$AFTER" | grep '^ok' | tail -1)
[ "$ERRS" = 0 ] && [ "$OKS" -ge 5 ] && echo "$AFTER" | tail -1 | grep -q '^ok' \
  && pass "the flow opened before the crash resumed ($OKS echoes, 0 errors after the kill)" || fail "flow: $OKS ok, $ERRS err after the kill"
GAP=$(echo "$FLOW" | awk -v t="$TKILL" '$1=="ok" { if (prev && $NF > t && !done) { printf "%.1f", $NF - prev; done=1 } prev=$NF }')
log "longest echo gap across the crash: ${GAP}s"

BULK_LOG=$(cli vm exec uk -- cat /tmp/bulk.log)
python3 - "$TKILL" "$BULK_LOG" <<'PY2'
import sys
tkill, rows = float(sys.argv[1]), [l.split() for l in sys.argv[2].splitlines() if l.strip()]
pts = [(float(r[-1]), int(r[0])) for r in rows if r[0].isdigit()]
end = [r for r in rows if not r[0].isdigit()]
def rate(a, b):
    s = [p for p in pts if a <= p[0] <= b]
    return (s[-1][1] - s[0][1]) / (s[-1][0] - s[0][0]) / 1e6 if len(s) > 1 and s[-1][0] > s[0][0] else 0.0
last = pts[-1][0] if pts else 0
stall = max((b[0] - a[0] for a, b in zip(pts, pts[1:]) if b[0] > tkill - 1 and b[1] == a[1]), default=0)
print("    BULK before the kill %.0f MB/s; after it (to %.1fs) %.0f MB/s; last 3 s %.0f MB/s; %s"
      % (rate(tkill - 3, tkill), last - tkill, rate(tkill, last), rate(last - 3, last),
         " ".join(" ".join(r) for r in end) or "still running"))
PY2

# --- 2. hung stop
Q=$(qemu_pid); P=$(passt_pid)
T0=$(date +%s.%N)
sc stop "$U"
TS=$(echo "$(date +%s.%N) - $T0" | bc | cut -c1-4)
sleep 0.5
! alive "$Q" && ! alive "$P" && pass "hung stop (${TS}s): stop-post ended QEMU and passt" || fail "hung stop left QEMU alive=$(alive $Q && echo y) passt alive=$(alive $P && echo y)"
journalctl -u "$U" --no-pager -o cat | grep 'stop-post:' | tail -1 | sed 's/^/    /'
journalctl -u "$U" --no-pager -o cat | grep 'stop-post:' | tail -1 | grep -q 'SERVICE_RESULT=timeout job=[0-9]' \
  && pass "the stop timed out (a real hang) and stop-post swept" || fail "the stop didn't time out"
[ -z "$(procs)" ] && pass "cgroup empty" || fail "cgroup: $(procs)"
sc reset-failed "$U" 2>/dev/null

# --- 3. clean stop (and the re-adopted-then-killed VM is 'stopped' in the registry)
start_unit || fail "restart for the clean stop"
[ "$(cli vm ls --json | python3 -c 'import json,sys; print([v["state"] for v in json.load(sys.stdin)["vms"] if v["name"]=="uk"][0])')" = stopped ] \
  && pass "the VM ended by stop-post reads 'stopped'" || fail "registry state after stop-post"
cli vm start uk >/dev/null && cli vm exec uk -- true && pass "start again" || fail "vm start"
journalctl -u "$U" --no-pager -o cat | grep -c 'took back passt' | grep -q '^1$' && pass "a fresh start launched a new passt (store released at stop)" || fail "passt taken back after a full stop"
Q=$(qemu_pid); P=$(passt_pid)
sc stop "$U"
sleep 0.5
! alive "$Q" && ! alive "$P" && [ -z "$(procs)" ] && pass "clean stop: nothing left" || fail "clean stop left: $(procs)"
journalctl -u "$U" --no-pager -o cat | grep 'stop-post:' | tail -1 | sed 's/^/    /'
exit $STATUS
