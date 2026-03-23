#!/bin/sh
# on-boot.sh — Runs at boot before any profile config is applied.
#
# Starts background services that benefit from early initialization
# (e.g. WARP in proxy mode) so they're ready by the time a session is claimed.

mkdir -p /tmp/bromure
chmod 777 /tmp/bromure
chmod 666 /dev/hvc0 2>/dev/null

# Sync system clock from PL031 RTC (hwclock service times out on virtual RTC tick)
[ -e /dev/rtc0 ] && hwclock -s -u 2>/dev/null || true

# Load modules needed for profile disk mounting (virtio-fs mounted later at claim time)
modprobe virtiofs 2>/dev/null
modprobe loop 2>/dev/null
mkdir -p /mnt/share

# Start dbus early (needed by warp-svc if VPN is enabled later).
/usr/bin/dbus-daemon --system 2>/dev/null
