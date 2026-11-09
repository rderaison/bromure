#!/bin/bash
# e2e.sh <bromure-ac>: the shared remote menu (`__remote-menu`) against a
# private daemon (temp XDG dirs; no VM, loopback only): on a pty with only the
# SSH handler's passthrough env, then over the daemon's embedded SSH server
# with a throwaway key (the login forced into the menu). PASS/FAIL, exit 0/1.
set -uo pipefail
BIN=${1:?bromure-ac binary}
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d /tmp/acl-menu.XXXXXX)
DPID=""
cleanup() { [ -n "$DPID" ] && kill "$DPID" 2>/dev/null; sleep 0.5; [ -n "$DPID" ] && kill -9 "$DPID" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
export XDG_RUNTIME_DIR=$W/run XDG_STATE_HOME=$W/state XDG_DATA_HOME=$W/data XDG_CONFIG_HOME=$W/config
export BROMURE_SENTRY_CATALOG_BASE=http://127.0.0.1:9/
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
"$BIN" daemon > "$W/daemon.log" 2>&1 & DPID=$!
SOCK=$XDG_RUNTIME_DIR/bromure-ac/control.sock
for i in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || { echo "FAIL daemon socket never appeared"; tail -20 "$W/daemon.log"; exit 1; }
curl -s --max-time 5 --unix-socket "$SOCK" -X POST -H 'Content-Type: application/json' \
  -d '{"name":"menu-e2e-ws"}' http://localhost/profiles > "$W/create.json"
grep -q '"ok"\s*:\s*true' "$W/create.json" || { echo "FAIL profile create: $(cat "$W/create.json")"; exit 1; }
# The SSH handler's env for the menu: only the passthrough keys, as RemoteSSHHandlers builds it.
timeout 30 env -i TERM=xterm-256color PATH=/usr/bin:/bin HOME="$W" USER=menu LANG=en_US.UTF-8 \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XDG_STATE_HOME="$XDG_STATE_HOME" XDG_DATA_HOME="$XDG_DATA_HOME" \
  python3 -I -B "$HERE/drive.py" "$BIN"
rc=$?
[ $rc -eq 0 ] || { echo "FAIL remote menu e2e (rc $rc)"; exit $rc; }
# Over SSH: the daemon's embedded server forces the login into the menu, with
# only RemoteSSHHandlers' passthrough env. Loopback only; a throwaway key.
PORT=$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
ssh-keygen -q -t ed25519 -N '' -C menu-e2e -f "$W/key" || { echo "FAIL ssh-keygen"; exit 1; }
timeout 20 "$BIN" remote add-key "$(cat "$W/key.pub")" > "$W/addkey.log" 2>&1 || { echo "FAIL add-key: $(cat "$W/addkey.log")"; exit 1; }
timeout 20 "$BIN" remote enable --port "$PORT" --bind 127.0.0.1 --no-password > "$W/enable.log" 2>&1 || { echo "FAIL enable: $(cat "$W/enable.log")"; exit 1; }
for i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break; sleep 0.1; done
SSH="ssh -F /dev/null -tt -p $PORT -i $W/key -o IdentitiesOnly=yes -o UserKnownHostsFile=$W/known -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 $(id -un)@127.0.0.1"
timeout 40 python3 -I -B "$HERE/drive.py" --ssh $SSH
rc=$?
[ $rc -eq 0 ] && echo "PASS remote menu e2e" || echo "FAIL remote menu e2e (rc $rc)"
exit $rc
