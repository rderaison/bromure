#!/bin/bash
# suspend-resume.sh <name> <cid> [mapped]: boot, suspend to file, restore, verify vsock both ways + virtiofs; prints timings + RSS
set -u; D=$(cd "$(dirname "$0")" && pwd); N=$1; CID=$2; MODE=${3:-exec}; V=$D/vms/$N
mig() { while :; do st=$(python3 $D/qmp.py $V/qmp.sock '{"execute":"query-migrate"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["return"].get("status"))'); case $st in completed|failed) echo $st; return;; esac; sleep 0.01; done; }
rss() { sudo -n awk '/^Rss:/{print int($2/1024)" MiB"}' /proc/$(cat $V/qemu.pid)/smaps_rollup; }
sudo -n -g kvm $D/run-vm.sh $N $CID; python3 $D/vsock.py wait $CID 5800 120 >/dev/null; sleep 15
echo "booted RSS $(rss)"; python3 $D/vsock.py call $CID 5800 "echo $MODE > /mnt/shared/pre-$MODE.txt"
if [ $MODE = mapped ]; then
  ST=$V/state.mapped; rm -f $ST
  python3 $D/qmp.py $V/qmp.sock '{"execute":"migrate-set-capabilities","arguments":{"capabilities":[{"capability":"mapped-ram","state":true}]}}' >/dev/null
  URI="file:$ST"
else ST=$V/state.exec; URI="exec:cat > $ST"; fi
python3 $D/qmp.py $V/qmp.sock '{"execute":"migrate-set-parameters","arguments":{"max-bandwidth":107374182400}}' >/dev/null  # default cap is 128 MiB/s
T0=$(date +%s.%N); python3 $D/qmp.py $V/qmp.sock '{"execute":"stop"}' "{\"execute\":\"migrate\",\"arguments\":{\"uri\":\"$URI\"}}" >/dev/null
st=$(mig); T1=$(date +%s.%N); echo "save[$MODE] $st $(echo "$T1-$T0"|bc)s file=$(du -h $ST|cut -f1) apparent=$(du -h --apparent-size $ST|cut -f1)"
$D/stop-vm.sh $N
T0=$(date +%s.%N); MAPPED=$([ $MODE = mapped ] && echo 1 || echo 0) sudo -n -g kvm --preserve-env=MAPPED $D/run-vm.sh $N $CID $ST
st=$(mig); T1=$(date +%s.%N); python3 $D/qmp.py $V/qmp.sock '{"execute":"cont"}' >/dev/null
python3 $D/vsock.py wait $CID 5800 60 >/dev/null; T2=$(date +%s.%N)
echo "restore[$MODE] $st load=$(echo "$T1-$T0"|bc)s launch->vsock=$(echo "$T2-$T0"|bc)s RSS $(rss)"
python3 $D/vsock.py call $CID 5800 "cat /mnt/shared/pre-$MODE.txt && echo ok > /mnt/shared/post-$MODE.txt && python3 -c 'import socket;s=socket.socket(socket.AF_VSOCK);s.connect((2,5801));s.sendall(b\"guest-hello restored-$MODE\")' && echo guest-dialed-host"
cat $D/shared/post-$MODE.txt; $D/stop-vm.sh $N
