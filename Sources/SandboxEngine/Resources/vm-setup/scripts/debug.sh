#!/bin/sh
sleep 15
echo === PCI DEVICES ===
cat /proc/bus/pci/devices 2>/dev/null || echo no-pci
ls -la /sys/bus/pci/devices/ 2>/dev/null
for d in /sys/bus/pci/devices/*; do
  echo "$d: $(cat $d/vendor 2>/dev/null) $(cat $d/device 2>/dev/null) $(cat $d/class 2>/dev/null)"
done
echo === USB MODULES AVAIL ===
find /lib/modules/*/kernel/drivers/usb -name "*.ko*" 2>/dev/null || echo none
find /lib/modules/*/kernel/drivers/hid -name "*.ko*" 2>/dev/null || echo none
echo === USB/INPUT ===
lsmod 2>/dev/null
ls -la /dev/input/ 2>/dev/null || echo no-input-devs
cat /proc/bus/input/devices 2>/dev/null || echo no-input-proc
dmesg | grep -iE "usb|hid|input|keyboard|xhci|pci" 2>/dev/null
echo === END DEBUG ===
