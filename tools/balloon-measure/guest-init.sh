#!/bin/busybox sh
/bin/busybox --install -s /bin 2>/dev/null
mount -t proc p /proc; mount -t sysfs s /sys; mount -t devtmpfs d /dev
K=$(uname -r)
for m in virtio virtio_ring virtio_pci virtio_mmio virtio_console squashfs loop; do modprobe $m 2>/dev/null; done
exec >/dev/hvc0 2>&1 </dev/hvc0
echo "KVER $K $(cat /proc/cmdline)"
modprobe virtio_balloon 2>&1
ls /sys/bus/virtio/drivers/ | tr '\n' ' '; echo
ls /sys/bus/virtio/drivers/virtio_balloon/ 2>/dev/null | tr '\n' ' '; echo
cat /sys/kernel/mm/page_reporting/order 2>/dev/null
for d in /sys/bus/virtio/drivers/virtio_balloon/virtio*; do [ -e "$d/features" ] && echo "balloon-features $(cat $d/features)"; done
mkdir -p /t; mount -t tmpfs -o size=100% t /t
mem(){ awk '/MemTotal|MemAvailable|MemFree/{printf "%s %d MB  ",$1,$2/1024}END{print ""}' /proc/meminfo; }
echo READY; mem
while read -r c a; do
  case "$c" in
    touch) dd if=/dev/zero of=/t/x bs=1M count=$a 2>/dev/null; echo "touched $a"; mem;;
    free) rm -f /t/x; echo freed; mem;;
    mem) mem;;
    halt) poweroff -f;;
  esac
  echo DONE
done
