#!/bin/sh
# Bromure Agentic Coding — base image postinstall script.
#
# Runs inside the same Alpine netboot installer environment as setup.sh,
# but against an ALREADY-INSTALLED Ubuntu disk (freshly downloaded from
# dl.bromure.io, or a local build being amended). It chroots into the
# image and executes the postinstall commands declared in img-catalog.json
# — this is where non-free software (Claude Code, Codex, Grok CLI, gcloud)
# lands on the end-user's machine, since the published image itself must
# stay free-software-only.
#
# The host watches stdout for SANDBOX_POSTINSTALL_DONE (success) or
# SANDBOX_POSTINSTALL_FAILED (any failure).
#
# Shares the host attaches:
#   setup        — this directory (read-only), same as setup.sh
#   postinstall  — a host temp dir containing steps/NNN-<slug>.sh, one file
#                  per accepted catalog step, executed in lexical order.
#                  Line 1 of each file is `# <human description>`.
#   macos-fonts / macos-user-fonts / macos-terminal-fonts — optional; when
#                  present the host's fonts are copied in, mirroring the
#                  setup.sh bake path (fonts never ship in the published
#                  image — Apple's fonts are not redistributable).
#
# Pipeline:
#   1. Mount vda2 (root) + vda1 (ESP) and bind /dev /proc /sys.
#   2. Mount the postinstall share, copy the step files into the chroot.
#   3. chroot: proxy env up, run each step with retries, markers per step.
#   4. Copy macOS fonts (when shared) + fc-cache.
#   5. Restore resolv.conf, umount, sync, print marker.

set -e

TARGET_DEV=/dev/vda
TARGET_EFI=${TARGET_DEV}1
TARGET_ROOT=${TARGET_DEV}2

log() { printf '[ac-postinstall] %s\n' "$*"; }
fail() { printf 'SANDBOX_POSTINSTALL_FAILED: %s\n' "$*"; exit 1; }

# e2fsprogs for the final integrity check below — the netboot initramfs
# doesn't ship e2fsck. Best-effort: a transient apk failure skips the
# check (setup.sh's own e2fsck already gated the artifact we started
# from) rather than failing the whole postinstall.
( apk update && apk add e2fsprogs ) >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Mount the installed system.
# ---------------------------------------------------------------------------

log "mounting installed system from $TARGET_ROOT"
# The netboot initramfs autoloads most fs modules on demand, but be
# explicit — unlike setup.sh we never ran mkfs here to warm them up.
modprobe ext4 2>/dev/null || true
modprobe vfat 2>/dev/null || true
mkdir -p /mnt
mount -t ext4 "$TARGET_ROOT" /mnt || fail "cannot mount root partition"
mount -t vfat "$TARGET_EFI" /mnt/boot/efi || fail "cannot mount EFI partition"

[ -d /dev/pts ] || mkdir /dev/pts
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts

mount --bind /dev      /mnt/dev
mount --bind /dev/pts  /mnt/dev/pts
mount -t proc  proc    /mnt/proc
mount -t sysfs sys     /mnt/sys

# ---------------------------------------------------------------------------
# Bring in the step files from the host.
# ---------------------------------------------------------------------------

log "mounting postinstall share"
mkdir -p /tmp/postinstall
mount -t virtiofs postinstall /tmp/postinstall || fail "cannot mount postinstall share"

STEP_COUNT=$(ls /tmp/postinstall/steps/*.sh 2>/dev/null | wc -l | tr -d ' ')
log "found $STEP_COUNT postinstall step(s)"

rm -rf /mnt/tmp/bromure-postinstall
mkdir -p /mnt/tmp/bromure-postinstall
if [ "$STEP_COUNT" -gt 0 ]; then
    cp /tmp/postinstall/steps/*.sh /mnt/tmp/bromure-postinstall/
fi

# Same build-time var stash as setup.sh: the chroot reads the proxy base
# back without heredoc interpolation. ALPINE_REPO_BASE is the host's
# HTTP→HTTPS proxy when it's running — but when the proxy failed to
# start it's the plain Alpine CDN URL, which must NOT become the
# chroot's http_proxy (nothing proxies through a package mirror).
BROMURE_PROXY=""
if [ -n "${ALPINE_REPO_BASE:-}" ] && [ "$ALPINE_REPO_BASE" != "http://dl-cdn.alpinelinux.org" ]; then
    BROMURE_PROXY="$ALPINE_REPO_BASE"
fi
{
    echo "BROMURE_PROXY=$BROMURE_PROXY"
} > /mnt/tmp/bromure-build.env

# The installed image's /etc/resolv.conf is a symlink to systemd-resolved's
# stub — dangling inside a chroot (no /run tmpfs). Swap in the installer's
# resolv.conf for the duration and restore the symlink afterwards.
rm -f /mnt/etc/resolv.conf
cp /etc/resolv.conf /mnt/etc/resolv.conf

# ---------------------------------------------------------------------------
# Execute the steps inside the chroot.
# ---------------------------------------------------------------------------

log "entering ubuntu chroot"
chroot /mnt /bin/bash -e <<'CHROOT_EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/bin
export DEBIAN_PRIORITY=critical
. /tmp/bromure-build.env

# Route every request through the host's proxy — same rationale as the
# setup.sh bake: Apple's TLS handles VPN MITM setups that guest TLS
# stacks (Node, curl, apt-https) sometimes don't.
if [ -n "$BROMURE_PROXY" ]; then
    export http_proxy="$BROMURE_PROXY"
    export https_proxy="$BROMURE_PROXY"
    export HTTP_PROXY="$BROMURE_PROXY"
    export HTTPS_PROXY="$BROMURE_PROXY"
    _host_port="${BROMURE_PROXY##*://}"
    _proxy_host="${_host_port%%:*}"
    export no_proxy="localhost,127.0.0.1,::1,$_proxy_host"
    export NO_PROXY="$no_proxy"
    mkdir -p /etc/apt/apt.conf.d
    cat > /etc/apt/apt.conf.d/99-bromure-proxy <<APTCONF
Acquire::http::Proxy "$BROMURE_PROXY";
Acquire::https::Proxy "$BROMURE_PROXY";
Acquire::http::Proxy::$_proxy_host DIRECT;
Acquire::https::Proxy::$_proxy_host DIRECT;
APTCONF
fi

# Build-time apt/dpkg speedups — removed in the cleanup below, so they
# never ship in the image. Translations are dead weight in a headless
# chroot, and dpkg's per-file fsync discipline guards against a power
# loss the scratch-clone + atomic-promote flow already handles (a torn
# run is discarded whole, never promoted).
mkdir -p /etc/apt/apt.conf.d /etc/dpkg/dpkg.cfg.d
printf 'Acquire::Languages "none";\n' > /etc/apt/apt.conf.d/99-bromure-fast
printf 'force-unsafe-io\n' > /etc/dpkg/dpkg.cfg.d/99-bromure-unsafe-io

log() { printf '[ac-postinstall-chroot] %s (t+%ss)\n' "$*" "$SECONDS"; }

run_step() {
    # $1 = step script path. Line 1 is `# <description>`.
    local file="$1"
    local name
    name=$(sed -n '1s/^# *//p' "$file")
    [ -n "$name" ] || name=$(basename "$file")
    log "BEGIN step $name"
    local t0=$SECONDS
    local i
    for i in 1 2 3; do
        if bash -e "$file"; then
            log "END   step $name (took $((SECONDS - t0))s)"
            return 0
        fi
        log "retry $i/3 failed: $name"
        sleep 3
    done
    printf 'SANDBOX_POSTINSTALL_FAILED: step failed after 3 attempts: %s\n' "$name"
    exit 1
}

for f in /tmp/bromure-postinstall/*.sh; do
    [ -e "$f" ] || continue
    run_step "$f"
done

# Leave no bake-time residue in the image.
rm -f /etc/apt/apt.conf.d/99-bromure-proxy /etc/apt/apt.conf.d/99-bromure-fast
rm -f /etc/dpkg/dpkg.cfg.d/99-bromure-unsafe-io
rm -rf /tmp/bromure-postinstall /tmp/bromure-build.env
apt-get clean 2>/dev/null || true

log "chroot phase complete"
CHROOT_EOF

# ---------------------------------------------------------------------------
# Copy macOS fonts (same blocks as setup.sh — no-ops when the host didn't
# attach the shares, e.g. when amending an image that already has them).
# ---------------------------------------------------------------------------

log "copying macOS fonts into image (when shared)"
mkdir -p /tmp/macfonts-sys /tmp/macfonts-usr /tmp/macfonts-term
modprobe virtiofs 2>/dev/null || true
if mount -t virtiofs macos-fonts /tmp/macfonts-sys 2>/dev/null; then
    mkdir -p /mnt/usr/share/fonts/macos
    cp -a /tmp/macfonts-sys/. /mnt/usr/share/fonts/macos/ 2>/dev/null || \
        log "  copy of macOS system fonts had warnings (some sealed-system fonts skipped)"
    umount /tmp/macfonts-sys
fi
if mount -t virtiofs macos-user-fonts /tmp/macfonts-usr 2>/dev/null; then
    mkdir -p /mnt/usr/share/fonts/macos-user
    cp -a /tmp/macfonts-usr/. /mnt/usr/share/fonts/macos-user/ 2>/dev/null || true
    umount /tmp/macfonts-usr
fi
if mount -t virtiofs macos-terminal-fonts /tmp/macfonts-term 2>/dev/null; then
    mkdir -p /mnt/usr/share/fonts/macos
    cp -a /tmp/macfonts-term/. /mnt/usr/share/fonts/macos/ 2>/dev/null || true
    umount /tmp/macfonts-term
fi
rmdir /tmp/macfonts-sys /tmp/macfonts-usr /tmp/macfonts-term 2>/dev/null || true

chroot /mnt /bin/bash -c 'fc-cache -f >/dev/null 2>&1 || true'

# ---------------------------------------------------------------------------
# Restore runtime resolv.conf and tear down.
# ---------------------------------------------------------------------------

rm -f /mnt/etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

log "unmounting target"
umount /tmp/postinstall || true
umount /mnt/dev/pts || true
umount /mnt/dev     || true
umount /mnt/proc    || true
umount /mnt/sys     || true
umount /mnt/boot/efi
umount /mnt
sync

# Same integrity gate as setup.sh: never promote an image whose
# superblock carries the ext4 error flag (it would force a repair on
# the user's next boot). -p auto-fixes + clears the flag; >= 4 is real
# uncorrected damage.
if command -v e2fsck >/dev/null 2>&1; then
    log "running final e2fsck on $TARGET_ROOT"
    e2fsck -f -p "$TARGET_ROOT" || {
        rc=$?
        if [ "$rc" -ge 4 ]; then
            fail "e2fsck found uncorrectable errors on $TARGET_ROOT (exit $rc)"
        fi
        log "e2fsck corrected issues (exit $rc)"
    }
else
    log "e2fsck unavailable — skipping final filesystem check"
fi

log "all done"
echo "SANDBOX_POSTINSTALL_DONE"
