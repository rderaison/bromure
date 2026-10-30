#!/bin/bash
# bake-amd64.sh [out-dir]
# QEMU/KVM port of UbuntuImageManager.createBaseImage for an amd64 guest:
#   Alpine 3.22 netboot (x86_64) + the /init.bromure DHCP/MTU shim  ->  installer VM
#   our setup.sh (staged by stage-amd64.sh) debootstraps noble onto a 24 GiB raw GPT disk
#   then the kernel + initrd are copied out for direct kernel boot (no BIOS/GRUB at runtime).
# Artefacts in <out-dir>: base.img (raw: vda1 ESP "EFI", vda2 ext4 "root"), vmlinuz, initrd.img,
#   cmdline, base.version (= imageVersion from UbuntuImageManager.swift, untouched), bake.log
# Needs: qemu-system-x86, virtiofsd, cpio, KVM + vhost access.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
OUT=$(realpath -m "${1:-$HOME/.local/share/bromure-ac/image-amd64}")
CACHE=${BAKE_CACHE:-$HOME/.cache/bromure-bake}
ALPINE_VER=3.22; ALPINE_REL=3.22.3
ALPINE_CDN=${ALPINE_CDN:-http://dl-cdn.alpinelinux.org}
UBUNTU_MIRROR=${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}
MTU=${BAKE_MTU:-1500}
DISK_GB=24; CPUS=4; MEM=4G
mkdir -p "$OUT" "$CACHE"; W=$OUT/.work; rm -rf "$W"; mkdir -p "$W/out"
# Unix sockets live in a short runtime dir (sun_path is limited to 108 bytes)
R=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/bromure-bake.XXXXXX")
log() { echo "[bake $(date +%T)] $*"; }

# 1. Alpine netboot, sha256-verified (UbuntuImageManager.swift:495-530, aarch64 -> x86_64)
TB=alpine-netboot-$ALPINE_REL-x86_64.tar.gz
URL=$ALPINE_CDN/alpine/v$ALPINE_VER/releases/x86_64/$TB
if [ ! -f "$CACHE/$TB" ]; then
  log "downloading $URL"
  curl -fsSL -o "$CACHE/$TB.part" "$URL"; curl -fsSL -o "$CACHE/$TB.sha256" "$URL.sha256"
  (cd "$CACHE" && sed "s/ .*$/  $TB.part/" "$TB.sha256" | sha256sum -c --quiet) && mv "$CACHE/$TB.part" "$CACHE/$TB"
fi
tar -xzf "$CACHE/$TB" -C "$W" boot/vmlinuz-virt boot/initramfs-virt
# x86 kernels are bzImages QEMU loads as-is: no extractRawKernel equivalent needed.

# 2. Shim: same script as SandboxEngine/InitrdShim.swift, appended as a second cpio
mkdir -p "$W/shim"
cat > "$W/shim/init.bromure" <<SHIM
#!/bin/sh
BB=/bin/busybox
log() { echo "\$1"; echo "\$1" > /dev/kmsg 2>/dev/null || true; }
\$BB mount -t sysfs -o noexec,nosuid,nodev sys /sys 2>/dev/null || true
\$BB mount -t proc -o noexec,nosuid,nodev proc /proc 2>/dev/null || true
\$BB mount -t devtmpfs -o exec,nosuid devtmpfs /dev 2>/dev/null || true
\$BB modprobe virtio_net 2>/dev/null || true
\$BB --install -s 2>/dev/null || true
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
log "bromure-shim: bringing lo + eth0 up"
\$BB ip link set dev lo up; \$BB ip link set dev eth0 up
log "bromure-shim: udhcpc"
\$BB udhcpc -i eth0 -q -n 2>&1 | while IFS= read -r l; do log "  \$l"; done
for f in /sys/class/net/e*/mtu; do [ -w "\$f" ] && echo $MTU > "\$f"; done
exec /init "\$@"
SHIM
chmod +x "$W/shim/init.bromure"
cp "$W/boot/initramfs-virt" "$W/initramfs-shimmed"
(cd "$W/shim" && echo init.bromure | cpio -o -H newc --quiet | gzip) >> "$W/initramfs-shimmed"

# 3. Stage vm-setup with the amd64 rewrites; empty raw target disk
"$HERE/stage-amd64.sh" "$REPO/Sources/AgentCoding/Resources/vm-setup" "$W/setup"
rm -f "$OUT/base.img.partial"; truncate -s ${DISK_GB}G "$OUT/base.img.partial"

# 4. Installer VM: virtiofs "setup" (ro) + "out", slirp NAT, serial on a unix socket
VFS=/usr/libexec/virtiofsd
$VFS --shared-dir "$W/setup" --readonly --socket-path "$R/setup.sock" --sandbox namespace >"$W/vfs-setup.log" 2>&1 &
$VFS --shared-dir "$W/out" --socket-path "$R/out.sock" --sandbox namespace >"$W/vfs-out.log" 2>&1 &
trap 'kill $(jobs -p) 2>/dev/null; [ -f "$W/qemu.pid" ] && kill $(cat "$W/qemu.pid") 2>/dev/null; true' EXIT
for s in setup out; do for i in $(seq 100); do [ -S "$R/$s.sock" ] && break; sleep 0.05; done; done
MODLOOP=$ALPINE_CDN/alpine/v$ALPINE_VER/releases/x86_64/netboot-$ALPINE_REL/modloop-virt
qemu-system-x86_64 -name bromure-bake -machine q35,accel=kvm -cpu host -smp $CPUS -m $MEM \
  -object memory-backend-memfd,id=mem,size=$MEM,share=on -numa node,memdev=mem \
  -kernel "$W/boot/vmlinuz-virt" -initrd "$W/initramfs-shimmed" \
  -append "console=ttyS0 rdinit=/init.bromure alpine_repo=$ALPINE_CDN/alpine/v$ALPINE_VER/main modloop=$MODLOOP modules=loop,squashfs,virtio-net,virtio-blk,virtiofs" \
  -drive if=none,id=d0,file="$OUT/base.img.partial",format=raw,cache=none,aio=io_uring,discard=unmap -device virtio-blk-pci,drive=d0 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -chardev socket,id=fs0,path="$R/setup.sock" -device vhost-user-fs-pci,chardev=fs0,tag=setup \
  -chardev socket,id=fs1,path="$R/out.sock" -device vhost-user-fs-pci,chardev=fs1,tag=out \
  -device virtio-rng-pci \
  -chardev socket,id=ser,path="$R/serial.sock",server=on,wait=off -serial chardev:ser \
  -display none -daemonize -pidfile "$W/qemu.pid"

# 5. The same console dialogue as runProvisioner (UbuntuImageManager.swift:990-1105)
P='localhost:~#'
cat > "$W/script.json" <<JSON
[["wait","localhost login:",180,["Kernel panic"]], ["send","root"], ["wait","$P",30],
 ["send","NIC=\$(ip -o link show | awk -F': ' '/^[0-9]+: (eth|enp|ens)/ {print \$2; exit}')"], ["wait","$P",10],
 ["send","[ -n \"\$NIC\" ] && ip link set dev \"\$NIC\" mtu $MTU 2>/dev/null || true"], ["wait","$P",10],
 ["send","if [ -n \"\$NIC\" ] && ! ip -4 -o addr show dev \"\$NIC\" | grep -q 'inet '; then udhcpc -i \"\$NIC\" -q -n 2>/dev/null || true; fi"], ["wait","$P",60],
 ["send","if ip -4 -o addr show dev \"\$NIC\" 2>/dev/null | grep -q 'inet '; then echo SANDBOX_NETWORK_\"OK\"; else echo SANDBOX_NO_\"NETWORK\"; fi"],
 ["wait","SANDBOX_NETWORK_OK",30,["SANDBOX_NO_NETWORK"]],
 ["send","modprobe virtiofs && mkdir -p /tmp/setup /tmp/out && mount -t virtiofs setup /tmp/setup && mount -t virtiofs out /tmp/out && echo MOUNTS_\"OK\""],
 ["wait","MOUNTS_OK",60],
 ["send","UBUNTU_MIRROR='$UBUNTU_MIRROR' ALPINE_REPO_BASE='$ALPINE_CDN' sh /tmp/setup/setup.sh 1"],
 ["wait","SANDBOX_SETUP_DONE",2700,["SANDBOX_SETUP_FAILED:","Kernel panic","Internal error: Oops"]],
 ["send","mkdir -p /mnt && mount -o ro /dev/vda2 /mnt && cp -L /mnt/boot/vmlinuz /tmp/out/vmlinuz && cp -L /mnt/boot/initrd.img /tmp/out/initrd.img && ls /mnt/lib/modules > /tmp/out/kernel-release && umount /mnt && sync && echo EXTRACT_\"OK\""],
 ["wait","EXTRACT_OK",120,["No such file"]],
 ["send","poweroff"]]
JSON
log "installer VM up; running setup.sh (serial log: $W/serial.log)"
T0=$(date +%s)
python3 "$HERE/serial-driver.py" "$R/serial.sock" "$W/serial.log" "$W/script.json"
for i in $(seq 300); do kill -0 $(cat "$W/qemu.pid") 2>/dev/null || break; sleep 0.1; done
kill $(cat "$W/qemu.pid") 2>/dev/null || true
log "setup.sh finished in $(( $(date +%s) - T0 ))s"

# 6. Artefacts
mv "$OUT/base.img.partial" "$OUT/base.img"
mv "$W/out/vmlinuz" "$W/out/initrd.img" "$W/out/kernel-release" "$OUT/"
echo "console=ttyS0 root=LABEL=root rootfstype=ext4 ro quiet" > "$OUT/cmdline"
grep -oE 'imageVersion = "[^"]+"' "$REPO/Sources/AgentCoding/UbuntuImageManager.swift" | cut -d'"' -f2 > "$OUT/base.version"
cp "$W/serial.log" "$OUT/bake.log"; rm -rf "$W" "$R"
log "done: $(ls "$OUT" | tr '\n' ' ')"
