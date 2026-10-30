#!/bin/bash
# run-vm.sh <name> <cid> [incoming-state-file]
# Boots (or restores) one spike VM: q35+KVM, virtio-blk on a qcow2 overlay of the RO base,
# vhost-vsock, virtiofs (memfd shared RAM), virtio-net over a unix stream socket, QMP socket.
# Run as: sudo -g kvm ./run-vm.sh ...   (until the vhost udev rule lands)
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd); N=$1; CID=$2; IN=${3:-}
V=$D/vms/$N; mkdir -p $V $D/shared
BASE=$D/img/noble-amd64.img
[ -f $V/disk.qcow2 ] || qemu-img create -q -f qcow2 -F qcow2 -b $BASE $V/disk.qcow2 20G
rm -f $V/fs.sock $V/qmp.sock
/usr/libexec/virtiofsd --shared-dir $D/shared --socket-path $V/fs.sock --sandbox namespace \
  --migration-mode find-paths >$V/virtiofsd.log 2>&1 &
echo $! > $V/virtiofsd.pid
for i in $(seq 100); do [ -S $V/fs.sock ] && break; sleep 0.02; done
[ -S $V/net.sock ] || { echo "start frame_tap.py on $V/net.sock first" >&2; exit 1; }
ARGS=(-name $N -machine q35,accel=kvm -cpu host -smp 2 -m 2G
  -object memory-backend-memfd,id=mem,size=2G,share=on -numa node,memdev=mem
  -drive if=none,id=d0,file=$V/disk.qcow2,format=qcow2,cache=none,aio=io_uring -device virtio-blk-pci,drive=d0
  -drive if=virtio,file=$D/seed.iso,format=raw,readonly=on
  -device vhost-vsock-pci,guest-cid=$CID
  -chardev socket,id=fs0,path=$V/fs.sock -device vhost-user-fs-pci,chardev=fs0,tag=share
  -netdev stream,id=n0,server=off,addr.type=unix,addr.path=$V/net.sock -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:$(printf %02x $CID)
  -qmp unix:$V/qmp.sock,server=on,wait=off
  -display none -serial file:$V/serial.log -daemonize -pidfile $V/qemu.pid)
[ -n "$IN" ] && ARGS+=(-incoming defer)
qemu-system-x86_64 "${ARGS[@]}"
if [ -n "$IN" ]; then
  if [ "${MAPPED:-0}" = 1 ]; then   # mapped-ram: fixed-offset file format, file: URI
    python3 $D/qmp.py $V/qmp.sock '{"execute":"migrate-set-capabilities","arguments":{"capabilities":[{"capability":"mapped-ram","state":true}]}}' \
      "{\"execute\":\"migrate-incoming\",\"arguments\":{\"uri\":\"file:$IN\"}}" >/dev/null
  else
    python3 $D/qmp.py $V/qmp.sock "{\"execute\":\"migrate-incoming\",\"arguments\":{\"uri\":\"exec:cat $IN\"}}" >/dev/null
  fi
fi
