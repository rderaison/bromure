#!/bin/bash
# boot-direct.sh <image-dir> [q35|microvm] [runs]
# Boots a qcow2 overlay of <image-dir>/base.img by direct kernel boot (vmlinuz/initrd.img/cmdline
# from bake-amd64.sh), with the bromure-meta virtiofs share holding bromure-agentd.py, and times
# QEMU exec -> bromure-agentd's first vsock connection to host port 5800. The NIC is QEMU user-mode
# NAT: without a NIC, agentd's docker restart waits out network-online (120 s) before the shell starts.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
IMG=$(realpath "$1"); MACH=${2:-q35}; RUNS=${3:-3}; CID=${CID:-77}
# Short dir: it holds unix sockets (sun_path is limited to 108 bytes)
W=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/bromure-boot.XXXXXX"); mkdir -p "$W/meta" "$W/outbox"
trap 'kill $(jobs -p) 2>/dev/null; [ -f "$W/qemu.pid" ] && kill $(cat "$W/qemu.pid") 2>/dev/null; true' EXIT
cp "$REPO/Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py" "$W/meta/"
mkdir -p "$W/meta/virtiofs-tags"; touch "$W/meta/virtiofs-tags/bromure-meta" "$W/meta/virtiofs-tags/bromure-outbox"
if [ $MACH = microvm ]; then
  M="microvm,accel=kvm,pit=off,pic=off,rtc=on,isa-serial=on"; BLK=virtio-blk-device; FS=vhost-user-fs-device; VS=vhost-vsock-device; NIC=virtio-net-device
else
  M="q35,accel=kvm"; BLK=virtio-blk-pci; FS=vhost-user-fs-pci; VS=vhost-vsock-pci; NIC=virtio-net-pci
fi
for r in $(seq $RUNS); do
  rm -f "$W/disk.qcow2" "$W/meta.sock" "$W/outbox.sock"
  qemu-img create -q -f qcow2 -F raw -b "$IMG/base.img" "$W/disk.qcow2"
  /usr/libexec/virtiofsd --shared-dir "$W/meta" --socket-path "$W/meta.sock" --sandbox namespace >"$W/vfs.log" 2>&1 &
  VPID=$!
  /usr/libexec/virtiofsd --shared-dir "$W/outbox" --socket-path "$W/outbox.sock" --sandbox namespace >"$W/vfs-outbox.log" 2>&1 &
  OPID=$!; for i in $(seq 100); do [ -S "$W/meta.sock" ] && [ -S "$W/outbox.sock" ] && break; sleep 0.02; done
  python3 "$HERE/vsock-host.py" 5800 180 > "$W/agentd.txt" &
  LPID=$!; until grep -q ready "$W/agentd.txt" 2>/dev/null; do sleep 0.01; done
  T0=$(date +%s.%N)
  qemu-system-x86_64 -name bromure-direct -machine $M -cpu host -smp 2 -m 2G \
    -object memory-backend-memfd,id=mem,size=2G,share=on -numa node,memdev=mem \
    -kernel "$IMG/vmlinuz" -initrd "$IMG/initrd.img" -append "$(cat "$IMG/cmdline")" \
    -drive if=none,id=d0,file="$W/disk.qcow2",format=qcow2,cache=none,aio=io_uring -device $BLK,drive=d0 \
    -chardev socket,id=fs0,path="$W/meta.sock" -device $FS,chardev=fs0,tag=bromure-meta \
    -chardev socket,id=fs1,path="$W/outbox.sock" -device $FS,chardev=fs1,tag=bromure-outbox \
    -netdev user,id=n0 -device $NIC,netdev=n0 \
    -device $VS,guest-cid=$CID -nodefaults -no-user-config \
    -serial file:"$W/serial-$r.log" -display none -daemonize -pidfile "$W/qemu.pid"
  wait $LPID || true; T1=$(date +%s.%N)
  RSS=$(sudo -n awk '/^Rss:/{print int($2/1024)}' /proc/$(cat "$W/qemu.pid")/smaps_rollup 2>/dev/null || echo "?")
  echo "$MACH run $r: exec -> agentd vsock 5800 = $(echo "$T1 - $T0" | bc) s ($(tail -1 "$W/agentd.txt")); qemu RSS ${RSS} MiB"
  kill $(cat "$W/qemu.pid"); kill $VPID $OPID 2>/dev/null; sleep 0.3
  for f in "$W"/outbox/*; do [ -f "$f" ] && cp "$f" "${LOGDIR:-$W}/$MACH-$r-$(basename "$f")"; done
done
cp "$W"/serial-*.log "${LOGDIR:-$W}/" 2>/dev/null || true
