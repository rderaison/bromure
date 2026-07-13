#!/bin/bash
# End-to-end test of the privileged utun tunnel daemon (run with sudo).
#
#   sudo ./scripts/tunnel-daemon-test.sh
#
# Starts `bromure-ac __tunnel-helper` as root, drives a SETUP over its socket,
# and confirms it created the utun + route + pf rdr rule, then tears it down.
# This validates the daemon's root path (the spike validated utun+route; this
# adds the pf rdr + the socket IPC). DIOCNATLOOK is exercised only by a real
# redirected connection, so it isn't covered here.
set -u

BIN="$(cd "$(dirname "$0")/.." && pwd)/.build/arm64-apple-macosx/release/Bromure Agentic Coding.app/Contents/MacOS/bromure-ac"
SOCK="/var/run/io.bromure.fatclient-tunnel.sock"
CIDR="192.168.223.0/24"

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
[ -x "$BIN" ] || { echo "build first: ./build.sh bromure-ac"; exit 1; }

"$BIN" __tunnel-helper & DAEMON=$!
trap 'kill "$DAEMON" 2>/dev/null; pfctl -a io.bromure.fatclient -F nat 2>/dev/null; route -n delete -net "$CIDR" 2>/dev/null' EXIT
sleep 1.5

REPLY=$(python3 - "$SOCK" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(3)
s.connect(sys.argv[1]); s.sendall(b"SETUP 192.168.223.0/24 51999\n")
print(s.recv(256).decode().strip())
PY
)
echo "SETUP reply: $REPLY"
UTUN="${REPLY#OK }"

echo "--- utun interface ---";  ifconfig "$UTUN" 2>/dev/null | grep -E "$UTUN|10.98" || echo "  (utun not found)"
echo "--- route ---";           netstat -rn | grep "192.168.223" || echo "  (route not found)"
echo "--- pf rdr rule ---";     pfctl -a io.bromure.fatclient -s nat 2>/dev/null || echo "  (no pf rule)"

python3 - "$SOCK" "$UTUN" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(3)
s.connect(sys.argv[1]); s.sendall(f"TEARDOWN 192.168.223.0/24 {sys.argv[2]}\n".encode())
print("TEARDOWN reply:", s.recv(256).decode().strip())
PY

if [[ "$REPLY" == OK\ utun* ]]; then
  echo; echo "RESULT: the daemon set up the utun + route + pf. utun forwarder root path works."
else
  echo; echo "RESULT: SETUP failed — check the daemon log."
fi
