#!/bin/bash
# sweep.sh <bromure-ac>: every CLI command, with its options, against a private
# daemon (temp XDG dirs, no image, no network: every remote base is 127.0.0.1:9).
# Flags a command whose daemon route is missing ("Not found" for the route),
# that crashes, or that prints usage for a runtime failure. PASS/FAIL, exit 0 when clean.
set -uo pipefail
BIN=${1:?bromure-ac binary}
W=$(mktemp -d /tmp/acl-sweep.XXXXXX)   # short: unix socket paths stop at 107 bytes
DPID=""
cleanup() { [ -n "$DPID" ] && kill "$DPID" 2>/dev/null; sleep 0.5; [ -n "$DPID" ] && kill -9 "$DPID" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
export XDG_RUNTIME_DIR=$W/run XDG_STATE_HOME=$W/state XDG_DATA_HOME=$W/data XDG_CONFIG_HOME=$W/config HOME=$W/home
export BROMURE_SENTRY_CATALOG_BASE=http://127.0.0.1:9/ BROMURE_IMAGE_CATALOG_BASE=http://127.0.0.1:9/ BROMURE_MODELS_FETCH=0
unset BROMURE_AC_API_KEY BROMURE_AC_CONTROL_SOCKET
mkdir -p "$XDG_RUNTIME_DIR" "$HOME"; chmod 700 "$XDG_RUNTIME_DIR"
export BROMURE_AC_CONTROL_SOCKET=$XDG_RUNTIME_DIR/bromure-ac/control.sock
timeout 600 "$BIN" daemon > "$W/daemon.log" 2>&1 & DPID=$!
for i in $(seq 1 150); do [ -S "$BROMURE_AC_CONTROL_SOCKET" ] && break; sleep 0.1; done
[ -S "$BROMURE_AC_CONTROL_SOCKET" ] || { echo "FAIL daemon didn't start"; tail "$W/daemon.log"; exit 1; }
fails=0
c() {   # c <cmd...>: runs it; any rc is fine, but not a missing route, a crash, or usage for a runtime failure
  local out rc; out=$(timeout 40 "$BIN" "$@" < /dev/null 2>&1); rc=$?
  local why=""
  printf '%s' "$out" | grep -Eq '(^|: )Not found($|\b)|\(404\)' && why="missing route"
  [ "$rc" -ge 124 ] && why="rc $rc (crash/timeout)"
  [ "$rc" = 64 ] && why="usage error"
  if [ -n "$why" ]; then echo "FAIL [$why] $*: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"; fails=$((fails+1))
  else echo "ok   [rc $rc] $*: $(printf '%s' "$out" | head -1 | cut -c1-110)"; fi
}
ssh-keygen -q -t ed25519 -N '' -C sweep -f "$W/k" >/dev/null
c workspaces ls
c workspaces create --name sw --tool claude --auth token --memory 4 --color teal --generate-ssh
mkdir -p "$W/share"; c workspaces create --name sw2 --tool codex --auth token -v "$W/share"
printf '{"name":"sw3","tool":"claude"}' > "$W/p.json"
c workspaces create --from-json "$W/p.json"
printf '{"name":"sw","tool":"claude","color":"purple"}' > "$W/e.json"; c workspaces edit sw --from-json "$W/e.json"
c workspaces describe sw
c workspaces ssh-keygen sw
c workspaces ports sw
c workspaces ports sw --listening
c workspaces fsck sw
c workspaces fsck sw --repair
c workspaces fsck sw --home
c workspaces fusion status sw
c workspaces reboot sw
c workspaces reboot sw --hard
c workspaces exec sw -- true
c workspaces exec --timeout 5 sw -- true
c workspaces attach sw
c workspaces kill sw
c workspaces kill sw --suspend
c workspaces kill sw --force
c workspaces run sw -d
c vm ls
c vm ls --json
c vm run sw -d
c vm run --name tmp1 --tool claude --rm -d --memory-gb 4 --cpus 2 --home-gb 20
c vm exec sw -- true
c vm kill sw
c vm suspend sw
c vm resume sw
c vm start sw
c vm start sw --home-gb 30
c vm routing local sw
c vm rm sw2
c model use some-model sw
c trace ls
c trace ls sw --limit 5
c trace summary sw
c trace hostnames sw
c trace leaks sw
c trace clear -f
c image info
c remote status
c remote status --json
c remote key add "$W/k.pub"
c remote key ls
c remote key rm 1
c remote add-key "$W/k.pub"
c remote add-key "$(cat "$W/k2.pub" 2>/dev/null || cat "$W/k.pub")"
c remote rm-key "$(ssh-keygen -lf "$W/k.pub" | cut -d" " -f2)"
c remote code
c remote code --minutes 5
c remote enable --port 0 --bind 127.0.0.1
c remote enable --port 0 --bind 127.0.0.1 --no-password --allow-account-password
c remote disable
c account status
c account status --json
c account sync
c account sign-out
c cloud status
c cloud status --json
c cloud enroll --server-url http://127.0.0.1:9 --device-name sweep
c cloud unenroll
c cloud unenroll --force
c ssh-key ls sw
c ssh-key ls sw --json
ssh-keygen -q -t ed25519 -N '' -C sweep2 -f "$W/k2" >/dev/null
c ssh-key import sw "$W/k2" --label sweep2
KID=$(timeout 20 "$BIN" ssh-key ls sw < /dev/null 2>/dev/null | awk '/sweep2/{print $1; exit}')
c ssh-key approve sw "$KID" --ask
c ssh-key approve sw "$KID" --no-ask
c ssh-key rm sw "$KID"
c ssh-key add-agent sw --list
c admin list
c admin p2p on
c admin pool list
c workspaces rm sw3 -f
c workspaces rm sw -f
# account sign-in reads its code from stdin; a link to a dead local API base
out=$(printf 'https://bromure.io/enroll?code=abc&api=http%%3A%%2F%%2F127.0.0.1%%3A9\n' | timeout 40 "$BIN" account sign-in 2>&1); rc=$?
case $rc in 0|1) echo "ok   [rc $rc] account sign-in: $(printf '%s' "$out" | tail -1)";; *) echo "FAIL account sign-in rc $rc: $out"; fails=$((fails+1));; esac
[ "$fails" = 0 ] && echo "PASS sweep" || echo "FAIL sweep ($fails)"
[ "$fails" = 0 ]
