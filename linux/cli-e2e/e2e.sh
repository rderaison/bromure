#!/bin/bash
# e2e.sh <bromure-ac>: the CLI's `workspaces`, `trace` and `remote key` commands
# (ported from macOS) against a private daemon (temp XDG dirs; no VM; no network).
# PASS/FAIL per step, exit 0 when all pass.
set -uo pipefail
BIN=${1:?bromure-ac binary}
W=$(mktemp -d /tmp/acl-cli.XXXXXX)
DPID=""
cleanup() { [ -n "$DPID" ] && kill "$DPID" 2>/dev/null; sleep 0.5; [ -n "$DPID" ] && kill -9 "$DPID" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
export XDG_RUNTIME_DIR=$W/run XDG_STATE_HOME=$W/state XDG_DATA_HOME=$W/data XDG_CONFIG_HOME=$W/config
export BROMURE_SENTRY_CATALOG_BASE=http://127.0.0.1:9/
export BROMURE_IMAGE_CATALOG_BASE=http://127.0.0.1:9/
export BROMURE_MODELS_FETCH=0
unset BROMURE_AC_API_KEY BROMURE_AC_CONTROL_SOCKET
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
"$BIN" daemon > "$W/daemon.log" 2>&1 & DPID=$!
for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/bromure-ac/control.sock" ] && break; sleep 0.1; done
fails=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
run() { timeout 30 "$BIN" "$@" < /dev/null; }
expect() {   # expect <label> <rc> <grep-regex> <cmd...>: exit status and output
  local label=$1 want=$2 re=$3; shift 3
  local out rc; out=$(run "$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && printf '%s' "$out" | grep -Eq "$re"; then ok "$label"
  else bad "$label: rc $rc (want $want): $(printf "%s" "$out" | tail -6)"; fi
}
expect "ls with no workspaces" 0 "No workspaces" workspaces ls
expect "create" 0 "Created workspace cli-e2e" workspaces create --name cli-e2e --tool claude --auth token --color teal
expect "ls lists it, off" 0 "cli-e2e +claude +token +off" workspaces ls
expect "describe" 0 "cli-e2e" workspaces describe cli-e2e
# edit through $VISUAL: a script that changes the color in the JSON
cat > "$W/ed.sh" <<'ED'
#!/bin/sh
sed -i 's/"teal"/"purple"/' "$1"
ED
chmod +x "$W/ed.sh"
out=$(VISUAL="$W/ed.sh" timeout 30 "$BIN" workspaces edit cli-e2e < /dev/null 2>&1)
if curl -s --max-time 5 --unix-socket "$XDG_RUNTIME_DIR/bromure-ac/control.sock" "http://localhost/profiles/cli-e2e?full=1" | grep -q '"purple"'; then
  ok "edit in \$VISUAL saved"; else bad "edit: $out"; fi
[ -z "$(ls -A "$XDG_RUNTIME_DIR/bromure-ac/editor" 2>/dev/null)" ] && ok "the edit's file is gone" || bad "edit file left behind"
expect "ssh-keygen prints a public key" 0 "ssh-ed25519 " workspaces ssh-keygen cli-e2e
expect "ports: not running" 64 "isn't running" workspaces ports cli-e2e
expect "reboot: not running is an error" 64 "(not running|isn.t running|Couldn.t reboot)" workspaces reboot cli-e2e
expect "fsck without a disk" 64 "No system disk image for .cli-e2e." workspaces fsck cli-e2e
expect "trace ls" 0 "^No trace records\\. \\(Tracing is per-workspace" trace ls
expect "trace summary" 0 "^No trace records\\.$" trace summary
ssh-keygen -q -t ed25519 -N '' -C cli-e2e-key -f "$W/key"
expect "remote key add (a .pub path)" 0 "Added key: SHA256:" remote key add "$W/key.pub"
expect "remote key ls" 0 "^\\[1\\] SHA256:.* cli-e2e-key" remote key ls
expect "remote status (macOS's lines)" 0 "Remote access: (ENABLED|disabled)" remote status
expect "remote key rm 1" 0 "^Removed\\.$" remote key rm 1
expect "rm --force" 0 "(Deleted|Removed) .*cli-e2e" workspaces rm cli-e2e --force
expect "ls: gone" 0 "No workspaces" workspaces ls
# A running VM's details: /profiles names it in uppercase, /vms in lowercase
# (the Linux daemon's ids); `ls` and `describe` must still pair them.
FAKE=$W/fake.sock
python3 -I -B "$(cd "$(dirname "$0")" && pwd)/fake_daemon.py" "$FAKE" & FPID=$!
for i in $(seq 1 50); do [ -S "$FAKE" ] && break; sleep 0.1; done
out=$(BROMURE_AC_CONTROL_SOCKET=$FAKE timeout 20 "$BIN" workspaces ls < /dev/null 2>&1); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -Eq "fake-ws +claude +token +running +1h2m +detached" \
   && printf '%s' "$out" | grep -q "└─ claude (0) \*" && printf '%s' "$out" | grep -q "└─ shell (1)"; then
  ok "ls pairs a running VM across id case (uptime, window, tabs)"
else bad "ls across id case: rc $rc: $out"; fi
out=$(BROMURE_AC_CONTROL_SOCKET=$FAKE timeout 20 "$BIN" workspaces describe fake-ws < /dev/null 2>&1); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "── runtime ──" && printf '%s' "$out" | grep -q "10.0.0.7"; then
  ok "describe shows the runtime section across id case"
else bad "describe across id case: rc $rc: $out"; fi
rm -f "$FAKE"; wait "$FPID" 2>/dev/null
[ $fails -eq 0 ] && { echo "PASS cli e2e"; exit 0; } || { echo "FAIL cli e2e ($fails)"; exit 1; }
