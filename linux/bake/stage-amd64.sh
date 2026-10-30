#!/bin/bash
# stage-amd64.sh <vm-setup dir> <out dir>
# Copies vm-setup and rewrites setup.sh's arm64-only lines for an amd64 QEMU guest.
# STOPGAP: the bake should run setup.sh unmodified once it takes the arch from
# `uname -m` (see linux/bake/README.md, "proposed changes"). Every rewrite is
# asserted, so a setup.sh change that moves these lines fails the bake loudly.
set -euo pipefail
SRC=$1; OUT=$2
rm -rf "$OUT"; cp -a "$SRC" "$OUT"
S=$OUT/setup.sh
sub() { grep -qF -- "$1" "$S" || { echo "stage-amd64: '$1' not found in setup.sh" >&2; exit 1; }
        python3 - "$S" "$1" "$2" <<'PY'
import sys; p, a, b = sys.argv[1:]; t = open(p).read(); open(p, "w").write(t.replace(a, b))
PY
}
sub '--arch=arm64' '--arch=amd64'
sub 'grub-efi-arm64 grub-efi-arm64-bin' 'grub-efi-amd64 grub-efi-amd64-bin'
sub 'GRUB_CMDLINE_LINUX="console=hvc0 root=LABEL=root rootfstype=ext4 arm64.nosme"' \
    'GRUB_CMDLINE_LINUX="console=ttyS0 root=LABEL=root rootfstype=ext4"'
sub '--target=arm64-efi' '--target=x86_64-efi'
sub '--bootloader-id=BOOTAA64' '--bootloader-id=BOOTX64'
# Not arch: setup.sh:235 hands ALPINE_REPO_BASE to the chroot as BROMURE_PROXY even when it is
# the plain CDN default, which setup.sh:79 deliberately does NOT treat as a proxy. apt then sends
# every Ubuntu request to dl-cdn.alpinelinux.org as a forward proxy (Fastly: "500 Domain Not Found").
# Same condition as :79 here; proposed as a fix to setup.sh itself.
sub '    echo "BROMURE_PROXY=$ALPINE_REPO_BASE"' \
    '    if [ "$ALPINE_REPO_BASE" != "http://dl-cdn.alpinelinux.org" ]; then echo "BROMURE_PROXY=$ALPINE_REPO_BASE"; fi'
! grep -nE 'arm64|aarch64' "$S" | grep -vE '^\s*[0-9]+:\s*#|case "\$ARCH"' || { echo "stage-amd64: arm64 left in setup.sh (above)" >&2; exit 1; }
