#!/bin/sh
# Bromure Agentic Coding — build the self-contained provisioner initramfs.
#
# Runs inside the Alpine netboot installer (publish pipeline only:
# `bromure-ac init-foss-image`), right after the image bake. It turns the
# netboot environment into ONE initramfs that boots straight to the same
# root serial login — with the kernel modules (normally the network-fetched
# modloop) and e2fsprogs (normally an `apk add` at postinstall time)
# already inside. The pipeline publishes it next to base.img.gz, so an
# end-user install downloads the image + this provisioner from
# dl.bromure.io and never touches dl-cdn.alpinelinux.org: the netboot
# tarball, modloop-virt, APKINDEX and alpine-base fetches all disappear.
#
# The provisioner is only an execution environment for postinstall.sh
# (mount vda, chroot into Ubuntu, run the catalog steps). It keeps the
# netboot's observable contract so the host driver doesn't care which one
# it booted: getty on hvc0 → `localhost login:` → root, passwordless →
# `localhost:~#`, `modprobe virtiofs`, `poweroff`.
#
# Shares the host attaches:
#   setup — this directory (read-only)
#   out   — writable; receives provisioner-initrd (gzip'd newc cpio) and
#           provisioner-kernel-release (the `uname -r` it was built for —
#           the modules only load under that exact kernel, which the host
#           publishes alongside as provisioner-vmlinuz).
#
# The host watches stdout for SANDBOX_PROVISIONER_DONE / SANDBOX_PROVISIONER_FAILED.

set -e

log() { printf '[ac-provisioner] %s\n' "$*"; }
fail() { printf 'SANDBOX_PROVISIONER_FAILED: %s\n' "$*"; exit 1; }

retry() {
    for i in 1 2 3; do
        "$@" && return 0
        log "retry $i/3 failed: $*"
        sleep 2
    done
    fail "command failed after 3 attempts: $*"
}

STAGE=/tmp/provisioner-root
OUT=/tmp/out
KREL=$(uname -r)
. /etc/os-release 2>/dev/null || true
ALPINE_VER_SHORT=$(echo "${VERSION_ID:-3.22}" | cut -d. -f1,2)

log "mounting output share"
mkdir -p "$OUT"
mountpoint -q "$OUT" || mount -t virtiofs out "$OUT" || fail "cannot mount output share"

# Same package channel as setup.sh: the host proxy when it's up.
: "${ALPINE_REPO_BASE:=http://dl-cdn.alpinelinux.org}"
# GNU cpio lives in community; same host as the main repo line (the proxy).
grep -q '/community' /etc/apk/repositories \
    || echo "${ALPINE_REPO_BASE}/alpine/v${ALPINE_VER_SHORT}/community" >> /etc/apk/repositories
# The netboot's own package set, captured before the build tools below
# join it — that's what the provisioner root gets.
WORLD=$(cat /etc/apk/world)
retry apk update
# GNU cpio: busybox's applet can't be relied on to write archives.
retry apk add cpio

# ---------------------------------------------------------------------------
# Root filesystem: the netboot's own package set + e2fsprogs.
# ---------------------------------------------------------------------------

log "installing provisioner root ($(echo $WORLD) + e2fsprogs)"
rm -rf "$STAGE"
mkdir -p "$STAGE/etc/apk"
cp -a /etc/apk/keys "$STAGE/etc/apk/"
cp /etc/apk/repositories "$STAGE/etc/apk/repositories"
# shellcheck disable=SC2086  # $WORLD is a word list
retry apk add --root "$STAGE" --initdb --no-cache \
    --keys-dir /etc/apk/keys \
    --repositories-file /etc/apk/repositories \
    $WORLD e2fsprogs

# The build-time repositories file points at the bake's host proxy, which
# won't exist on the end-user's machine — ship the canonical CDN instead.
echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER_SHORT}/main" \
    > "$STAGE/etc/apk/repositories"

# ---------------------------------------------------------------------------
# Kernel modules: everything the modloop carries, for THIS kernel.
# ---------------------------------------------------------------------------

KMOD_SRC=$(readlink -f "/lib/modules/$KREL" 2>/dev/null || true)
[ -n "$KMOD_SRC" ] && [ -f "$KMOD_SRC/modules.dep" ] \
    || fail "no modules for $KREL (modloop not mounted?)"
log "copying kernel modules for $KREL from $KMOD_SRC"
mkdir -p "$STAGE/lib/modules"
rm -rf "$STAGE/lib/modules/$KREL"
cp -a "$KMOD_SRC" "$STAGE/lib/modules/$KREL"

# ---------------------------------------------------------------------------
# Boot contract: what Alpine's netboot /init sets up, done by hand.
# ---------------------------------------------------------------------------

# Passwordless root on the serial console (the host logs in as `root`).
sed -i 's/^root:[^:]*:/root::/' "$STAGE/etc/shadow"
grep -qx hvc0 "$STAGE/etc/securetty" 2>/dev/null || echo hvc0 >> "$STAGE/etc/securetty"
echo localhost > "$STAGE/etc/hostname"

# busybox init: a getty on the virtio console and a clean shutdown path.
# No OpenRC — nothing here needs services, and `poweroff` halts in ~1 s.
cat > "$STAGE/etc/inittab" <<'EOF'
::sysinit:/bin/true
hvc0::respawn:/sbin/getty -L 0 hvc0 vt100
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/sync
::shutdown:/bin/umount -a -r
EOF

# PID 1. The host boots with rdinit=/init.bromure (InitrdShim: DHCP + MTU
# clamp), which exec's this. Kernel and modules match, so everything the
# netboot fetched is local.
cat > "$STAGE/init" <<'EOF'
#!/bin/sh
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
mount -t proc -o noexec,nosuid,nodev proc /proc 2>/dev/null
mount -t sysfs -o noexec,nosuid,nodev sys /sys 2>/dev/null
mount -t devtmpfs -o exec,nosuid devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts /dev/shm /run /tmp /mnt
mount -t devpts devpts /dev/pts 2>/dev/null
hostname localhost
for m in virtio_pci virtio_blk virtio_net virtio_console virtiofs \
         af_packet ext4 vfat nls_cp437 nls_iso8859_1 nls_utf8; do
    modprobe "$m" 2>/dev/null
done
ip link set lo up 2>/dev/null
echo "bromure-provisioner: $(uname -r) up"
exec /sbin/init
EOF
chmod 755 "$STAGE/init"

# Sanity: the pieces postinstall.sh and the host driver depend on.
for f in /sbin/init /sbin/getty /bin/login /sbin/e2fsck /sbin/modprobe \
         /usr/share/udhcpc/default.script "/lib/modules/$KREL/modules.dep"; do
    [ -e "$STAGE$f" ] || fail "provisioner root is missing $f"
done

# ---------------------------------------------------------------------------
# Pack.
# ---------------------------------------------------------------------------

log "packing initramfs"
rm -f "$OUT/provisioner-initrd" "$OUT/provisioner-kernel-release"
( cd "$STAGE" && find . -mindepth 1 | cpio -o -H newc --quiet ) \
    | gzip -9 > "$OUT/provisioner-initrd.tmp" || fail "cpio/gzip failed"
mv "$OUT/provisioner-initrd.tmp" "$OUT/provisioner-initrd"
printf '%s\n' "$KREL" > "$OUT/provisioner-kernel-release"
sync
log "provisioner-initrd: $(du -k "$OUT/provisioner-initrd" | cut -f1) KiB for kernel $KREL"

echo SANDBOX_PROVISIONER_DONE
