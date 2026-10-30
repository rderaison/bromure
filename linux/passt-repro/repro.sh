#!/bin/bash
# repro.sh <image-dir> <out-dir> [mtu] [runs] [mib]
# passt stall reproduction with nothing of Bromure's host side: qemu + passt (+ virtiofsd only to
# hand the guest its script), the guest uploading to a sink on the host's LAN address.
#   <image-dir>  vmlinuz, initrd.img, base.img (raw) of an Ubuntu guest whose fstab mounts the
#                virtiofs tag `bromure-meta` at /mnt/bromure-meta (linux/bake, `bromure-ac image bake`)
#   <out-dir>    passt.pcap, serial.log, passt.log, results.txt (keep it out of git: the pcap is GBs)
# The guest runs runner.sh via systemd.run= and powers off; results come back on its console.
# Env: MACHINE=q35|microvm (default q35), PCAP=0 to run without passt's capture,
#      PASST_MTU=<n>|none: passt's own --mtu (default: the guest's; `none` leaves passt at 65520),
#      RELAY=rechunk: put a relay between QEMU and passt that forwards the guest->passt byte stream
#      in pieces of random size (1..128 KiB) with a short pause between them, so passt's reads
#      end mid-frame. Nothing is held back.
#      Legal on a stream socket; it is what any process batching frames toward passt does.
#      RELAY=passthrough: the same relay, forwarding each read unchanged (the control).
#      RELAY=slowread: the relay stops reading passt's side now and then (5-50 ms), with small socket
#      buffers, so passt's writes to its tap fd hit EAGAIN -- as behind any consumer that applies
#      backpressure (Bromure's switch pauses reading when a VM's port is full).
#      RELAY_PCAP=1 (with a relay): the relay writes $OUT/wire.pcap, both directions, headers only
#      (snaplen 128), so the capture doesn't slow passt the way --pcap does (which hides the stall).
set -euo pipefail
IMG=$(realpath "$1"); OUT=$(realpath -m "$2"); MTU=${3:-1500}; RUNS=${4:-10}; MIB=${5:-512}
HERE=$(cd "$(dirname "$0")" && pwd)
# Under /tmp: Ubuntu's AppArmor profile for passt lets it create its socket only under /tmp/**
# (or libvirt's directories); $XDG_RUNTIME_DIR is refused ("Failed to bind UNIX domain socket").
mkdir -p "$OUT"; W=$(mktemp -d /tmp/passt-repro.XXXXXX); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
LAN=$(ip -4 -o route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p'); PORT=${PORT:-47011}

# The sink: reads each connection to EOF, answers one byte (so the guest knows it all landed).
python3 - "$LAN" "$PORT" > "$OUT/sink.log" 2>&1 <<'PY' &
import socket, subprocess, sys, threading
srv = socket.create_server((sys.argv[1], int(sys.argv[2])), backlog=16)
def serve(c):
    n, peer, quiet = 0, c.getpeername(), False
    c.settimeout(5)
    while True:
        try:
            b = c.recv(1 << 20)
        except socket.timeout:          # 5 s without data: passt's host-side socket, as the kernel sees it
            if not quiet:
                out = subprocess.run(["ss", "-tni", "dst", "%s:%d" % peer], capture_output=True, text=True).stdout
                print("QUIET after", n, "bytes from", peer, "\n" + out, flush=True)
            quiet = True
            continue
        if not b: break
        n += len(b)
    c.sendall(b"k"); c.close(); print("received", n, flush=True)
while True:
    c, _ = srv.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
PY

mkdir -p "$W/share"; cp "$HERE/runner.sh" "$W/share/"
printf 'HOST=%s\nPORT=%s\nMTU=%s\nRUNS=%s\nMIB=%s\n' "$LAN" "$PORT" "$MTU" "$RUNS" "$MIB" > "$W/share/params"
/usr/libexec/virtiofsd --shared-dir "$W/share" --readonly --socket-path "$W/fs.sock" --sandbox namespace \
    > "$OUT/virtiofsd.log" 2>&1 &
# passt as a plain QEMU backend: its own DHCP, a private /24 (as Bromure's switch hands out), no port
# forwards, no host-loopback mapping. The guest's traffic to $LAN leaves through the host's stack.
# Connected over a socketpair (passt --fd 0, QEMU addr.type=fd): this passt build's --socket mode
# fails every connection with "Failed to add fd to epoll: Bad file descriptor" (see the report).
PASST=(passt --foreground --fd 0 -4 -a 192.168.64.2 -n 24 -g 192.168.64.1
       --map-host-loopback none --map-guest-addr none -t none -u none)
[ "${PASST_MTU:-$MTU}" = none ] || PASST+=(--mtu "${PASST_MTU:-$MTU}")
[ "${PCAP:-1}" = 0 ] || PASST+=(--pcap "$OUT/passt.pcap")
case "${MACHINE:-q35}" in
  q35)     M=(-machine q35,accel=kvm); DEV=pci ;;
  microvm) M=(-machine microvm,accel=kvm,pit=off,pic=off,rtc=on,isa-serial=on); DEV=device ;;
esac
for _ in $(seq 100); do [ -S "$W/fs.sock" ] && break; sleep 0.05; done
qemu-img create -q -f qcow2 -F raw -b "$IMG/base.img" "$W/disk.qcow2"
QEMU=(qemu-system-x86_64 "${M[@]}" -cpu host -smp 2 -m 2048
    -object memory-backend-memfd,id=mem,size=2048M,share=on -numa node,memdev=mem
    -kernel "$IMG/vmlinuz" -initrd "$IMG/initrd.img"
    -append "$(cat "$IMG/cmdline") systemd.run=/mnt/bromure-meta/runner.sh systemd.run_success_action=poweroff systemd.run_failure_action=poweroff"
    -drive if=none,id=d0,file="$W/disk.qcow2",format=qcow2 -device virtio-blk-$DEV,drive=d0
    -chardev socket,id=fs0,path="$W/fs.sock" -device vhost-user-fs-$DEV,chardev=fs0,tag=bromure-meta
    -netdev stream,id=n0,addr.type=fd,addr.str=@FD@ -device virtio-net-$DEV,netdev=n0,mac=52:54:00:12:34:56
    -serial file:"$OUT/serial.log" -display none -nodefaults -no-user-config)
WIRE=""; [ "${RELAY_PCAP:-0}" = 1 ] && WIRE="$OUT/wire.pcap"
timeout $((RUNS * 120 + 180)) python3 - "$OUT/passt.log" "${RELAY:-none}" "$WIRE" "${#PASST[@]}" "${PASST[@]}" "${QEMU[@]}" <<'PY' || true
import os, random, socket, struct, subprocess, sys, threading, time
log, relay, wire, n = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]); passt, qemu = sys.argv[5:5 + n], sys.argv[5 + n:]
lock = threading.Lock()
pcap = None
if wire:
    pcap = open(wire, "wb", buffering=1 << 20)
    pcap.write(struct.pack("<IHHiIII", 0xa1b2c3d4, 2, 4, 0, 0, 128, 1))
class Framer:                           # QEMU's stream framing: 4-byte big-endian length, then the frame
    def __init__(self): self.buf = bytearray()
    def feed(self, data):
        if pcap is None: return
        self.buf += data
        now = time.time()
        while len(self.buf) >= 4:
            ln = int.from_bytes(self.buf[:4], "big")
            if len(self.buf) < 4 + ln: break
            fr = bytes(self.buf[4:4 + min(ln, 128)])
            with lock:
                pcap.write(struct.pack("<IIII", int(now), int(now % 1 * 1e6), len(fr), ln) + fr)
            del self.buf[:4 + ln]
a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)            # passt <-> (relay or QEMU)
if relay == "slowread":
    for sk in (a, b):
        sk.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 32 << 10)
        sk.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32 << 10)
p = subprocess.Popen(passt, stdin=a.fileno(), stdout=open(log, "w"), stderr=subprocess.STDOUT)
a.close()
if relay in ("rechunk", "passthrough", "slowread"):
    c, d = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)        # QEMU <-> relay
    q = subprocess.Popen([x.replace("@FD@", str(d.fileno())) for x in qemu], pass_fds=[d.fileno()])
    d.close()
    def to_passt():                     # guest frames: re-chunked at random offsets
        pend = bytearray(); fr = Framer()
        while True:
            x = c.recv(1 << 18)
            if not x: break
            fr.feed(x)
            if relay in ("passthrough", "slowread"):
                b.sendall(x); continue
            # Everything read is forwarded at once (holding bytes back would deadlock the guest's
            # window on the relay itself), but in random pieces with a pause between them, so
            # passt's reads end mid-frame.
            pend += x
            while pend:
                k = min(len(pend), random.randint(1, 128 << 10))
                b.sendall(pend[:k]); del pend[:k]
                if pend: time.sleep(0.0002)
    def to_qemu():                      # passt's frames: as they come (slowread: with pauses)
        n = 0; fr = Framer()
        while True:
            x = b.recv(1 << 18)
            if not x: break
            fr.feed(x)
            c.sendall(x)
            n += 1
            if relay == "slowread" and n % 200 == 0:
                time.sleep(random.uniform(0.005, 0.05))
    for f in (to_passt, to_qemu): threading.Thread(target=f, daemon=True).start()
else:
    q = subprocess.Popen([x.replace("@FD@", str(b.fileno())) for x in qemu], pass_fds=[b.fileno()])
    b.close()
q.wait(); p.terminate(); p.wait()
if pcap:
    with lock: pcap.flush()
PY
grep -a 'REPRO' "$OUT/serial.log" | tr -d '\r' | tee "$OUT/results.txt"
