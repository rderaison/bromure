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

# Network health probe — backgrounded so on-boot.sh returns quickly.
# Waits up to 8s for DHCP, then validates gateway + external reachability.
# Emits one of BROMURE_NET_OK / BROMURE_NET_NO_IP / BROMURE_NET_NO_TRAFFIC on
# the serial console; the host watches for these markers and may offer a
# vmnet repair when traffic doesn't flow.
(
    IFACE=eth0
    IP=""
    i=0
    while [ $i -lt 16 ]; do
        IP=$(ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet / {print $2; exit}')
        [ -n "$IP" ] && break
        sleep 0.5
        i=$((i + 1))
    done
    if [ -z "$IP" ]; then
        echo "BROMURE_NET_NO_IP"
    else
        GW=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
        if [ -n "$GW" ] \
           && ping -c1 -W2 "$GW" >/dev/null 2>&1 \
           && ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
            echo "BROMURE_NET_OK"
        else
            echo "BROMURE_NET_NO_TRAFFIC"
        fi
    fi
) &
