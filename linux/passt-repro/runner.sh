#!/bin/bash
# Guest side of repro.sh (systemd.run=): sets the MTU, waits for the lease, uploads RUNS x MIB MiB
# to HOST:PORT, one connection each, and prints one REPRO line per run on the console.
. /mnt/bromure-meta/params
say() { echo "REPRO $*" > /dev/console; }
NIC=$(ip -o link show | awk -F': ' '/^[0-9]+: (eth|enp|ens)/ {print $2; exit}')
ip link set dev "$NIC" mtu "$MTU"
# systemd.run= boots into this unit instead of the default target: bring networking up ourselves
# (the image's networkd config leases on en*; passt answers DHCP).
systemctl start systemd-networkd
for _ in $(seq 60); do ip -4 -o addr show dev "$NIC" | grep -q 'inet ' && break; sleep 0.5; done
say "guest $(uname -r) nic $NIC mtu $(cat /sys/class/net/$NIC/mtu) addr $(ip -4 -o addr show dev "$NIC" | awk '{print $4}')"
python3 - "$HOST" "$PORT" "$RUNS" "$MIB" <<'PY'
import socket, sys, time
host, port, runs, mib = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
def say(m):
    with open("/dev/console", "w") as c: c.write("REPRO " + m + "\n")
buf = b"\0" * (1 << 20)
stalls = 0
for i in range(runs):
    s = socket.create_connection((host, port), timeout=10)
    sent, t0 = 0, time.time()
    try:
        while sent < mib << 20:
            sent += s.send(buf)          # a 10 s stall in send() is a stall
        s.shutdown(socket.SHUT_WR)
        s.recv(1)                        # the sink's answer: everything arrived
        say("run %d: %d MiB in %.2fs (%.0f MB/s)" % (i, mib, time.time() - t0, (mib << 20) / (time.time() - t0) / 1e6))
    except socket.timeout:
        stalls += 1
        sport = s.getsockname()[1]
        say("run %d: STALL after %d bytes (%.1fs); local port %d" % (i, sent, time.time() - t0, sport))
        import subprocess   # the guest's view of the stuck flow: unacked, retransmits, rto
        ss = subprocess.run(["ss", "-tin", "sport", "= :%d" % sport], capture_output=True, text=True).stdout
        for line in ss.strip().splitlines()[1:]:
            say("  guest ss: " + " ".join(line.split()))
    s.close()
say("done: %d/%d runs stalled" % (stalls, runs))
PY
