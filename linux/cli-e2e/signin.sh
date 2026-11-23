#!/bin/bash
# signin.sh <bromure-ac>: `account sign-in` on a terminal against a private
# daemon and a fake bromure.io on 127.0.0.1 (fake_bromure_io.py; nothing
# leaves this machine): the link and user code shown, the poll, the
# approved code handed to the daemon's enroll; and, with no device grants
# there, the fallback to a pasted code. PASS/FAIL, exit 0 when all pass.
set -uo pipefail
BIN=${1:?bromure-ac binary}
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d /tmp/acl-signin.XXXXXX)   # short: unix socket paths stop at 107 bytes
DPID=""; FPID=""
cleanup() {
  for p in $DPID $FPID; do kill "$p" 2>/dev/null; done; sleep 0.5
  for p in $DPID $FPID; do kill -9 "$p" 2>/dev/null; done
  rm -rf "$W"
}
trap cleanup EXIT
command -v script >/dev/null || { echo "FAIL signin: needs script(1) for a terminal"; exit 1; }
export XDG_RUNTIME_DIR=$W/run XDG_STATE_HOME=$W/state XDG_DATA_HOME=$W/data XDG_CONFIG_HOME=$W/config HOME=$W/home
export BROMURE_SENTRY_CATALOG_BASE=http://127.0.0.1:9/ BROMURE_IMAGE_CATALOG_BASE=http://127.0.0.1:9/ BROMURE_MODELS_FETCH=0
unset BROMURE_AC_API_KEY
mkdir -p "$XDG_RUNTIME_DIR" "$HOME"; chmod 700 "$XDG_RUNTIME_DIR"
export BROMURE_AC_CONTROL_SOCKET=$XDG_RUNTIME_DIR/bromure-ac/control.sock
timeout 300 "$BIN" daemon > "$W/daemon.log" 2>&1 & DPID=$!
for i in $(seq 1 150); do [ -S "$BROMURE_AC_CONTROL_SOCKET" ] && break; sleep 0.1; done
[ -S "$BROMURE_AC_CONTROL_SOCKET" ] || { echo "FAIL signin: daemon didn't start"; tail "$W/daemon.log"; exit 1; }
fails=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

fake() {   # fake <mode>: (re)start the fake bromure.io; sets PORT
  [ -n "$FPID" ] && { kill "$FPID" 2>/dev/null; wait "$FPID" 2>/dev/null; }
  rm -f "$W/port" "$W/fake.log"
  timeout 120 python3 -I "$HERE/fake_bromure_io.py" "$W/port" "$W/fake.log" "$1" & FPID=$!
  for i in $(seq 1 50); do [ -s "$W/port" ] && break; sleep 0.1; done
  PORT=$(cat "$W/port" 2>/dev/null) || PORT=""
  [ -n "$PORT" ] || { bad "fake bromure.io didn't start"; exit 1; }
}
on_tty() {   # on_tty <stdin-file> <args...>: the CLI on a pseudo-terminal
  local input=$1; shift
  timeout 60 script -qec "$(printf '%q ' "$BIN" "$@")" /dev/null < "$input" 2>&1 | tr -d '\r'
}

# 1. The link: shown, polled, approved, redeemed by the daemon.
fake grants
: > "$W/empty"
out=$(on_tty "$W/empty" account sign-in --api "http://127.0.0.1:$PORT/api")
printf '%s' "$out" | grep -q 'open this link' && printf '%s' "$out" | grep -q 'user_code=BCDF-GHJK' \
  && printf '%s' "$out" | grep -q 'enter the code BCDF-GHJK' && ok "the link and user code are shown" \
  || bad "the link and user code are shown: $out"
grep -q '"capability": "server".*"platform": "linux"' "$W/fake.log" && ok "the grant names a Linux server" \
  || bad "the grant names a Linux server: $(cat "$W/fake.log")"
[ "$(grep -c '^/api/v1/device-grants/token ' "$W/fake.log")" = 2 ] && ok "polled until approved" \
  || bad "polled until approved: $(cat "$W/fake.log")"
grep -q '^/api/v1/devices/enroll .*"code": "e2e-approved-code-0123"' "$W/fake.log" && ok "the daemon redeems the approved code" \
  || bad "the daemon redeems the approved code: $(cat "$W/fake.log")"
printf '%s' "$out" | grep -q 'Approved. Signing in' && printf '%s' "$out" | grep -q '^Error: ' \
  && ! printf '%s' "$out" | grep -q '^Usage:' && ok "the enroll's refusal is an error, not usage" \
  || bad "the enroll's refusal is an error, not usage: $out"

# 2. No device grants there: the pasted code.
fake no-grants
printf 'bromure://enroll?v=1&code=pasted-code-0123456&api=http%%3A%%2F%%2F127.0.0.1%%3A%s%%2Fapi\n' "$PORT" > "$W/code"
out=$(on_tty "$W/code" account sign-in --api "http://127.0.0.1:$PORT/api")
printf '%s' "$out" | grep -q "can't approve a link yet" && printf '%s' "$out" | grep -q 'Authorize & Show code' \
  && ok "no device grants: asks for a code" || bad "no device grants: asks for a code: $out"
grep -q '^/api/v1/devices/enroll .*"code": "pasted-code-0123456"' "$W/fake.log" && ok "the pasted code is redeemed" \
  || bad "the pasted code is redeemed: $(cat "$W/fake.log")"

# 3. --code skips the link; a code on stdin (no terminal) too.
fake grants
printf 'bromure://enroll?v=1&code=pasted-code-0123456&api=http%%3A%%2F%%2F127.0.0.1%%3A%s%%2Fapi\n' "$PORT" > "$W/code"
out=$(on_tty "$W/code" account sign-in --code --api "http://127.0.0.1:$PORT/api")
! grep -q 'device-grants' "$W/fake.log" && grep -q '"code": "pasted-code-0123456"' "$W/fake.log" \
  && ok "--code takes a code, no link" || bad "--code takes a code, no link: $(cat "$W/fake.log") $out"
: > "$W/fake.log"
timeout 60 "$BIN" account sign-in --api "http://127.0.0.1:$PORT/api" < "$W/code" > /dev/null 2>&1
! grep -q 'device-grants' "$W/fake.log" && grep -q '"code": "pasted-code-0123456"' "$W/fake.log" \
  && ok "a code on stdin, no link" || bad "a code on stdin, no link: $(cat "$W/fake.log")"

[ "$fails" = 0 ] && echo "PASS signin" || echo "FAIL signin ($fails)"
[ "$fails" = 0 ]
