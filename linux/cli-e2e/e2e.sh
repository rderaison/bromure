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
unset BROMURE_AC_API_KEY BROMURE_AC_CONTROL_SOCKET
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
"$BIN" daemon > "$W/daemon.log" 2>&1 & DPID=$!
for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/bromure-ac/control.sock" ] && break; sleep 0.1; done
fails=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
run() { timeout 30 "$BIN" "$@" < /dev/null; }
expect() {   # expect <label> <grep-regex> <cmd...>
  local label=$1 re=$2; shift 2
  local out; out=$(run "$@" 2>&1)
  if printf '%s' "$out" | grep -Eq "$re"; then ok "$label"; else bad "$label: $(printf '%s' "$out" | tail -3)"; fi
}
expect "ls with no workspaces" "No workspaces" workspaces ls
expect "create" "Created|cli-e2e" workspaces create --name cli-e2e --tool claude --auth token --color teal
expect "ls lists it, off" "cli-e2e +claude +token +off" workspaces ls
expect "describe" "cli-e2e" workspaces describe cli-e2e
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
expect "ssh-keygen prints a public key" "ssh-ed25519 " workspaces ssh-keygen cli-e2e
expect "ports: not running" "isn't running" workspaces ports cli-e2e
expect "reboot: not running is an error" "." workspaces reboot cli-e2e
expect "fsck without a disk" "No system disk image" workspaces fsck cli-e2e
expect "trace ls" "." trace ls
expect "trace summary" "." trace summary
ssh-keygen -q -t ed25519 -N '' -C cli-e2e-key -f "$W/key"
expect "remote key add (a .pub path)" "Added key" remote key add "$W/key.pub"
expect "remote key ls" "cli-e2e-key" remote key ls
expect "remote status (macOS's lines)" "Remote access:" remote status
expect "remote key rm 1" "Removed" remote key rm 1
expect "rm --force" "." workspaces rm cli-e2e --force
expect "ls: gone" "No workspaces" workspaces ls
[ $fails -eq 0 ] && { echo "PASS cli e2e"; exit 0; } || { echo "FAIL cli e2e ($fails)"; exit 1; }
