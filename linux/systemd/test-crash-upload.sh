#!/bin/bash
# test-crash-upload.sh [N]: N SIGKILLs of the daemon (default 30) while a guest
# uploads to the host at full rate, under systemd as bromure-ac.service runs it
# (transient system unit as this user with the kvm group, as test-unit-kvm.sh).
# Each kill is classified:
#   resumed  the upload's connection kept going after the restart
#   lost     it failed, and a new connection works (a fresh passt, or flows reset)
#   wedged   nothing moves and a new connection fails: never acceptable
# and passt is counted as kept (same pid) or replaced. Exit 1 on any wedged.
set -u
N=${1:-30}
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
BIN=$ROOT/linux/ACLinux/.build/release/bromure-ac
U=bromure-ac-crashup-$$
W=$(mktemp -d /tmp/acl-cu.XXXXXX); chmod 755 "$W"
export XDG_RUNTIME_DIR=$W/run XDG_STATE_HOME=$W/state XDG_CONFIG_HOME=$W/config
# A private data home too: no test daemon reads the user's subscription
# logins, model settings, engine key or secrets vault (~/.local/share); the
# image stays the user's (read only).
export BROMURE_AC_IMAGE=${BROMURE_AC_IMAGE:-${XDG_DATA_HOME:-$HOME/.local/share}/bromure-ac/image-amd64} XDG_DATA_HOME=$W/data
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
prop() { systemctl show "$U" -p "$1" --value; }
cli() { "$BIN" "$@"; }
CG=""
procs() { local c; c=$(prop ControlGroup); [ -n "$c" ] && CG=$c; [ -n "$CG" ] && cat "/sys/fs/cgroup$CG/cgroup.procs" 2>/dev/null; }
passt_pid() { for p in $(procs); do [[ $(cat /proc/$p/comm 2>/dev/null) == passt* ]] && echo $p; done | head -1; }
LAN=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
PORT=$((45000 + RANDOM % 2000))
python3 -c "
import socket, threading
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('$LAN', $PORT)); s.listen(64)
def h(c):
    try:
        while c.recv(1 << 20): pass
    except OSError: pass
while True:
    c, _ = s.accept(); threading.Thread(target=h, args=(c,), daemon=True).start()
" &
SINK=$!
cleanup() { sudo -n systemctl stop "$U" 2>/dev/null; sudo -n systemctl reset-failed "$U" 2>/dev/null; kill $SINK 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
sudo -n systemd-run -q --unit="$U" --uid="$(id -u)" --gid="$(id -g)" -p SupplementaryGroups=kvm \
  -p Type=notify -p NotifyAccess=main -p KillMode=process -p TimeoutStopSec=10 \
  -p Restart=on-failure -p RestartSec=2 -p FileDescriptorStoreMax=64 -p ExecStopPost="$BIN stop-post" \
  -p StartLimitBurst=1000 \
  --setenv=HOME="$HOME" --setenv=XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" --setenv=XDG_STATE_HOME="$XDG_STATE_HOME" \
    --setenv=XDG_DATA_HOME="$XDG_DATA_HOME" --setenv=XDG_CONFIG_HOME="$XDG_CONFIG_HOME" --setenv=BROMURE_AC_IMAGE="$BROMURE_AC_IMAGE" --setenv=BROMURE_SENTRY_CATALOG_BASE=http://127.0.0.1:9/ --setenv=BROMURE_IMAGE_CATALOG_BASE=http://127.0.0.1:9/ --setenv=BROMURE_MODELS_FETCH=0 \
  --setenv=BROMURE_AGENTD="$ROOT/Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py" "$BIN" daemon || exit 1
cli vm run -d --name cu >/dev/null && cli vm exec cu -- true || { echo "vm run failed"; exit 1; }
# The uploader: one connection at a time, 1 MiB writes; "<conn> <bytes> <time>"
# every 0.25 s, "err <conn> <exc> <time>" and a reconnect when one fails.
cli vm exec cu -- sh -c "nohup python3 -c \"
import socket, time
buf = bytes(1 << 20); conn = 0
while True:
    conn += 1; n = 0; t = 0
    try:
        s = socket.create_connection(('$LAN', $PORT), timeout=5); s.settimeout(5)
        while True:
            s.sendall(buf); n += len(buf)
            if time.time() - t >= 0.25:
                t = time.time(); open('/tmp/up.log', 'a').write('%d %d %.2f\\\\n' % (conn, n, t))
    except Exception as e:
        open('/tmp/up.log', 'a').write('err %d %s %.2f\\\\n' % (conn, type(e).__name__, time.time())); time.sleep(0.5)
\" >/dev/null 2>&1 &" >/dev/null
sleep 3
resumed=0; lost=0; wedged=0; kept=0; replaced=0; gaps=""
for i in $(seq "$N"); do
  P=$(passt_pid); M=$(prop MainPID); R=$(prop NRestarts)
  T=$(date +%s.%N)
  kill -9 "$M"
  for _ in $(seq 100); do [ "$(prop NRestarts)" -gt "$R" ] && [ "$(prop ActiveState)" = active ] && break; sleep 0.1; done
  ok=0; for _ in $(seq 40); do cli vm exec cu -- true 2>/dev/null && { ok=1; break; }; sleep 0.25; done
  # Up to 12 s for the upload to move again: a flow whose retransmit backoff
  # outlasts the uploader's 5 s timeout is lost (it reconnects at +5.5 s), not wedged.
  for w in $(seq 12); do
  sleep 1
  LOG=$(cli vm exec cu -- tail -c 20000 /tmp/up.log 2>/dev/null)
  verdict=$(python3 - "$T" "$LOG" <<'PY'
import sys
t, rows = float(sys.argv[1]), [l.split() for l in sys.argv[2].splitlines() if l.strip()]
data = [(int(r[0]), int(r[1]), float(r[2])) for r in rows if r[0].isdigit() and len(r) == 3]
before = [d for d in data if d[2] <= t]
after = [d for d in data if d[2] > t]
errs = [r for r in rows if r[0] == "err" and float(r[-1]) > t - 0.5]
if not before: print("unknown 0"); sys.exit()
c, b = before[-1][0], before[-1][1]
same = [d for d in after if d[0] == c and d[1] > b]
newer = [d for d in after if d[0] > c and d[1] > 0]
gap = (same[0][2] - t) if same else 0
print(("resumed %.1f" % gap) if same and not errs else ("lost 0" if newer else "wedged 0"))
PY
)
  [ "$w" -ge 3 ] && [ "${verdict%% *}" != wedged ] && break
  done
  P2=$(passt_pid)
  [ "$P2" = "$P" ] && kept=$((kept + 1)) || replaced=$((replaced + 1))
  case $verdict in resumed*) resumed=$((resumed + 1)); gaps="$gaps ${verdict#resumed }";; lost*) lost=$((lost + 1));; *) wedged=$((wedged + 1));; esac
  echo "kill $i: ${verdict%% *} (gap ${verdict#* }s), passt $P -> $P2, exec after restart: $ok"
  case $verdict in resumed*) ;; *) echo "    host kill time $T, guest now $(cli vm exec cu -- date +%s.%N 2>/dev/null)"
    echo "$LOG" | tail -4 | sed 's/^/    /';; esac
done
echo "CRASH-UPLOAD $N kills: resumed $resumed, lost $lost, wedged $wedged; passt kept $kept, replaced $replaced; resume gaps:$gaps"
journalctl -u "$U" --no-pager -o cat | grep -E "passt: adopted pid .* (answers|doesn't answer)" | sed 's/pid [0-9]*/pid N/' | sort | uniq -c
[ "$wedged" = 0 ]
