#!/bin/bash
# e2e-single-user.sh — one user's day with a Linux server, driven through the
# control socket the way the Mac fat client drives it (its routes, its JSON):
#   1. a fresh daemon has its first workspace (ensureFirstWorkspace)
#   2. create a workspace (POST /profiles), its row as a client reads it
#   3. start it, exec in it, start an agent session (POST /agent-sessions/start)
#      and see the agent's tab and process in the guest
#   4. suspend and resume it: the guest's uptime and a file survive
#   5. stop the daemon (SIGTERM) with the VM running: it's suspended by its
#      close action; a new daemon shows it suspended and resumes it
#   6. shut it down (DELETE action shutdown), delete it
# A private daemon (its own XDG dirs), the user's image read only. Bounded
# steps, teardown on exit, PASS/FAIL. Needs KVM (or passwordless sudo -g kvm),
# the release build and the baked image; never reaches real hosts beyond what
# the guest itself does.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/.." && pwd)
if [ ! -w /dev/kvm ] && sudo -n -g kvm true 2>/dev/null && [ -z "${ACL_E2E_ELEVATED:-}" ]; then
  exec sudo -n -g kvm env PATH="$PATH" HOME="$HOME" ACL_E2E_ELEVATED=1 OUT="${OUT:-}" BROMURE_AC_IMAGE="${BROMURE_AC_IMAGE:-}" "$0" "$@"
fi
BIN=$ROOT/linux/ACLinux/.build/release/bromure-ac
[ -x "$BIN" ] || { echo "FAIL build it first: swift build --package-path linux/ACLinux -c release --product bromure-ac"; exit 1; }
command -v curl >/dev/null || { echo "FAIL curl needed"; exit 1; }
OUT=${OUT:-$(mktemp -d /tmp/acl-e2e-out.XXXXXX)}; mkdir -p "$OUT"
W=$(mktemp -d /tmp/acl-e2e.XXXXXX)         # short: it holds the daemon's sockets
case "$W" in /tmp/acl-e2e.??????) ;; *) echo "FAIL unexpected work dir $W"; exit 1 ;; esac
export XDG_RUNTIME_DIR=$W/run XDG_STATE_HOME=$W/state XDG_CONFIG_HOME=$W/config
export BROMURE_AC_IMAGE=${BROMURE_AC_IMAGE:-${XDG_DATA_HOME:-$HOME/.local/share}/bromure-ac/image-amd64} XDG_DATA_HOME=$W/data
export BROMURE_SENTRY_CATALOG_BASE=http://127.0.0.1:9/ BROMURE_IMAGE_CATALOG_BASE=http://127.0.0.1:9/ BROMURE_MODELS_FETCH=0
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
SOCK=$XDG_RUNTIME_DIR/bromure-ac/control.sock
FAILS=0
log()  { echo "[e2e $(date +%T)] $*"; }
pass() { log "PASS $*"; }
fail() { log "FAIL $*"; FAILS=$((FAILS + 1)); }
api()  { curl -s --max-time "${T:-60}" --unix-socket "$SOCK" -X "$1" -H 'Content-Type: application/json' ${3:+-d "$3"} "http://localhost$2"; }
js()   { python3 -I -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }
cli()  { timeout "${T:-120}" "$BIN" "$@"; }

DAEMON=
start_daemon() {
  BROMURE_AGENTD="$ROOT/Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py" "$BIN" daemon >> "$OUT/daemon.log" 2>&1 &
  DAEMON=$!
  for _ in $(seq 150); do [ -S "$SOCK" ] && api GET /state >/dev/null 2>&1 && return 0; sleep 0.2; done
  return 1
}
stop_daemon() {   # SIGTERM, bounded by the unit's 120 s
  [ -n "$DAEMON" ] || return 0
  kill -TERM "$DAEMON" 2>/dev/null
  for _ in $(seq 1300); do kill -0 "$DAEMON" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$DAEMON" 2>/dev/null && { kill -KILL "$DAEMON"; fail "daemon still up 130 s after SIGTERM"; }
  wait "$DAEMON" 2>/dev/null; DAEMON=
}
cleanup() {
  [ -n "$DAEMON" ] && { cli vm kill --force e2e >/dev/null 2>&1; kill -TERM "$DAEMON" 2>/dev/null; wait "$DAEMON" 2>/dev/null; }
  case "$W" in /tmp/acl-e2e.??????) rm -rf "$W" ;; esac
}
trap cleanup EXIT
state_of() { api GET /state | js "[w['state'] for w in d['workspaces'] if w['name']=='e2e'][0]" 2>/dev/null; }
wait_state() {  # wait_state <state> <seconds>
  for _ in $(seq $(($2 * 2))); do [ "$(state_of)" = "$1" ] && return 0; sleep 0.5; done; return 1
}
gx() { T=60 api POST "/vms/$ID/exec" "{\"command\": $(python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"), \"timeout\": 30}"; }

log "out: $OUT"
start_daemon || { fail "daemon didn't come up"; tail -20 "$OUT/daemon.log"; exit 1; }

# 1. the first workspace
FIRST=$(api GET /state | js "[w['name'] for w in d['workspaces']]")
case "$FIRST" in *"Default workspace"*) pass "a fresh daemon has its first workspace ($FIRST)" ;; *) fail "no first workspace: $FIRST" ;; esac

# 2. create a workspace, as the client's New Workspace sheet
R=$(api POST /profiles '{"name": "e2e", "tool": "claude", "authMode": "subscription", "comments": "e2e notes", "color": "green"}')
ID=$(echo "$R" | js "d['id'].lower()" 2>/dev/null) || { fail "create: $R"; exit 1; }
pass "created e2e ($ID)"
ROW=$(api GET /state | js "[w for w in d['workspaces'] if w['name']=='e2e'][0]")
for k in "'tool': 'claude'" "'comments': 'e2e notes'" "'color': 'green'" "'state': 'off'" "readyTools"; do
  case "$ROW" in *"$k"*) ;; *) fail "row lacks $k: $ROW" ;; esac
done
pass "its row: tool, notes, color, state, readyTools"

# 3. start, exec, an agent
T=300 api POST "/vms/$ID/start" '{}' > "$OUT/start.json"
wait_state running 240 && pass "running" || { fail "not running: $(cat "$OUT/start.json")"; exit 1; }
OUTX=$(gx 'echo hello-$(id -un); echo e2e-mark > ~/e2e-mark')
case "$OUTX" in *hello-ubuntu*) pass "exec as ubuntu" ;; *) fail "exec: $OUTX" ;; esac
SID=$(api POST /agent-sessions/start "{\"profile\": \"$ID\", \"tool\": \"claude\", \"cwd\": \"~\"}" | js "d['id']") \
  && pass "agent session started ($SID)" || fail "agent session didn't start"
TABS=
for _ in $(seq 90); do
  TABS=$(api GET /state | js "[len(v['tabs']) for v in d['vms'] if v['id'].lower()=='$ID'][0]" 2>/dev/null)
  [ "${TABS:-0}" -ge 2 ] && break; sleep 1
done
[ "${TABS:-0}" -ge 2 ] && pass "the agent's tab is up ($TABS tabs)" || fail "no agent tab ($TABS)"
# The agent's own process (its comm is claude, or node running claude), not
# this exec's shell whose command line names it.
AGENT='ps -eo pid=,comm=,args= | awk '"'"'$2=="claude" || ($2=="node" && $0 ~ /claude/) {print}'"'"''
for _ in $(seq 30); do gx "$AGENT" > "$OUT/agent.json"; grep -q '"stdout" *: *"[^"]' "$OUT/agent.json" && break; sleep 1; done
grep -q '"stdout" *: *"[^"]' "$OUT/agent.json" && pass "claude runs in the guest ($(js "d['stdout'].strip()[:80]" < "$OUT/agent.json"))" \
  || fail "claude not running in the guest: $(cat "$OUT/agent.json")"
api GET /state | js "[s for s in d.get('agentSessions', []) if s.get('id')=='$SID']" | grep -q "$SID" \
  && pass "the session is in /state" || fail "the session isn't in /state"

# 4. suspend and resume
UP1=$(gx 'cat /proc/uptime' | grep -o '"stdout" *: *"[0-9.]*' | grep -o '[0-9.]*$')
R=$(T=200 api DELETE "/vms/$ID" '{"action": "suspend"}')
wait_state suspended 120 && pass "suspended" || fail "not suspended: $R"
T=300 api POST "/vms/$ID/start" '{}' > "$OUT/resume.json"
wait_state running 240 && pass "resumed" || fail "not resumed: $(cat "$OUT/resume.json")"
UP2=$(gx 'cat /proc/uptime' | grep -o '"stdout" *: *"[0-9.]*' | grep -o '[0-9.]*$')
python3 -I -c "import sys; sys.exit(0 if float(sys.argv[2]) >= float(sys.argv[1]) else 1)" "${UP1:-0}" "${UP2:-0}" \
  && pass "the guest's uptime went on ($UP1 -> $UP2 s): a resume, not a boot" || fail "uptime $UP1 -> $UP2: rebooted?"
gx 'cat ~/e2e-mark' | grep -q e2e-mark && pass "its files are there" || fail "file lost on resume"
gx "$AGENT" | grep -q '"stdout" *: *"[^"]' && pass "the agent is still running after the resume" || fail "the agent died with the suspend"

# 5. the daemon stopped with the VM running, then started again
stop_daemon
pass "daemon stopped (SIGTERM) with e2e running"
start_daemon || { fail "daemon didn't come back"; exit 1; }
[ "$(state_of)" = suspended ] && pass "e2e suspended by its close action" || fail "after the restart e2e is $(state_of)"
T=300 api POST "/vms/$ID/start" '{}' > "$OUT/resume2.json"
wait_state running 240 && pass "resumed after the restart" || fail "not resumed: $(cat "$OUT/resume2.json")"
gx 'cat ~/e2e-mark' | grep -q e2e-mark && pass "its files are there after the restart" || fail "file lost after the restart"
gx "$AGENT" | grep -q '"stdout" *: *"[^"]' && pass "the agent is still running after the restart" || fail "the agent died across the daemon restart"
api GET /state | js "[s for s in d.get('agentSessions', []) if s.get('id')=='$SID']" | grep -q "$SID" \
  && pass "its session is still in /state" || fail "the session is gone after the restart"

# 6. shut down, delete
R=$(T=120 api DELETE "/vms/$ID" '{"action": "shutdown"}')
wait_state off 90 && pass "shut down" || fail "not off: $R"
R=$(api DELETE "/profiles/$ID")
api GET /state | js "[w['name'] for w in d['workspaces']]" | grep -q "'e2e'" && fail "not deleted: $R" || pass "deleted"

[ "$FAILS" = 0 ] && { log "PASS (logs: $OUT)"; exit 0; } || { log "FAIL: $FAILS check(s) (logs: $OUT)"; exit 1; }
