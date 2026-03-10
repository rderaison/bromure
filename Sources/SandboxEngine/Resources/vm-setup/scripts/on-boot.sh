#!/bin/sh
# on-boot.sh — Runs at boot before any profile config is applied.
#
# Starts background services that benefit from early initialization
# (e.g. WARP in proxy mode) so they're ready by the time a session is claimed.

mkdir -p /tmp/bromure

# Start Cloudflare WARP in proxy mode (socks5://127.0.0.1:40000).
# Runs in the background so boot is not blocked.
# If WARP is not needed for the session, apply-config.sh will disconnect it.
(
    PRELOAD="LD_PRELOAD=/usr/lib/libresolv_stub.so"
    /usr/bin/dbus-daemon --system 2>/dev/null
    env $PRELOAD /bin/warp-svc 1>/dev/null 2>/dev/null &
    sleep 3
    env $PRELOAD /bin/warp-cli --accept-tos registration new 2>&1
    env $PRELOAD /bin/warp-cli --accept-tos mode proxy 2>&1
    env $PRELOAD /bin/warp-cli --accept-tos connect 2>&1
) &
