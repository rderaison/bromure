#!/bin/bash
# bench-boot.sh <name> <cid> <runs>: cold boots an already-provisioned overlay, times QEMU exec -> guest vsock :5800 answering
D=$(cd "$(dirname "$0")" && pwd)
for r in $(seq $3); do
  T0=$(date +%s.%N); sudo -n -g kvm $D/run-vm.sh $1 $2
  W=$(python3 $D/vsock.py wait $2 5800 120); T1=$(date +%s.%N)
  echo "run $r: launch->vsock $(echo "$T1 - $T0" | bc) s (poll after launch returned: $W s)"
  $D/stop-vm.sh $1
done
