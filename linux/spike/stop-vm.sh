#!/bin/bash
# stop-vm.sh <name>: quit QEMU via QMP and stop its virtiofsd
D=$(cd "$(dirname "$0")" && pwd); V=$D/vms/$1
python3 $D/qmp.py $V/qmp.sock '{"execute":"quit"}' >/dev/null 2>&1 || true
for i in $(seq 100); do [ -e /proc/$(cat $V/qemu.pid 2>/dev/null || echo 0) ] || break; sleep 0.05; done
kill $(cat $V/virtiofsd.pid) 2>/dev/null; true
