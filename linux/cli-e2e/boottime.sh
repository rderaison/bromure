#!/usr/bin/env bash
# boottime.sh [boots]: how long a workspace takes to boot, as a user sees it:
# from `bromure-ac workspaces run <ws> --detach` until a command runs in it
# (one `bromure-ac vm exec <ws> -- true`, which waits for the guest's
# shell). Against a private daemon (temp dirs, this user, the installed
# image or BROMURE_AC_IMAGE) on the release build.
#
# The first boot is a new workspace's (its system disk is made, the home
# formatted, the agent's unit and the CA installed): reported, not judged.
# Then `boots` cold boots of that workspace, each after a full stop. PASS
# when every one of them is under BOOT_TARGET_MS (default 1000).
#
# Needs /dev/kvm, Firecracker, the image. Times are monotonic
# (/proc/uptime): the wall clock can step mid-run.
set -euo pipefail
BOOTS=${1:-8}
TARGET=${BOOT_TARGET_MS:-1000}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
BIN=${BIN:-$HERE/../ACLinux/.build/release/bromure-ac}
IMAGE=${BROMURE_AC_IMAGE:-/var/lib/bromure-ac-image}
[ -x "$BIN" ] || { echo "FAIL no $BIN (swift build -c release --product bromure-ac)"; exit 1; }
[ -f "$IMAGE/vmlinuz" ] || { echo "FAIL no image at $IMAGE"; exit 1; }
[ -r /dev/kvm ] && [ -w /dev/kvm ] || { echo "FAIL /dev/kvm"; exit 1; }

W=$(mktemp -d /tmp/acl-boot.XXXXXX)   # short: unix socket paths stop at 107 bytes
DPID=""
cleanup() {
    if [ -n "$DPID" ] && kill -0 "$DPID" 2>/dev/null; then
        kill -TERM "$DPID" 2>/dev/null || true
        for _ in $(seq 1 100); do kill -0 "$DPID" 2>/dev/null || break; sleep 0.1; done
        kill -KILL "$DPID" 2>/dev/null || true
    fi
    rm -rf "$W"
}
trap cleanup EXIT

export HOME=$W/home XDG_RUNTIME_DIR=$W/run XDG_STATE_HOME=$W/state XDG_CONFIG_HOME=$W/config XDG_CACHE_HOME=$W/cache
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
chmod 700 "$XDG_RUNTIME_DIR"
export BROMURE_AC_IMAGE=$IMAGE BROMURE_MODELS_FETCH=0
export BROMURE_AGENTD=$REPO/Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py BROMURE_AC_RESOURCES=$REPO/Sources/AgentCoding/Resources
export BROMURE_SENTRY_CATALOG_BASE=http://127.0.0.1:9/ BROMURE_IMAGE_CATALOG_BASE=http://127.0.0.1:9/
unset BROMURE_AC_API_KEY BROMURE_AC_CONTROL_SOCKET
export BROMURE_AC_CONTROL_SOCKET=$XDG_RUNTIME_DIR/bromure-ac/control.sock
timeout 1800 "$BIN" daemon > "$W/daemon.log" 2>&1 < /dev/null & DPID=$!
for _ in $(seq 1 150); do [ -S "$BROMURE_AC_CONTROL_SOCKET" ] && break; sleep 0.1; done
[ -S "$BROMURE_AC_CONTROL_SOCKET" ] || { echo "FAIL daemon didn't start"; tail "$W/daemon.log"; exit 1; }

ac() { timeout 60 "$BIN" "$@"; }
mono() { awk '{printf "%d", $1*1000}' /proc/uptime; }
boot() {
    local t0 t1
    t0=$(mono)
    ac workspaces run boot --detach >"$W/run.log" 2>&1 || { cat "$W/run.log" >&2; echo "FAIL run" >&2; exit 1; }
    ac vm exec boot -- true >"$W/exec.log" 2>&1 || { cat "$W/exec.log" >&2; echo "FAIL exec" >&2; exit 1; }
    t1=$(mono)
    echo $((t1 - t0))
}
stop() {
    ac vm kill boot >/dev/null 2>&1 || true
    for _ in $(seq 1 300); do ac vm ls 2>/dev/null | grep -E '\bboot\b' | grep -q stopped && return; sleep 0.1; done
    echo "FAIL the workspace didn't stop"; exit 1
}

echo sk-test-not-real | ac workspaces create --name boot --tool claude --auth token --api-key - >/dev/null
first=$(boot)
echo "first boot (new workspace): $first ms"
stop
worst=0; all=""
for i in $(seq 1 "$BOOTS"); do
    sleep 1
    ms=$(boot)
    all="$all $ms"
    [ "$ms" -gt "$worst" ] && worst=$ms
    stop
done
echo "cold boots (ms):$all"
echo "worst: $worst ms (target < $TARGET ms)"
[ "$worst" -lt "$TARGET" ] && echo PASS || { echo FAIL; exit 1; }
