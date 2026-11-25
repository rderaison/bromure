#!/bin/sh
# Runs inside ci/linux/Dockerfile.smoke as an unprivileged user, the .deb
# installed. Checks the install, then launches the app in screenshot mode under
# Xvfb (no server: it renders the Connect screen) and checks the PNG.
# Results (connect.png, smoke.log) in ~/out.
set -eu
OUT="$HOME/out"; mkdir -p "$OUT"
fail() { echo "SMOKE FAILED: $*" >&2; exit 1; }
. /etc/os-release; echo "=== $PRETTY_NAME · $(uname -m) · $(dpkg-query -W -f '${Package} ${Version} ${Architecture}' bromure-client)"

[ -u /opt/bromure-client/chrome-sandbox ] || fail "chrome-sandbox isn't setuid"
[ "$(readlink -f /usr/bin/bromure-client)" = /opt/bromure-client/bromure-client ] || fail "/usr/bin/bromure-client"
# The network tunnel: its program runs here (the helper needs systemd and a
# TUN: not in this container), its units are installed.
v=$(/opt/bromure-client/resources/bromure-client-tunnel version) || fail "the tunnel program doesn't run"
echo "tunnel program: $v"
[ -f /usr/lib/systemd/system/bromure-client-tunnel.socket ] && [ -f '/usr/lib/systemd/system/bromure-client-tunnel@.service' ] || fail "tunnel units missing"
h=$(xdg-mime query default x-scheme-handler/bromure-client || true)
[ "$h" = io.bromure.client.desktop ] || fail "bromure-client:// handler is '$h'"
echo "scheme handler: $h"

# Under Docker's default seccomp profile Chromium's sandbox can't start (the
# zygote exits), so the render runs unsandboxed; the sandbox is checked on a
# real machine (see the README's Linux packaging section).
shot() { BROMURE_SHOT="$OUT/connect.png" BROMURE_SHOT_DELAY=4000 timeout 120 \
    xvfb-run -a -s '-screen 0 1600x1200x24' bromure-client "$@" >"$OUT/smoke.log" 2>&1; }
shot --no-sandbox || { cat "$OUT/smoke.log"; fail "the app exited with an error"; }
grep '^shot ' "$OUT/smoke.log" || { cat "$OUT/smoke.log"; fail "no screenshot written"; }

# PNG signature, and the 2x render of the 1320x944 window (IHDR width/height).
[ "$(od -An -tx1 -N8 "$OUT/connect.png" | tr -d ' ')" = 89504e470d0a1a0a ] || fail "connect.png isn't a PNG"
w=$(od -An -tu1 -j16 -N4 "$OUT/connect.png" | awk '{print ($1*16777216)+($2*65536)+($3*256)+$4}')
ht=$(od -An -tu1 -j20 -N4 "$OUT/connect.png" | awk '{print ($1*16777216)+($2*65536)+($3*256)+$4}')
size=$(wc -c < "$OUT/connect.png")
echo "connect.png ${w}x${ht}, $size bytes"
[ "$w" -ge 2000 ] && [ "$ht" -ge 1500 ] || fail "unexpected size ${w}x${ht}"
# A blank page compresses to a few KB; the Connect screen is far more.
[ "$size" -gt 30000 ] || fail "connect.png looks blank ($size bytes)"
echo "=== smoke OK"
