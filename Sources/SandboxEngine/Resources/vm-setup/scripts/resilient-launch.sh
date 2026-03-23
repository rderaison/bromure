#!/bin/sh
# resilient-launch.sh — Auto-restart wrapper for VM daemons.
#
# Runs the given command in a loop, restarting on crash. Logs all
# stderr/stdout and crash events to /tmp/bromure/errors.txt so the
# host e2e test suite can detect failures.
#
# Usage: resilient-launch.sh <command> [args...]
#
# Example:
#   resilient-launch.sh /usr/local/bin/routing-socks.py
#   resilient-launch.sh proxychains4 -q -f /etc/proxychains/proxychains.conf squid -N -f /etc/squid/squid.conf

LOG="/tmp/bromure/resilient-launch.$(id -u).log"
CMD="$*"

mkdir -p /tmp/bromure
chmod 777 /tmp/bromure 2>/dev/null

while :; do
    "$@" >> "$LOG" 2>&1
    RC=$?
    TIMESTAMP=$(date '+%H:%M:%S')
    echo "[$TIMESTAMP] CRASHED rc=$RC: $CMD" >> "$LOG"
    # Brief pause to avoid tight crash loops
    sleep 1
done
