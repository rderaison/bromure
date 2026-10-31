#!/bin/bash
# test-stop-post.sh BIN: `bromure-ac stop-post` under a real systemd user manager,
# with a stand-in main process that leaves a child (as the daemon leaves QEMU)
# and ignores SIGTERM (as a hung daemon would):
#   1. crash (SIGKILL the main; Restart=on-failure): the child is kept;
#   2. user stop past TimeoutStopSec: stop-post ends every leftover.
set -u
BIN=$1; U=bromure-ac-stoppost-$$
systemd-run --user -q --unit=$U -p KillMode=process -p TimeoutStopSec=2 -p Restart=on-failure -p RestartSec=1 \
  -p ExecStopPost="$BIN stop-post" bash -c 'sleep 1000 & trap "" TERM; while :; do sleep 1; done'
CG=/sys/fs/cgroup$(systemctl --user show $U -p ControlGroup --value)
sleep 0.5
child=$(pgrep -x sleep -P "$(systemctl --user show $U -p MainPID --value)" | head -1)
fail() { echo "FAIL: $*"; journalctl --user -u $U --no-pager -n 20; systemctl --user stop $U 2>/dev/null; kill -9 $(cat "$CG/cgroup.procs" 2>/dev/null) 2>/dev/null; exit 1; }
[ -n "$child" ] || fail "no stand-in child"
kill -9 "$(systemctl --user show $U -p MainPID --value)"
for _ in $(seq 50); do [ "$(systemctl --user show $U -p NRestarts --value)" = 1 ] && [ "$(systemctl --user is-active $U)" = active ] && break; sleep 0.1; done
[ "$(systemctl --user show $U -p NRestarts --value)" = 1 ] || fail "no restart after the crash"
kill -0 "$child" 2>/dev/null || fail "the crash restart killed the leftover child"
echo "crash: restarted, the leftover child $child kept"
t0=$(date +%s.%N)
systemctl --user stop $U
for _ in $(seq 50); do [ -s "$CG/cgroup.procs" ] 2>/dev/null || break; sleep 0.1; done
[ -s "$CG/cgroup.procs" ] 2>/dev/null && fail "left after stop: $(cat "$CG/cgroup.procs")"
kill -0 "$child" 2>/dev/null && fail "child $child survived the stop"
echo "stop (hung main, SIGKILLed at TimeoutStopSec): stop-post ended the leftovers in $(echo "$(date +%s.%N) - $t0" | bc | cut -c1-4)s"
journalctl --user -u $U --no-pager -o cat | grep 'stop-post:'
systemctl --user reset-failed $U 2>/dev/null
exit 0
