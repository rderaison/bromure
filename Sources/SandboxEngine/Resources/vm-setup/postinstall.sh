#!/bin/sh
# Bromure Web — browser base image postinstall script.
#
# Runs inside the same Alpine netboot installer environment as setup.sh,
# but against an ALREADY-INSTALLED browser disk (freshly downloaded from
# dl.bromure.io/browser-images/, or a local build being amended). Three
# jobs, all of them things a published image cannot carry:
#
#   1. Personalisation — re-render the keyboard/scrolling/locale templates
#      setup.sh bakes for local builds (a published image carries neutral
#      defaults).
#   2. macOS fonts — copy the user's own Apple fonts (never
#      redistributable) from the host's virtiofs shares, same cap logic
#      as setup.sh.
#   3. Catalog steps — chroot into the image and execute the postinstall
#      commands declared in browser-img-catalog.json (the non-free
#      software: Cloudflare WARP).
#
# The host watches stdout for SANDBOX_POSTINSTALL_DONE (success) or
# SANDBOX_POSTINSTALL_FAILED (any failure).
#
# Usage: postinstall.sh COPY_FONTS KB_LAYOUT NATURAL_SCROLLING LOCALE
#   COPY_FONTS          1 = copy macOS fonts from the fonts/userfonts
#                       shares (fresh download), 0 = skip (amending an
#                       image that already has them)
#   KB_LAYOUT/NATURAL_SCROLLING/LOCALE
#                       values to personalise with; "-" for all three =
#                       keep whatever the image already carries
#
# Shares the host attaches:
#   setup        — the vm-setup directory (read-only), same as setup.sh
#   postinstall  — a host temp dir containing steps/NNNN-<uuid8>.sh, one
#                  file per catalog step, executed in lexical order.
#                  Line 1 of each file is `# <human description>`.
#   fonts        — /System/Library/Fonts (only when COPY_FONTS=1)
#   userfonts    — /Library/Fonts (only when COPY_FONTS=1 and it exists)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COPY_FONTS="${1:-0}"
KB_LAYOUT_SPEC="${2:--}"
NATURAL_SCROLLING="${3:--}"
LOCALE="${4:--}"

# Host-side package proxy (same channel as setup.sh / the AC bake).
# ALPINE_REPO_BASE carries the proxy's guest URL when the host runs
# AlpinePackageProxy; exported as http(s)_proxy so the chroot's
# downloads (apk, the pinned WARP deb) ride the host's TLS stack.
# The proxy host itself must be in no_proxy or requests to the proxy
# would recurse through it forever.
: "${ALPINE_REPO_BASE:=https://dl-cdn.alpinelinux.org}"
PROXIED=""
case "$ALPINE_REPO_BASE" in
    *dl-cdn.alpinelinux.org*) ;;
    *)
        PROXIED=1
        export http_proxy="$ALPINE_REPO_BASE"
        export https_proxy="$ALPINE_REPO_BASE"
        export HTTP_PROXY="$ALPINE_REPO_BASE"
        export HTTPS_PROXY="$ALPINE_REPO_BASE"
        _host_port="${ALPINE_REPO_BASE##*://}"
        _proxy_host="${_host_port%%:*}"
        export no_proxy="localhost,127.0.0.1,::1,$_proxy_host"
        export NO_PROXY="$no_proxy"
        ;;
esac

log() { printf '[browser-postinstall] %s\n' "$*"; }
fail() { printf 'SANDBOX_POSTINSTALL_FAILED: %s\n' "$*"; exit 1; }

# e2fsprogs for the final integrity check below — the netboot initramfs
# doesn't ship e2fsck. Best-effort: a transient apk failure skips the
# check (setup.sh's own mkfs gated the artifact we started from) rather
# than failing the whole postinstall.
( apk update && apk add e2fsprogs ) >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Mount the installed system. The browser image is a whole-disk ext4
# filesystem on vda (no partition table — it direct-kernel-boots).
# ---------------------------------------------------------------------------

log "mounting installed system from /dev/vda"
modprobe ext4 2>/dev/null || true
mkdir -p /mnt
mount -t ext4 /dev/vda /mnt || fail "cannot mount root filesystem"

mount --bind /dev      /mnt/dev
mount -t proc  proc    /mnt/proc
mount -t sysfs sys     /mnt/sys

# ---------------------------------------------------------------------------
# Personalisation — same %%VAR%% substitution as setup.sh's
# install_template, re-rendered from the shared vm-setup configs. Skipped
# when the caller passes "-" (amending an image that's already personal).
# ---------------------------------------------------------------------------

if [ "$KB_LAYOUT_SPEC" != "-" ]; then
    case "$KB_LAYOUT_SPEC" in
        *:*) KB_LAYOUT="${KB_LAYOUT_SPEC%%:*}"; KB_VARIANT="${KB_LAYOUT_SPEC#*:}" ;;
        *)   KB_LAYOUT="$KB_LAYOUT_SPEC"; KB_VARIANT="" ;;
    esac
    render_template() {
        # render_template <source-relative-to-vm-setup> <dest-in-image>
        sed -e "s|%%KEYBOARD_LAYOUT%%|$KB_LAYOUT_SPEC|g" \
            -e "s|%%XKB_LAYOUT%%|$KB_LAYOUT|g" \
            -e "s|%%XKB_VARIANT%%|$KB_VARIANT|g" \
            -e "s|%%NATURAL_SCROLLING%%|$NATURAL_SCROLLING|g" \
            -e "s|%%LOCALE%%|$LOCALE|g" \
            "$SCRIPT_DIR/$1" > "$2"
    }
    log "personalising: layout=$KB_LAYOUT_SPEC scrolling=$NATURAL_SCROLLING locale=$LOCALE"
    render_template configs/locale.sh              /mnt/etc/profile.d/locale.sh
    render_template configs/xorg-20-keyboard.conf  /mnt/etc/X11/xorg.conf.d/20-keyboard.conf
    render_template configs/xorg-30-scrolling.conf /mnt/etc/X11/xorg.conf.d/30-scrolling.conf
fi

# ---------------------------------------------------------------------------
# macOS fonts (from the user's own Mac — never shipped in the image).
# Identical cap-copy logic to setup.sh.
# ---------------------------------------------------------------------------

if [ "$COPY_FONTS" = "1" ]; then
    mkdir -p /mnt/usr/share/fonts/macos
    MAX_FONTS_BYTES=734003200  # 700 MB cap to avoid filling the disk
    FONT_LIST=$(mktemp)
    for tag in fonts userfonts; do
        FMNT="/tmp/$tag"
        mkdir -p "$FMNT"
        mount -t virtiofs "$tag" "$FMNT" 2>/dev/null || continue
        find "$FMNT" -type f \( -name '*.ttf' -o -name '*.otf' -o -name '*.ttc' -o -name '*.TTF' -o -name '*.OTF' -o -name '*.TTC' \) \
            -exec stat -c '%s %n' {} + >> "$FONT_LIST"
    done
    sort -n "$FONT_LIST" | awk -v max="$MAX_FONTS_BYTES" '{sz+=$1; if(sz>max) exit; print substr($0, index($0," ")+1)}' \
        | while IFS= read -r path; do cp -- "$path" /mnt/usr/share/fonts/macos/; done
    rm -f "$FONT_LIST"
    for tag in fonts userfonts; do umount "/tmp/$tag" 2>/dev/null; done
    MACOS_FONT_COUNT=$(find /mnt/usr/share/fonts/macos/ -type f 2>/dev/null | wc -l)
    log "copied $MACOS_FONT_COUNT macOS font files"

    # Refresh the font cache so X11/Chromium don't scan on first boot.
    chroot /mnt fc-cache -f || true
fi

# ---------------------------------------------------------------------------
# Bring in the step files from the host and run them in the chroot.
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

# The image bakes static public DNS (setup.sh writes 1.1.1.1) — swap in
# the installer's resolv.conf for the chroot (it may carry the working
# vmnet gateway) and restore the static file afterwards, so no build-time
# network detail leaks into the image.
cp /mnt/etc/resolv.conf /tmp/resolv.conf.image 2>/dev/null || true
cp /etc/resolv.conf /mnt/etc/resolv.conf

# Same treatment for apk's repositories: point them at the proxy for the
# duration of the steps (plain HTTP, host-side TLS), restore the image's
# canonical HTTPS URLs afterwards.
if [ -n "$PROXIED" ]; then
    cp /mnt/etc/apk/repositories /tmp/repositories.image 2>/dev/null || true
    sed "s|https://dl-cdn.alpinelinux.org|$ALPINE_REPO_BASE|" \
        /tmp/repositories.image > /mnt/etc/apk/repositories 2>/dev/null || true
fi

if [ "$STEP_COUNT" -gt 0 ]; then
    # The steps download packages from inside the chroot — verify the VM
    # actually has connectivity first, so a broken network fails in
    # seconds with a clear message instead of as three opaque apk/wget
    # retries per step.
    NETWORK_OK=""
    # Probe through the proxy when one is up — that's the exact path the
    # steps' downloads take. Plain HTTP (the netboot busybox wget has no
    # TLS helper), proxy env cleared per-invocation so the probe can't
    # recurse through the proxy itself.
    NET_PROBE="http://dl-cdn.alpinelinux.org/alpine/"
    [ -n "$PROXIED" ] && NET_PROBE="$ALPINE_REPO_BASE/alpine/"
    for i in $(seq 1 30); do
        if http_proxy= https_proxy= wget -q -O /dev/null --spider "$NET_PROBE" 2>/dev/null; then
            NETWORK_OK=1
            break
        fi
        sleep 1
    done
    [ -n "$NETWORK_OK" ] || fail "no network connectivity in the postinstall VM — the packages (Cloudflare WARP) cannot be downloaded; check VPN/DNS settings and retry"

    log "entering alpine chroot"
    chroot /mnt /bin/sh -e <<'CHROOT_EOF'
set -e
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/bin

log() { printf '[browser-postinstall-chroot] %s\n' "$*"; }

run_step() {
    # $1 = step script path. Line 1 is `# <description>`.
    file="$1"
    name=$(sed -n '1s/^# *//p' "$file")
    [ -n "$name" ] || name=$(basename "$file")
    log "BEGIN step $name"
    for i in 1 2 3; do
        if sh -e "$file"; then
            log "END   step $name"
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

# Leave no residue in the image.
rm -rf /tmp/bromure-postinstall

log "chroot phase complete"
CHROOT_EOF
fi

# ---------------------------------------------------------------------------
# Restore the baked resolv.conf and tear down.
# ---------------------------------------------------------------------------

if [ -f /tmp/resolv.conf.image ]; then
    cp /tmp/resolv.conf.image /mnt/etc/resolv.conf
else
    printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' > /mnt/etc/resolv.conf
fi
if [ -n "$PROXIED" ] && [ -f /tmp/repositories.image ]; then
    cp /tmp/repositories.image /mnt/etc/apk/repositories
fi
rm -rf /mnt/tmp/bromure-postinstall

log "unmounting target"

# A step may leave a daemon running inside the chroot — newer warp-cli
# spawns the warp-svc background service even for `--version`. Its open
# fds and cwd keep /mnt/dev and /mnt busy, so the umounts below fail, the
# script errors before poweroff, and the VM hangs at a login shell. Kill
# anything still rooted in the chroot first; this teardown runs with root
# '/', so it never matches (and can't kill) itself.
for p in /proc/[0-9]*; do
    [ -e "$p/root" ] || continue
    case "$(readlink "$p/root" 2>/dev/null)" in
        /mnt|/mnt/*) kill -9 "${p#/proc/}" 2>/dev/null || true ;;
    esac
done
sync
sleep 1

# Lazy fallback only as a last resort; the kill above should let the plain
# umount succeed, which matters because e2fsck runs on /dev/vda next.
umount /tmp/postinstall || umount -l /tmp/postinstall || true
umount /mnt/dev  || umount -l /mnt/dev  || true
umount /mnt/proc || umount -l /mnt/proc || true
umount /mnt/sys  || umount -l /mnt/sys  || true
umount /mnt      || umount -l /mnt      || true
sync

# Same integrity gate as the AC pipeline: never promote an image whose
# superblock carries the ext4 error flag (it would force a repair on the
# user's next boot). -p auto-fixes + clears the flag; >= 4 is real
# uncorrected damage.
if command -v e2fsck >/dev/null 2>&1; then
    log "running final e2fsck on /dev/vda"
    e2fsck -f -p /dev/vda || {
        rc=$?
        if [ "$rc" -ge 4 ]; then
            fail "e2fsck found uncorrectable errors on /dev/vda (exit $rc)"
        fi
        log "e2fsck corrected issues (exit $rc)"
    }
else
    log "e2fsck unavailable — skipping final filesystem check"
fi

log "all done"
echo "SANDBOX_POSTINSTALL_DONE"
