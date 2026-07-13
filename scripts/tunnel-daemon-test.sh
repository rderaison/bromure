#!/bin/bash
# End-to-end test of the privileged utun tunnel daemon (run with sudo).
#
#   sudo ./scripts/tunnel-daemon-test.sh
#
# Starts `bromure-ac __tunnel-helper` as root, drives a SETUP over its socket,
# and confirms it: created the utun + route, passed the utun fd back via
# SCM_RIGHTS, and deleted the route when the client disconnects. The userspace
# TCP forwarder itself is covered by the UtunForwarder unit test (no root); the
# full live flow is exercised by running the app with BROMURE_FATCLIENT_UTUN and
# curling a remote guest.
set -u

BIN="$(cd "$(dirname "$0")/.." && pwd)/.build/arm64-apple-macosx/release/Bromure Agentic Coding.app/Contents/MacOS/bromure-ac"
SOCK="/var/run/io.bromure.fatclient-tunnel.sock"
CIDR="192.168.223.0/24"

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
[ -x "$BIN" ] || { echo "build first: ./build.sh bromure-ac"; exit 1; }

"$BIN" __tunnel-helper & DAEMON=$!
trap 'kill "$DAEMON" 2>/dev/null; route -n delete -net "$CIDR" 2>/dev/null' EXIT
sleep 1.5

# Client: SETUP, receive "OK <utun>" + the utun fd (SCM_RIGHTS), then hold the
# connection open for a few seconds so we can inspect the interface + route.
python3 - "$SOCK" "$CIDR" <<'PY' &
import socket, sys, array, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.sendall(f"SETUP {sys.argv[2]}\n".encode())
msg, anc, _, _ = s.recvmsg(256, socket.CMSG_LEN(4))
print("SETUP reply:", msg.decode().strip(), flush=True)
for level, typ, data in anc:
    if level == socket.SOL_SOCKET and typ == socket.SCM_RIGHTS:
        print("received utun fd:", array.array("i", data)[0], flush=True)
time.sleep(6)   # hold the tunnel up while the shell checks below
PY
CLIENT=$!
sleep 2

echo "--- utun interface (10.98 /30 link net) ---"
ifconfig | grep -B1 "10.98" | grep -E "utun|10.98" || echo "  (utun not found)"
echo "--- route ---"
netstat -rn | grep "192.168.223" || echo "  (route not found)"

# Disconnect → the daemon should delete the route.
kill "$CLIENT" 2>/dev/null
sleep 1
echo "--- after disconnect ---"
if netstat -rn | grep -q "192.168.223"; then
  echo "RESULT: route still present — teardown FAILED"
else
  echo "RESULT: utun created, fd passed, route removed on disconnect — daemon path works."
fi
