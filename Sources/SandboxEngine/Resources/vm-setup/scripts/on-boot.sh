#!/bin/sh
# on-boot.sh — Runs at boot before any profile config is applied.
#
# Starts background services that benefit from early initialization
# (e.g. WARP in proxy mode) so they're ready by the time a session is claimed.

mkdir -p /tmp/bromure
chmod 666 /dev/hvc0 2>/dev/null

# Sync system clock from PL031 RTC (hwclock service times out on virtual RTC tick)
[ -e /dev/rtc0 ] && hwclock -s -u 2>/dev/null || true

# Load modules needed for profile disk mounting (virtio-fs mounted later at claim time)
modprobe virtiofs 2>/dev/null
modprobe loop 2>/dev/null
mkdir -p /mnt/share

# Start Cloudflare WARP in proxy mode (socks5://127.0.0.1:40000).
# Runs in the background so boot is not blocked.
# If WARP is not needed for the session, apply-config.sh will disconnect it.
# The barrier marker at the end signals apply-config.sh that it's safe to
# tear down WARP (avoids a race where killall runs before warp-svc starts).
(
    PRELOAD="LD_PRELOAD=/usr/lib/libresolv_stub.so"
    /usr/bin/dbus-daemon --system 2>/dev/null
    env $PRELOAD /bin/warp-svc 1>/dev/null 2>/dev/null &
    sleep 3
    env $PRELOAD /bin/warp-cli --accept-tos registration new 2>&1
    env $PRELOAD /bin/warp-cli --accept-tos mode proxy 2>&1
    env $PRELOAD /bin/warp-cli --accept-tos connect 2>&1
    touch /tmp/bromure/on-boot-done
) &
