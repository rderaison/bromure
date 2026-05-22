#!/bin/sh
# Bromure Agentic Coding — base image build script.
#
# Runs inside an Alpine Linux netboot installer driven by the host over
# the serial console. The host watches stdout for the SANDBOX_SETUP_DONE
# marker (success) or SANDBOX_SETUP_FAILED (any failure).
#
# This is the unified script: the same file runs on macOS (arm64 host →
# arm64 guest) and Windows (amd64 host → amd64 guest). Architecture
# detection happens once at the top via `uname -m`, then every
# arch-specific token is referenced through a variable.
#
# Pipeline:
#   1. Partition vda (GPT, EFI + ext4) and format.
#   2. debootstrap Ubuntu 24.04 (Noble) for ${DEB_ARCH} onto /mnt.
#   3. Bind-mount /dev /proc /sys, chroot, install kernel/grub/agents.
#   4. grub-install for EFI boot from vda1.
#   5. umount, sync, print marker.
#
# This script trusts the host network filter to gate egress; it does not
# add its own DNS entries. If apk/apt fail, that's an upstream config issue.

set -e

# Args from the host: $1 = host backingScaleFactor (1 on regular display,
# 2 on Retina). Used in the chroot to compute the kitty font size.
DISPLAY_SCALE="${1:-2}"

UBUNTU_RELEASE="${UBUNTU_RELEASE:-noble}"

# ---------------------------------------------------------------------------
# Architecture detection.
# ---------------------------------------------------------------------------
case "$(uname -m)" in
    aarch64|arm64)
        DEB_ARCH=arm64
        EFI_ARCH=arm64
        EFI_BOOT_DIR=BOOTAA64
        KERN_EXTRA_CMDLINE="arm64.nosme"
        UBUNTU_MIRROR_DEFAULT="http://ports.ubuntu.com/ubuntu-ports"
        ;;
    x86_64|amd64)
        DEB_ARCH=amd64
        EFI_ARCH=x86_64
        EFI_BOOT_DIR=BOOTX64
        KERN_EXTRA_CMDLINE=""
        UBUNTU_MIRROR_DEFAULT="http://archive.ubuntu.com/ubuntu"
        ;;
    *)
        echo "SANDBOX_SETUP_FAILED: unsupported host arch $(uname -m)"
        exit 1
        ;;
esac
UBUNTU_MIRROR="${UBUNTU_MIRROR:-$UBUNTU_MIRROR_DEFAULT}"

# TARGET_DEV: which block device receives the installed Ubuntu.
# HCS/Hyper-V Gen2 exposes SCSI as /dev/sda; macOS-VZ and QEMU expose
# virtio-blk as /dev/vda. Honour the host driver's env-var override
# (the Windows HyperVAlpineBaker sets TARGET_DEV=/dev/sda); else probe.
if [ -z "${TARGET_DEV:-}" ]; then
    for dev in /dev/vda /dev/sda /dev/nvme0n1; do
        [ -b "$dev" ] || continue
        # Skip whatever Alpine itself is running from.
        grep -qE "^${dev}[[:space:]]" /proc/mounts && continue
        TARGET_DEV="$dev"
        break
    done
    [ -z "${TARGET_DEV:-}" ] && fail "could not auto-detect TARGET_DEV (none of /dev/vda /dev/sda /dev/nvme0n1 are present)"
fi
# Partition suffix differs for NVMe (pN) vs virtio/SCSI (N).
case "$TARGET_DEV" in
    *nvme*) TARGET_PART_SUFFIX="p" ;;
    *)      TARGET_PART_SUFFIX="" ;;
esac
TARGET_EFI=${TARGET_DEV}${TARGET_PART_SUFFIX}1
TARGET_ROOT=${TARGET_DEV}${TARGET_PART_SUFFIX}2

log() { printf '[ac-setup] %s\n' "$*"; }
fail() { printf 'SANDBOX_SETUP_FAILED: %s\n' "$*"; exit 1; }

retry() {
    for i in 1 2 3; do
        "$@" && return 0
        log "retry $i/3 failed: $*"
        sleep 2
    done
    fail "command failed after 3 attempts: $*"
}

# ---------------------------------------------------------------------------
# Alpine-side: install the bootstrap toolchain.
# debootstrap is in the community repo; ensure it's enabled.
# ---------------------------------------------------------------------------

# Sync the system clock before any apt/apk operation. The bake VM's
# RTC is whatever the hypervisor's firmware passed at boot — on
# Hyper-V Gen2 VMs that's often hours off real time, which trips
# apt's "InRelease file not yet valid" check inside the chroot
# (Ubuntu signs Release files with a future-bounded validity
# window). busybox ntpd does a single iburst sync and exits; the
# `|| true` tail is defensive — if NTP UDP/123 egress is firewalled
# we still try and rely on the Acquire::Check-Valid-Until=false
# fallback below. time.cloudflare.com is more firewall-tolerant
# than pool.ntp.org.
log "syncing clock (was: $(date -u +%FT%TZ))"
busybox ntpd -d -q -n -p time.cloudflare.com 2>&1 | head -3 || true
log "clock now: $(date -u +%FT%TZ)"

log "preparing alpine bootstrap toolchain (host arch: $(uname -m), guest: $DEB_ARCH)"
. /etc/os-release 2>/dev/null || true
ALPINE_VER="${VERSION_ID:-3.22}"
ALPINE_VER_SHORT=$(echo "$ALPINE_VER" | cut -d. -f1,2)
# The macOS port boots Alpine via netboot with
#   alpine_repo=https://dl-cdn.alpinelinux.org/alpine/v3.22/main
# in the kernel cmdline, so its initramfs auto-adds the main repo to
# /etc/apk/repositories. The Windows path boots from the Alpine virt
# ISO, whose stock /etc/apk/repositories only contains the on-ISO
# local cache (/media/sr0/apks) — not enough to apk add parted,
# ca-certificates, tar, etc. Add main + community explicitly here;
# the macOS path already has main so the duplicate-check skips.
if ! grep -q '/main' /etc/apk/repositories; then
    echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER_SHORT}/main" \
        >> /etc/apk/repositories
fi
if ! grep -q '/community' /etc/apk/repositories; then
    echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER_SHORT}/community" \
        >> /etc/apk/repositories
fi

retry apk update
# GNU tar + xz + zstd: debootstrap's dpkg-deb extractor shells out to tar,
# and BusyBox tar fails on some Ubuntu .deb data tarballs (xattrs, etc.).
# zstd is needed because newer Ubuntu compresses control.tar.zst.
retry apk add e2fsprogs dosfstools parted util-linux \
    ca-certificates wget debootstrap \
    tar xz zstd

# ---------------------------------------------------------------------------
# Partition + format target disk.
#  - 512 MiB FAT32 EFI System Partition
#  - rest ext4 root
# ---------------------------------------------------------------------------

log "partitioning $TARGET_DEV"
# parted is in the base toolchain we just installed; sgdisk would be
# preferable but Alpine doesn't ship it under a stable package name.
parted -s "$TARGET_DEV" \
    mklabel gpt \
    mkpart EFI  fat32 1MiB 513MiB \
    mkpart root ext4  513MiB 100% \
    set 1 esp on
partprobe "$TARGET_DEV" 2>/dev/null || true

# Wait for the kernel to expose the new partitions; busybox mdev is
# slower than udev and partprobe alone may race the next mkfs.
for i in 1 2 3 4 5; do
    [ -b "$TARGET_EFI" ] && [ -b "$TARGET_ROOT" ] && break
    sleep 1
done

mkfs.vfat -F32 -n EFI "$TARGET_EFI"
mkfs.ext4 -q -F -L root "$TARGET_ROOT"

mkdir -p /mnt
mount -t ext4 "$TARGET_ROOT" /mnt
mkdir -p /mnt/boot/efi
mount -t vfat "$TARGET_EFI" /mnt/boot/efi

# ---------------------------------------------------------------------------
# debootstrap Ubuntu Noble.
# --variant=minbase keeps the rootfs small; everything we need lands in
# the chroot phase below.
# ---------------------------------------------------------------------------

log "debootstrapping Ubuntu $UBUNTU_RELEASE for $DEB_ARCH (this is the slow step, ~3-5 min)"
retry debootstrap \
    --arch=$DEB_ARCH \
    --variant=minbase \
    --include=ca-certificates,curl,gnupg,sudo,locales,tzdata \
    --components=main,universe \
    "$UBUNTU_RELEASE" /mnt "$UBUNTU_MIRROR"

# ---------------------------------------------------------------------------
# Set up sources.list inside the chroot so apt finds main + universe.
# ---------------------------------------------------------------------------

cat > /mnt/etc/apt/sources.list <<EOF
deb $UBUNTU_MIRROR $UBUNTU_RELEASE main universe
deb $UBUNTU_MIRROR ${UBUNTU_RELEASE}-updates main universe
deb $UBUNTU_MIRROR ${UBUNTU_RELEASE}-security main universe
EOF

# fstab — reference partitions by label so device renames don't break boot.
# Everything else (virtiofs on macOS host, iso9660+sshfs on Windows) is
# mounted by bromure-mount-meta on boot. Keeping virtiofs entries in
# fstab produced [FAILED] systemd-fstab-generator messages on Windows
# (no virtiofs device backend), and the macOS path was no different in
# spirit since share-2..share-8 routinely have nothing attached. Single
# code path for both hosts: bromure-mount-meta probes each tag silently.
cat > /mnt/etc/fstab <<'EOF'
LABEL=root     /               ext4     defaults,noatime  0  1
LABEL=EFI      /boot/efi       vfat     umask=0077        0  2
EOF
mkdir -p /mnt/mnt/bromure-meta /mnt/mnt/bromure-outbox \
         /mnt/mnt/bromure-share-1 /mnt/mnt/bromure-share-2 \
         /mnt/mnt/bromure-share-3 /mnt/mnt/bromure-share-4 \
         /mnt/mnt/bromure-share-5 /mnt/mnt/bromure-share-6 \
         /mnt/mnt/bromure-share-7 /mnt/mnt/bromure-share-8

echo "bromure-ac" > /mnt/etc/hostname
cat > /mnt/etc/hosts <<'EOH'
127.0.0.1       localhost
127.0.1.1       bromure-ac
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOH

mkdir -p /mnt/tmp
echo "DISPLAY_SCALE=$DISPLAY_SCALE" > /mnt/tmp/bromure-build.env
echo "EFI_ARCH=$EFI_ARCH"           >> /mnt/tmp/bromure-build.env
echo "DEB_ARCH=$DEB_ARCH"           >> /mnt/tmp/bromure-build.env
echo "EFI_BOOT_DIR=$EFI_BOOT_DIR"   >> /mnt/tmp/bromure-build.env
echo "KERN_EXTRA_CMDLINE=$KERN_EXTRA_CMDLINE" >> /mnt/tmp/bromure-build.env
# BROMURE_HOST = "windows" | "macos". The Windows HyperVAlpineBaker
# passes BROMURE_HOST=windows; macOS leaves it unset and the chroot
# defaults to "macos". The chroot phase uses this to decide whether
# to install the weston-rdp + hvsock-proxy stack (Windows-only — no
# framebuffer device on HCS-direct VMs) or the X11 + openbox + kitty
# stack (macOS-only — VZ framebuffer rendering).
echo "BROMURE_HOST=${BROMURE_HOST:-macos}" >> /mnt/tmp/bromure-build.env

# Copy the hvsocket→TCP proxy source from the setup ISO into the
# chroot's /tmp so the chroot phase can `gcc` it. Only meaningful on
# Windows; on macOS the file is absent and the cp silently no-ops.
if [ -f /tmp/setup/hvsock-proxy.c ]; then
    cp /tmp/setup/hvsock-proxy.c /mnt/tmp/hvsock-proxy.c
fi
if [ -f /tmp/setup/title-pusher.c ]; then
    cp /tmp/setup/title-pusher.c /mnt/tmp/title-pusher.c
fi
if [ -f /tmp/setup/overlay-fetch.c ]; then
    cp /tmp/setup/overlay-fetch.c /mnt/tmp/overlay-fetch.c
fi
if [ -f /tmp/setup/cmd-server.c ]; then
    cp /tmp/setup/cmd-server.c /mnt/tmp/cmd-server.c
fi
if [ -f /tmp/setup/ssh-agent-bridge.c ]; then
    cp /tmp/setup/ssh-agent-bridge.c /mnt/tmp/ssh-agent-bridge.c
fi
if [ -f /tmp/setup/bromure-aws-credentials.py ]; then
    cp /tmp/setup/bromure-aws-credentials.py /mnt/tmp/bromure-aws-credentials.py
fi

cp /etc/resolv.conf /mnt/etc/resolv.conf

# ---------------------------------------------------------------------------
# Bind-mount + enter chroot for the rest of provisioning.
# ---------------------------------------------------------------------------

mount --bind /dev      /mnt/dev
mount --bind /dev/pts  /mnt/dev/pts
mount -t proc  proc    /mnt/proc
mount -t sysfs sys     /mnt/sys

log "entering ubuntu chroot"
chroot /mnt /bin/bash -e <<'CHROOT_EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_PRIORITY=critical
. /tmp/bromure-build.env
KITTY_FONT_SIZE=$((14 * DISPLAY_SCALE))

log() { printf '[ac-chroot] %s (t+%ss)\n' "$*" "$SECONDS"; }
fail() { printf 'SANDBOX_SETUP_FAILED: %s\n' "$*"; exit 1; }

step() {
    local name="$1"; shift
    log "BEGIN $name"
    local t0=$SECONDS
    "$@"
    log "END   $name (${SECONDS}s, took $((SECONDS - t0))s)"
}

retry() {
    for i in 1 2 3; do
        "$@" && return 0
        log "retry $i/3 failed: $*"
        sleep 3
    done
    fail "command failed after 3 attempts: $*"
}

sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

# ---------------------------------------------------------------------------
# Kernel + EFI bootloader.
# ---------------------------------------------------------------------------

step "apt-get update" \
    retry apt-get update -y -qq -o Acquire::Check-Valid-Until=false
step "apt-get dist-upgrade" \
    retry apt-get dist-upgrade -y -q -o Dpkg::Options::="--force-confnew"
step "apt-get install kernel+grub+systemd+base" \
    retry apt-get install -y -q --no-install-recommends \
        linux-image-virtual initramfs-tools \
        grub-efi-${DEB_ARCH} grub-efi-${DEB_ARCH}-bin efibootmgr \
        systemd systemd-sysv systemd-resolved udev \
        iproute2 iputils-ping netbase isc-dhcp-client \
        openssh-client git build-essential pkg-config \
        less nano vim screen tmux \
        docker.io \
        fontconfig

# Kernel cmdline.
EXTRA="${KERN_EXTRA_CMDLINE}"
[ -n "$EXTRA" ] && EXTRA=" $EXTRA"
cat > /etc/default/grub <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_RECORDFAIL_TIMEOUT=0
GRUB_DISTRIBUTOR=Ubuntu
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=7 systemd.log_level=info systemd.log_target=console systemd.show_status=true systemd.journald.forward_to_console=1"
GRUB_CMDLINE_LINUX="console=ttyS0,115200n8 console=tty0 root=LABEL=root rootfstype=ext4${EXTRA}"
GRUB_TERMINAL=console
EOF

log "installing GRUB to EFI partition (removable mode)"
grub-install --target=${EFI_ARCH}-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=${EFI_BOOT_DIR} \
    --no-nvram \
    --removable
update-grub

# ---------------------------------------------------------------------------
# X server + minimal terminal session
# ---------------------------------------------------------------------------

step "pre-seed keyboard-configuration to a minimal US default" \
    sh -c '
        echo "keyboard-configuration keyboard-configuration/layoutcode select us"     | debconf-set-selections
        echo "keyboard-configuration keyboard-configuration/modelcode select pc105"   | debconf-set-selections
        echo "keyboard-configuration keyboard-configuration/variantcode select"       | debconf-set-selections
        echo "keyboard-configuration keyboard-configuration/optionscode select"       | debconf-set-selections
        echo "keyboard-configuration keyboard-configuration/xkb-keymap select us"     | debconf-set-selections
        echo "console-setup console-setup/codeset47 select Guess optimal character set" | debconf-set-selections
    '

step "apt-get install X + WM + fonts" \
    retry env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
        xserver-xorg-core xserver-xorg-legacy \
        xserver-xorg-input-libinput \
        xserver-xorg-video-modesetting \
        xinit xauth \
        x11-xserver-utils x11-xkb-utils \
        keyboard-configuration console-setup \
        xkb-data \
        openbox xdotool \
        spice-vdagent \
        libgl1-mesa-dri \
        fonts-jetbrains-mono fonts-noto-color-emoji \
        libfontconfig1 libxcb1 libxkbcommon0

cat > /etc/default/keyboard <<'EOK'
XKBMODEL="pc105"
XKBLAYOUT="us"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOK

install -d /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<'EOX'
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "us"
    Option "XkbModel" "pc105"
EndSection
EOX

# ---------------------------------------------------------------------------
# Node.js (NodeSource current LTS)
# ---------------------------------------------------------------------------

step "fetch NodeSource setup script" \
    retry curl -fsSL https://deb.nodesource.com/setup_lts.x -o /tmp/nodesource.sh
step "run NodeSource setup script (adds apt repo)" \
    retry bash /tmp/nodesource.sh
step "apt-get install nodejs" \
    retry apt-get install -y -q --no-install-recommends nodejs
log "node $(node --version), npm $(npm --version)"

step "npm install -g @socketsecurity/cli" \
    retry npm install -g --silent @socketsecurity/cli

socket_npm() {
    npx --yes @socketsecurity/cli npm "$@"
}

step "npm install -g @anthropic-ai/claude-code (via socket)" \
    retry socket_npm install -g --silent @anthropic-ai/claude-code

step "npm install -g @openai/codex (via socket)" \
    retry socket_npm install -g --silent @openai/codex

step "apt-get install kitty (+ xterm fallback)" \
    retry apt-get install -y -q --no-install-recommends kitty xterm

step "apt-get install terminal multiplexers (screen + tmux)" \
    retry apt-get install -y -q --no-install-recommends screen tmux

step "apt-get install bubblewrap" \
    retry apt-get install -y -q --no-install-recommends bubblewrap

# sshfs + fuse3 + jq: project-folder share between Windows host and
# guest goes via SSHFS over slirp NAT (host runs MSYS2 sshd; see
# windows/Bromure.SandboxEngine/Sharing/FolderShareServer.cs). jq
# parses /mnt/bromure-meta/shares.json. openssh-client provides the
# ssh / ssh-keyscan / ssh-keygen the helper script may need.
step "apt-get install sshfs + fuse3 + openssh-client + jq" \
    retry apt-get install -y -q --no-install-recommends \
        sshfs fuse3 openssh-client jq

step "apt-get install rdate" \
    retry apt-get install -y -q --no-install-recommends rdate

# ---------------------------------------------------------------------------
# bromure-meta share mount — portable across virtiofs (macOS host) and
# ISO9660 (Windows host, fsdev-disabled QEMU). The fstab entry above
# tries virtiofs unconditionally with nofail; this systemd unit covers
# the Windows path by mounting an ISO with volume label "bromuremeta"
# at /mnt/bromure-meta if virtiofs didn't take.
#
# We also write a tiny helper script the user / bashrc can call to
# query whether the share is alive, useful for diagnostics.
# ---------------------------------------------------------------------------

cat > /usr/local/bin/bromure-mount-meta <<'EOM'
#!/bin/sh
# Stage 1 — mount the metadata payload at /mnt/bromure-meta:
#   * virtiofs (macOS host) — fstab already tried; we just check.
#   * iso9660 by volume label "bromuremeta" (Windows host).
# Stage 2 — if shares.json is present (Windows path), set up sshfs
# mounts to the host's project folders. The host runs an MSYS2 sshd
# on port 2222 (FolderShareServer.cs); we have a per-session keypair
# in /mnt/bromure-meta/bromure-ssh-key.

set -e
TARGET=/mnt/bromure-meta
mkdir -p "$TARGET"

# --- Stage 1: metadata mount -------------------------------------------
if ! mountpoint -q "$TARGET"; then
    DEV=$(blkid -L bromuremeta 2>/dev/null || true)
    if [ -n "$DEV" ]; then
        mount -t iso9660 -o ro,nodev,nosuid "$DEV" "$TARGET"
    fi
fi

# --- Stage 1.5: per-session /home/ubuntu overlay -----------------------
# home.tar carries every profile-derived dotfile the host built for
# this session: kitty.conf, .bashrc, .bash_profile, .gitconfig,
# .config/gh, .config/glab-cli, .aws, .kube, .config/doctl, .docker, ...
# Extract over /home/ubuntu — overwriting matches the macOS virtiofs
# overlay semantics (host's view of the home dir is authoritative).
# --no-same-owner so files belong to ubuntu:ubuntu regardless of how
# the host's tar was packed.
if [ -f "$TARGET/home.tar" ]; then
    tar -xf "$TARGET/home.tar" -C /home/ubuntu --no-same-owner --no-same-permissions 2>/dev/null || \
        echo "bromure-mount-meta: home.tar extraction had warnings" >&2
    chown -R ubuntu:ubuntu /home/ubuntu
fi

# --- Stage 2: project folders via sshfs --------------------------------
SHARES_JSON="$TARGET/shares.json"
SSH_KEY_SRC="$TARGET/bromure-ssh-key"
if [ ! -f "$SHARES_JSON" ] || [ ! -f "$SSH_KEY_SRC" ]; then
    exit 0   # ISO carried no share config; macOS-virtiofs path or no shares this session
fi
if ! command -v jq >/dev/null 2>&1 || ! command -v sshfs >/dev/null 2>&1; then
    echo "bromure-mount-meta: jq or sshfs missing; cannot set up project folders" >&2
    exit 0
fi

# /mnt/bromure-meta is mounted read-only (iso9660) on Windows, so we
# can't `chmod 600` the key in place. Copy to a writable location
# first; sshfs requires 0600 perms or it refuses to use the key.
KEY_DIR=/run/bromure-ssh
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"
cp "$SSH_KEY_SRC" "$KEY_DIR/key"
chmod 600 "$KEY_DIR/key"

HOST=$(jq -r '.ssh.host // "10.0.2.2"' "$SHARES_JSON")
PORT=$(jq -r '.ssh.port // 2222' "$SHARES_JSON")
USER=$(jq -r '.ssh.user' "$SHARES_JSON")

# Iterate shares[]. Each entry: { guest_path, host_path, read_only }.
COUNT=$(jq '.shares | length' "$SHARES_JSON")
i=0
while [ "$i" -lt "$COUNT" ]; do
    GUEST=$(jq -r ".shares[$i].guest_path" "$SHARES_JSON")
    HOST_PATH=$(jq -r ".shares[$i].host_path" "$SHARES_JSON")
    RO=$(jq -r ".shares[$i].read_only // false" "$SHARES_JSON")
    i=$((i + 1))

    [ -z "$GUEST" ] && continue
    [ -z "$HOST_PATH" ] && continue
    mkdir -p "$GUEST"

    if mountpoint -q "$GUEST"; then
        continue   # already mounted by something else
    fi

    OPTS="IdentityFile=$KEY_DIR/key,StrictHostKeyChecking=no,UserKnownHostsFile=/dev/null,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,allow_other,default_permissions"
    [ "$RO" = "true" ] && OPTS="$OPTS,ro"

    # sshfs returns 0 on success. If the host sshd isn't up yet (race
    # against QEMU userspace startup), retry a few times. Don't `set -e`
    # past this — share-mount failure shouldn't kill the boot.
    set +e
    for attempt in 1 2 3 4 5; do
        sshfs -p "$PORT" -o "$OPTS" "$USER@$HOST:$HOST_PATH" "$GUEST" 2>/dev/null
        rc=$?
        [ "$rc" -eq 0 ] && break
        sleep 2
    done
    if [ "$rc" -ne 0 ]; then
        echo "bromure-mount-meta: sshfs $USER@$HOST:$HOST_PATH → $GUEST failed (rc=$rc)" >&2
    fi
    set -e
done
EOM
chmod +x /usr/local/bin/bromure-mount-meta

cat > /etc/systemd/system/bromure-meta-mount.service <<'EOM'
[Unit]
Description=Mount Bromure metadata share + apply per-session /home/ubuntu overlay
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target getty@tty1.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/bromure-mount-meta

[Install]
WantedBy=multi-user.target
EOM
systemctl enable bromure-meta-mount.service >/dev/null 2>&1 || true

cat > /etc/systemd/system/bromure-resume.path <<'EOP'
[Unit]
Description=Watch for Bromure VM resume signal from host

[Path]
PathChanged=/mnt/bromure-meta/.resume-signal

[Install]
WantedBy=multi-user.target
EOP

cat > /etc/systemd/system/bromure-resume.service <<'EOS'
[Unit]
Description=Re-sync clock after Bromure VM restore
After=mnt-bromure\x2dmeta.mount
Requires=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/rdate -n -s pool.ntp.org
EOS

systemctl enable bromure-resume.path >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# GitHub CLI (gh)
# ---------------------------------------------------------------------------

step "fetch gh apt signing key" \
    retry sh -c 'curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        > /usr/share/keyrings/githubcli-archive-keyring.gpg'
chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
step "apt-get update (after adding gh repo)" \
    retry apt-get update -y -qq -o Acquire::Check-Valid-Until=false
step "apt-get install gh" \
    retry apt-get install -y -q --no-install-recommends gh

# ---------------------------------------------------------------------------
# GitLab CLI (glab)
# ---------------------------------------------------------------------------

step "install glab from latest GitLab release deb (best effort)" \
    sh -c '
        set -e
        ARCH=$(dpkg --print-architecture)
        TAG=$(curl -fsSL https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases \
              | grep -o "\"tag_name\":\"[^\"]*\"" \
              | head -1 \
              | cut -d"\"" -f4 \
              || true)
        if [ -z "$TAG" ]; then
            echo "  glab: API lookup failed, using pinned fallback v1.45.0"
            TAG="v1.45.0"
        fi
        VER=${TAG#v}
        URL="https://gitlab.com/gitlab-org/cli/-/releases/${TAG}/downloads/glab_${VER}_linux_${ARCH}.deb"
        echo "  fetching $URL"
        if curl -fsSL -o /tmp/glab.deb "$URL"; then
            dpkg -i /tmp/glab.deb || apt-get install -f -y -q
            rm -f /tmp/glab.deb
        else
            echo "  glab download failed; skipping"
        fi
    ' || true

# ---------------------------------------------------------------------------
# Cloud + Kubernetes CLIs.
# ---------------------------------------------------------------------------

step "install kubectl (latest stable)" \
    sh -c '
        set -e
        ARCH=$(dpkg --print-architecture)
        case "$ARCH" in arm64|aarch64) K=arm64 ;; amd64|x86_64) K=amd64 ;; *) echo "  unsupported arch $ARCH"; exit 0 ;; esac
        STABLE=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
        URL="https://dl.k8s.io/release/${STABLE}/bin/linux/${K}/kubectl"
        echo "  fetching $URL"
        curl -fsSL -o /tmp/kubectl "$URL"
        install -m 755 /tmp/kubectl /usr/local/bin/kubectl
        rm -f /tmp/kubectl
        echo "  installed kubectl ${STABLE}"
    ' || true

step "install doctl (DigitalOcean CLI)" \
    sh -c '
        set -e
        ARCH=$(dpkg --print-architecture)
        case "$ARCH" in arm64|aarch64) K=arm64 ;; amd64|x86_64) K=amd64 ;; *) echo "  unsupported arch $ARCH"; exit 0 ;; esac
        TAG=$(curl -fsSL https://api.github.com/repos/digitalocean/doctl/releases/latest \
              | grep -m1 "\"tag_name\"" | cut -d"\"" -f4)
        VER=${TAG#v}
        URL="https://github.com/digitalocean/doctl/releases/download/${TAG}/doctl-${VER}-linux-${K}.tar.gz"
        echo "  fetching $URL"
        TMP=$(mktemp -d)
        curl -fsSL "$URL" -o "$TMP/doctl.tar.gz"
        tar -xzf "$TMP/doctl.tar.gz" -C "$TMP"
        install -m 755 "$TMP/doctl" /usr/local/bin/doctl
        rm -rf "$TMP"
        echo "  installed doctl ${TAG}"
    ' || true

step "install awscli v2 (Amazon)" \
    sh -c '
        set -e
        ARCH=$(uname -m)
        case "$ARCH" in aarch64|arm64) K=aarch64 ;; x86_64) K=x86_64 ;; *) echo "  unsupported arch $ARCH"; exit 0 ;; esac
        URL="https://awscli.amazonaws.com/awscli-exe-linux-${K}.zip"
        echo "  fetching $URL"
        TMP=$(mktemp -d)
        curl -fsSL "$URL" -o "$TMP/awscliv2.zip"
        apt-get install -y -q --no-install-recommends unzip || true
        unzip -q "$TMP/awscliv2.zip" -d "$TMP"
        "$TMP/aws/install" --update
        rm -rf "$TMP"
        echo "  installed awscli $(/usr/local/bin/aws --version 2>&1 | head -1)"
    ' || true

step "install Google Cloud SDK (gcloud)" \
    sh -c '
        set -e
        ARCH=$(uname -m)
        case "$ARCH" in aarch64|arm64) K=arm ;; x86_64) K=x86_64 ;; *) echo "  unsupported arch $ARCH"; exit 0 ;; esac
        URL="https://dl.google.com/dl/cloudsdk/channels/rapid/google-cloud-cli-linux-${K}.tar.gz"
        echo "  fetching $URL"
        TMP=$(mktemp -d)
        curl -fsSL "$URL" -o "$TMP/gcloud.tar.gz"
        tar -xzf "$TMP/gcloud.tar.gz" -C /opt
        /opt/google-cloud-sdk/install.sh --quiet --usage-reporting=false \
            --path-update=false --command-completion=false || true
        ln -sf /opt/google-cloud-sdk/bin/gcloud  /usr/local/bin/gcloud
        ln -sf /opt/google-cloud-sdk/bin/gsutil  /usr/local/bin/gsutil
        ln -sf /opt/google-cloud-sdk/bin/bq      /usr/local/bin/bq
        rm -rf "$TMP"
        echo "  installed gcloud"
    ' || true

step "install azure-cli (Microsoft)" \
    sh -c '
        set -e
        install -d /etc/apt/keyrings
        curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
            | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ noble main" \
            > /etc/apt/sources.list.d/azure-cli.list
        apt-get update -y -qq
        apt-get install -y -q --no-install-recommends azure-cli
        echo "  installed azure-cli $(/usr/bin/az version 2>/dev/null | head -3 | tail -1)"
    ' || true

# ---------------------------------------------------------------------------
# Default user account.
# ---------------------------------------------------------------------------

if ! id ubuntu >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo,docker ubuntu
fi
chown ubuntu:ubuntu /home/ubuntu

echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-ubuntu
chmod 440 /etc/sudoers.d/90-ubuntu

cat > /usr/local/bin/bromure-open <<'EOO'
#!/bin/sh
URL="$1"
[ -z "$URL" ] && exit 1
OUTBOX=/mnt/bromure-outbox
if [ ! -d "$OUTBOX" ]; then
    echo "bromure-open: outbox share not mounted; cannot relay $URL" >&2
    exit 2
fi
F="$OUTBOX/url-$(date +%s)-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n').txt"
printf '%s\n' "$URL" > "$F"
EOO
chmod +x /usr/local/bin/bromure-open

# ---------------------------------------------------------------------------
# Auto-login + X startup.
# ---------------------------------------------------------------------------

log "configuring auto-login + X startup (system-wide)"

install -d /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-virtio.conf <<'EOX'
Section "Device"
  Identifier "virtio"
  Driver "modesetting"
EndSection
Section "ServerFlags"
  Option "DRI2" "true"
EndSection
EOX

install -d /etc/X11
cat > /etc/X11/Xwrapper.config <<'EOW'
allowed_users=anybody
needs_root_rights=yes
EOW

usermod -a -G video,input,tty ubuntu

install -d /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'EOG'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ubuntu --noclear %I $TERM
EOG

install -d /etc/skel
cat > /etc/skel/.bash_profile <<'EOB'
if [ -z "${DISPLAY-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx
fi
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
EOB

# /etc/skel is consumed by useradd. We add ubuntu(8) BEFORE we
# populate skel, so the new files don't auto-land in /home/ubuntu.
# On macOS that doesn't matter — the host overlays /home/ubuntu via
# virtiofs at runtime. On Windows we have no overlay, so an unwritten
# /home/ubuntu/.bash_profile means login falls back to .profile and
# the `exec startx` chain never fires. Copy explicitly here so the
# baked image has a usable login profile out of the box.
install -m 644 -o ubuntu -g ubuntu /etc/skel/.bash_profile /home/ubuntu/.bash_profile

# Default .bashrc that sources the metadata ISO's api_key.env if the
# bromure-meta share mounted (set up by bromure-meta-mount.service on
# Windows; by virtiofs on macOS). The macOS host overlays /home/ubuntu
# from the profile share, so this file gets shadowed there — only the
# Windows path actually relies on it today.
cat > /home/ubuntu/.bashrc <<'EOB'
# Bromure AC default .bashrc — overridden by the host-shared
# /home/ubuntu/.bashrc when the host attaches one (macOS virtiofs).
case $- in *i*) ;; *) return ;; esac     # interactive shells only
[ -f /etc/bashrc ] && . /etc/bashrc
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -f /mnt/bromure-meta/api_key.env ] && . /mnt/bromure-meta/api_key.env
[ -f /mnt/bromure-meta/.bashrc ] && . /mnt/bromure-meta/.bashrc
PS1='\u@\h:\w\$ '
EOB
chown ubuntu:ubuntu /home/ubuntu/.bashrc

install -d /etc/X11/xinit
cat > /etc/X11/xinit/xinitrc <<'EOX'
#!/bin/sh
exec > /tmp/xinitrc.log 2>&1
set -x

xsetroot -solid '#0d1117'
xset s off -dpms

export LIBGL_ALWAYS_SOFTWARE=1

openbox &
sleep 0.3

for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -S /run/spice-vdagentd/spice-vdagent-sock ] && break
    sleep 0.2
done
spice-vdagent &
sleep 0.2

# NO auto-kitty here. Tabs are kitty PROCESSES driven by the host:
# the host's SessionWindow.AddTab appends a UUID-tagged tab to its
# model and dispatches `spawn-kitty <UUID>` to the in-VM command
# channel (bromure-cmd-server on AF_VSOCK port 9226). Each kitty
# launches with `--class bromure-<UUID>` so xdotool can target it
# for raise / close. Same shape as the macOS TabbedSessionWindow.
#
# Block forever (X session keeps running) — host orchestrates the
# user-visible windows. Without this `exec sleep` the X session
# would exit and openbox would die.
exec sleep infinity
EOX
chmod +x /etc/X11/xinit/xinitrc

install -d /etc/xdg/openbox
cat > /etc/xdg/openbox/rc.xml <<'EOO'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <applications>
    <!-- Bromure runs ONE app per VM (kitty on macOS, xterm on
         Windows). Force every client to be undecorated AND fullscreen
         so it always fills the Xvnc / VZ framebuffer, and so it tracks
         framebuffer resize events (RandR / SetDesktopSize). -->
    <application class="*">
      <decor>no</decor>
      <focus>yes</focus>
      <fullscreen>yes</fullscreen>
      <maximized>true</maximized>
    </application>
  </applications>
</openbox_config>
EOO

install -d /etc/xdg/kitty
cat > /etc/xdg/kitty/kitty.conf <<EOK
font_family       JetBrains Mono
font_size         ${KITTY_FONT_SIZE}
background        #0d1117
foreground        #c9d1d9
cursor_blink_interval 0
hide_window_decorations yes
window_padding_width 16
enable_audio_bell no
remember_window_size no

# Run bash as a LOGIN shell so .bash_profile + .bashrc are sourced
# (cd to \$HOME, PATH exports, etc.). Without this, kitty execs a
# plain shell with cwd=/ and an empty environment.
shell bash -l

# Native kitty tabs visible — we surface them through the
# Bromure-host tab strip eventually; for now they sit at the
# top of the kitty window so users can switch with Ctrl+Shift+→.
tab_bar_style                  fade
tab_bar_edge                   top

sync_to_monitor yes
repaint_delay 16
input_delay 10
update_check_interval 0

# Windows Terminal-style clipboard: Ctrl+Shift+C/V. Keeps Ctrl+C's
# SIGINT semantics intact (terminals MUST be able to send ^C).
map ctrl+shift+c    copy_to_clipboard
map ctrl+shift+v    paste_from_clipboard
map ctrl+shift+a    select_all
map ctrl+shift+t    new_tab
map ctrl+shift+w    close_tab
map ctrl+shift+left previous_tab
map ctrl+shift+right next_tab
map ctrl+plus       change_font_size all +2.0
map ctrl+minus      change_font_size all -2.0
map super+0    change_font_size all 0

open_url_with /usr/local/bin/bromure-open
EOK

cat > /etc/systemd/network/10-eth.network <<'EON'
[Match]
Name=en* eth*

[Network]
DHCP=yes
EON
systemctl enable systemd-networkd systemd-resolved >/dev/null 2>&1 || true
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

systemctl enable spice-vdagentd.socket spice-vdagentd.service >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Windows-only: weston-rdp + hvsock-proxy display stack.
#
# HCS-direct session VMs have NO framebuffer device (vmcompute does
# not attach a virtual GPU on the LinuxKernelDirect / UEFI-VHDX
# path — that's a Hyper-V Manager thing). The macOS port renders via
# VZ's framebuffer; for Windows we instead run weston with the
# rdp-backend.so plugin (Wayland desktop → RDP server on TCP
# 127.0.0.1:3389), then bridge that to AF_VSOCK port 3389 via the
# bromure-hvsock-proxy daemon compiled below. The Windows host's
# mstsc dials hvsocket://<vm-guid>:3389 and gets the desktop.
#
# Stock weston's rdp-backend listens on TCP only. The wslg fork has
# hvsocket support compiled in but building it is multi-hundred-MB
# of source + cross-deps; the proxy hop adds a couple of
# microseconds of latency and is straightforward to maintain.
# ---------------------------------------------------------------------------

if [ "$BROMURE_HOST" = "windows" ]; then
    log "BROMURE_HOST=windows — installing Xvnc + hvsock-proxy stack"

    # Windows-only delta vs. the macOS X stack: install Xvnc
    # (TigerVNC) as the display + RFB server, plus gcc/libc to
    # compile the hvsocket→TCP proxy below. Openbox, kitty, xterm,
    # JetBrains Mono and friends are already installed in the
    # common stack above (and the same xinitrc launches them on
    # both hosts — see /etc/X11/xinit/xinitrc and the
    # bromure-xsession.service unit below).
    apt-get install -y -q --no-install-recommends \
        tigervnc-standalone-server tigervnc-common \
        gcc libc6-dev

    if [ ! -f /tmp/hvsock-proxy.c ]; then
        fail "hvsock-proxy.c missing in chroot /tmp — the setup ISO didn't carry it"
    fi
    gcc -O2 -Wall -pthread -o /usr/local/bin/bromure-hvsock-proxy \
        /tmp/hvsock-proxy.c -lpthread
    strip /usr/local/bin/bromure-hvsock-proxy || true
    rm -f /tmp/hvsock-proxy.c

    if [ ! -f /tmp/title-pusher.c ]; then
        fail "title-pusher.c missing in chroot /tmp — the setup ISO didn't carry it"
    fi
    gcc -O2 -Wall -o /usr/local/bin/bromure-title-pusher \
        /tmp/title-pusher.c
    strip /usr/local/bin/bromure-title-pusher || true
    rm -f /tmp/title-pusher.c

    if [ ! -f /tmp/overlay-fetch.c ]; then
        fail "overlay-fetch.c missing in chroot /tmp — the setup ISO didn't carry it"
    fi
    gcc -O2 -Wall -o /usr/local/bin/bromure-overlay-fetch \
        /tmp/overlay-fetch.c
    strip /usr/local/bin/bromure-overlay-fetch || true
    rm -f /tmp/overlay-fetch.c

    if [ ! -f /tmp/cmd-server.c ]; then
        fail "cmd-server.c missing in chroot /tmp — the setup ISO didn't carry it"
    fi
    gcc -O2 -Wall -o /usr/local/bin/bromure-cmd-server \
        /tmp/cmd-server.c
    strip /usr/local/bin/bromure-cmd-server || true
    rm -f /tmp/cmd-server.c

    # ssh-agent bridge: Unix-socket frontend for ssh-add, AF_VSOCK
    # backend to the host's SshAgentHvSocketListener (port 8444).
    # Without this in-VM ssh-add can't reach the agent that lives on
    # the Windows host.
    if [ ! -f /tmp/ssh-agent-bridge.c ]; then
        fail "ssh-agent-bridge.c missing in chroot /tmp — the setup ISO didn't carry it"
    fi
    gcc -O2 -Wall -pthread -o /usr/local/bin/bromure-ssh-agent-bridge \
        /tmp/ssh-agent-bridge.c -lpthread
    strip /usr/local/bin/bromure-ssh-agent-bridge || true
    rm -f /tmp/ssh-agent-bridge.c

    cat > /etc/systemd/system/bromure-ssh-agent-bridge.service <<'AGENT_UNIT'
[Unit]
Description=Bromure ssh-agent bridge (Unix socket → AF_VSOCK)
After=network-pre.target
DefaultDependencies=no

[Service]
ExecStart=/usr/local/bin/bromure-ssh-agent-bridge
Restart=always
RestartSec=2
# Run as root so the bind succeeds in /run; the socket is chmod 0660
# so anyone in the `bromure` group can read it. The daemon itself is
# tiny and has no external attack surface — it's a byte pump.

[Install]
WantedBy=multi-user.target
AGENT_UNIT
    systemctl enable bromure-ssh-agent-bridge.service

    # Expose the socket via SSH_AUTH_SOCK in every shell. Two seams:
    #   /etc/profile.d/  — sourced by login shells (PAM-managed
    #     logins, kitty's bash --login, etc.). Belt and suspenders.
    #   /etc/environment — read by pam_env on EVERY login, including
    #     non-login shells spawned through automation /exec, sudo,
    #     and SSH. This is the one that actually fixes our case.
    cat > /etc/profile.d/bromure-ssh-auth-sock.sh <<'SOCK_PROFILE'
# Bromure: route ssh-add / ssh through the in-guest bridge, which
# forwards over AF_VSOCK to the SSH-agent on the Windows host.
if [ -S /run/bromure-ssh-agent.sock ]; then
    export SSH_AUTH_SOCK=/run/bromure-ssh-agent.sock
fi
SOCK_PROFILE
    chmod 0644 /etc/profile.d/bromure-ssh-auth-sock.sh
    # /etc/environment is consumed by pam_env without shell
    # interpretation — bare assignments only. Anyone with a shell
    # in the VM gets SSH_AUTH_SOCK set even before
    # /etc/profile.d/* runs.
    if ! grep -q "^SSH_AUTH_SOCK=" /etc/environment 2>/dev/null; then
        echo "SSH_AUTH_SOCK=/run/bromure-ssh-agent.sock" >> /etc/environment
    fi

    # AWS credential_process helper. Python's AF_VSOCK support is
    # 3.7+; the bake already installs python3 above. The helper
    # reads /etc/bromure-profile-id (written by the per-session home
    # overlay) and shells the host's AwsCredentialHvSocketListener
    # for the credential_process JSON document the AWS SDK expects.
    if [ ! -f /tmp/bromure-aws-credentials.py ]; then
        fail "bromure-aws-credentials.py missing in chroot /tmp"
    fi
    install -m 0755 /tmp/bromure-aws-credentials.py /usr/local/bin/bromure-aws-credentials
    rm -f /tmp/bromure-aws-credentials.py

    # Default ~/.aws/config that points the SDK at our helper.
    # SessionHomeBuilder lays per-profile contents over /home/ubuntu
    # so this default applies whenever the profile doesn't supply
    # its own ~/.aws/config.
    mkdir -p /home/ubuntu/.aws
    cat > /home/ubuntu/.aws/config <<'AWS_CFG'
# Managed by Bromure Agentic Coding. Routes all SDK credential
# lookups through the host's AWS credential server — the real
# secret never reaches this VM.
[default]
credential_process = /usr/local/bin/bromure-aws-credentials
AWS_CFG
    chown -R ubuntu:ubuntu /home/ubuntu/.aws

    # Bromure now uses our own VNC client → no weston needed. Xvnc
    # is both an X server and an RFB server in one binary; xterm is
    # its only client. Display geometry matches a 16:10 dev laptop
    # default; the host can resize via VNC extension messages.

    # systemd unit: in-guest hvsocket→TCP proxy. Port 5900 on both
    # sides — host's HvSocketTcpBridge connects via AF_HYPERV service
    # GUID derived from 5900 (RFB / VNC default), the proxy forwards
    # to TigerVNC's Xvnc listening on TCP 127.0.0.1:5900.
    cat > /etc/systemd/system/bromure-hvsock-proxy.service <<'PROXY_UNIT'
[Unit]
Description=Bromure hvsocket → TCP RFB/VNC proxy
After=network.target
Before=bromure-xvnc.service

[Service]
Type=simple
ExecStartPre=/sbin/modprobe -q hv_sock
ExecStart=/usr/local/bin/bromure-hvsock-proxy 5900 127.0.0.1 5900
Restart=on-failure
RestartSec=1
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
PROXY_UNIT

    # systemd unit: TigerVNC's Xvnc. One binary, two protocols at
    # once: an X server (talks to xterm/clients) AND an RFB server
    # (talks to our WPF VNC client). `-SecurityTypes None` skips
    # auth — the AF_HYPERV channel is already in-hypervisor secure.
    cat > /etc/systemd/system/bromure-xvnc.service <<'XVNC_UNIT'
[Unit]
Description=Bromure Xvnc — X server + RFB on TCP 5900
After=bromure-hvsock-proxy.service
Wants=bromure-hvsock-proxy.service

[Service]
Type=simple
User=ubuntu
Group=ubuntu
RuntimeDirectory=user/1000
RuntimeDirectoryMode=0700
Environment=XDG_RUNTIME_DIR=/run/user/1000
ExecStart=/usr/bin/Xvnc :1 -SecurityTypes None -localhost no \
    -geometry 2560x1600 -depth 24 -rfbport 5900 -AlwaysShared=1 \
    -AcceptSetDesktopSize=1 -SendCutText=1 -AcceptCutText=1 \
    -desktop bromure
Restart=on-failure
RestartSec=2
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
XVNC_UNIT

    # 9p mount units for the per-session Plan9 shares the host stages
    # at session-start (HcsSession.cs ports them to bromure-overlay,
    # bromure-certs, bromure-outbox). The shares carry the kitty.conf
    # / bashrc / token files (overlay), the MITM CA cert (certs), and
    # a guest-writable drop-zone the host watches (outbox).
    install -d /mnt/bromure-overlay /mnt/bromure-outbox
    install -d /usr/local/share/ca-certificates/bromure
    chown ubuntu:ubuntu /mnt/bromure-outbox

    cat > /etc/systemd/system/bromure-overlay-mount.service <<'OVL_UNIT'
[Unit]
Description=Mount Bromure home-overlay 9p share
DefaultDependencies=no
After=systemd-modules-load.service
Before=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/sbin/modprobe -q 9p
ExecStartPre=-/sbin/modprobe -q 9pnet_virtio
ExecStartPre=-/sbin/modprobe -q hv_sock
ExecStart=/bin/mount -t 9p -o trans=hyperv,port=50001,version=9p2000.L,access=client bromure-overlay /mnt/bromure-overlay
ExecStop=/bin/umount /mnt/bromure-overlay

[Install]
WantedBy=multi-user.target
OVL_UNIT

    cat > /etc/systemd/system/bromure-certs-mount.service <<'CERTS_UNIT'
[Unit]
Description=Mount Bromure CA certs 9p share
DefaultDependencies=no
After=systemd-modules-load.service
Before=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/sbin/modprobe -q 9p
ExecStartPre=-/sbin/modprobe -q 9pnet_virtio
ExecStartPre=-/sbin/modprobe -q hv_sock
ExecStart=/bin/mount -t 9p -o trans=hyperv,port=50002,version=9p2000.L,access=client bromure-certs /usr/local/share/ca-certificates/bromure
ExecStop=/bin/umount /usr/local/share/ca-certificates/bromure

[Install]
WantedBy=multi-user.target
CERTS_UNIT

    cat > /etc/systemd/system/bromure-outbox-mount.service <<'OB_UNIT'
[Unit]
Description=Mount Bromure outbox 9p share (guest→host events)
DefaultDependencies=no
After=systemd-modules-load.service
Before=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/sbin/modprobe -q 9p
ExecStartPre=-/sbin/modprobe -q 9pnet_virtio
ExecStartPre=-/sbin/modprobe -q hv_sock
ExecStart=/bin/mount -t 9p -o trans=hyperv,port=50003,version=9p2000.L,access=client,uname=ubuntu bromure-outbox /mnt/bromure-outbox
ExecStop=/bin/umount /mnt/bromure-outbox

[Install]
WantedBy=multi-user.target
OB_UNIT

    # Apply the home overlay into /home/ubuntu after the 9p mount lands.
    # cp -a preserves the host's mtime so re-running is idempotent (cp
    # copies even if dest exists, fine for our regenerate-each-session
    # model). update-ca-certificates picks up the CA the certs mount
    # dropped.
    cat > /usr/local/sbin/bromure-overlay-apply <<'APPLY_SH'
#!/bin/sh
set -e
SRC=/mnt/bromure-overlay
DST=/home/ubuntu
# Sentinel: prove bidirectional 9p write works. The host's
# FileSystemWatcher in SessionViewModel will fire as soon as
# this file lands.
printf 'overlay-apply started at %s\n' "$(date)" > "$SRC/.bromure-applied" 2>&1 || true
if [ -d "$SRC" ] && [ "$(ls -A "$SRC" 2>/dev/null)" ]; then
    cp -a "$SRC"/. "$DST/" 2>/dev/null || true
    chown -R ubuntu:ubuntu "$DST"
    if [ -f "$DST/.bromure-env" ]; then
        install -m 0644 "$DST/.bromure-env" /etc/profile.d/bromure-env.sh
    fi
fi
# Refresh CA trust store if the certs share dropped anything.
if [ -d /usr/local/share/ca-certificates/bromure ]; then
    update-ca-certificates >/dev/null 2>&1 || true
fi
# Make the overlay share writable for the ubuntu user so the
# bromure-title-poll service (running as ubuntu) can drop the
# window-title file there.
chown ubuntu:ubuntu "$SRC" 2>/dev/null || true
printf 'overlay-apply done at %s\n' "$(date)" >> "$SRC/.bromure-applied" 2>&1 || true
exit 0
APPLY_SH
    chmod 0755 /usr/local/sbin/bromure-overlay-apply

    cat > /etc/systemd/system/bromure-overlay-apply.service <<'APPLY_UNIT'
[Unit]
Description=Apply Bromure home overlay into /home/ubuntu
After=bromure-overlay-mount.service bromure-certs-mount.service
Wants=bromure-overlay-mount.service bromure-certs-mount.service
Before=bromure-xsession.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/bromure-overlay-apply

[Install]
WantedBy=multi-user.target
APPLY_UNIT

    # Title-poll runs bromure-title-pusher (compiled above): walks
    # /proc every 1.5 s, resolves the foreground process (via tpgid)
    # inside every `kitty --class bromure-<UUID>` it finds, and
    # pushes one `tab|<UUID>|<TITLE>\n` line per kitty to the host
    # over AF_VSOCK (port 9224 → ServiceIdFromPort on the host's
    # AF_HYPERV listener). The host dispatches each line to the
    # matching tab pill, so each tab's label reflects its OWN
    # foreground process — matching macOS tab-agent.sh's title_loop.
    # We use vsock instead of TCP over the Default Switch NIC because
    # Windows Firewall on that interface drops outbound guest→host
    # packets even with explicit allow rules; AF_HYPERV bypasses the
    # IP firewall entirely.
    # Overlay-fetch: oneshot at boot that pulls the per-session home
    # overlay (kitty.conf with profile colour, .bashrc, MCP config,
    # git tokens, etc.) from the host over AF_VSOCK port 9225 and
    # untars it into /home/ubuntu. This replaces the Plan9-share
    # overlay path (which doesn't work because stock Ubuntu kernels
    # lack CONFIG_NET_9P_HV_SOCK).
    cat > /etc/systemd/system/bromure-overlay-fetch.service <<'OFETCH_UNIT'
[Unit]
Description=Bromure home overlay fetch (AF_VSOCK 9225 → /home/ubuntu)
DefaultDependencies=no
After=systemd-modules-load.service local-fs.target
Before=multi-user.target bromure-xsession.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=+-/sbin/modprobe -q vsock
ExecStartPre=+-/sbin/modprobe -q vmw_vsock_virtio_transport
ExecStartPre=+-/sbin/modprobe -q hv_sock
ExecStart=/usr/local/bin/bromure-overlay-fetch 9225 /home/ubuntu
ExecStartPost=/bin/chown -R ubuntu:ubuntu /home/ubuntu
# Source any .bromure-env the host packed into the tar (replaces
# the WSLENV-style env injection from the WSL port).
ExecStartPost=/bin/sh -c '[ -f /home/ubuntu/.bromure-env ] && install -m 0644 /home/ubuntu/.bromure-env /etc/profile.d/bromure-env.sh || true'
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
OFETCH_UNIT

    # Guest command server: listens on AF_VSOCK port 9226 and execs
    # commands the host sends. Used by Bromure's + button (host
    # sends "DISPLAY=:1 kitty --title bromure-tab-N &") and by
    # the tab-raise / tab-close actions (host sends xdotool …).
    cat > /etc/systemd/system/bromure-cmd-server.service <<'CMD_UNIT'
[Unit]
Description=Bromure guest command server (AF_VSOCK 9226)
# Independent of xsession — the host needs to dial cmd-server
# right after boot signal to spawn the first kitty, and at that
# point xsession may still be waiting on overlay-fetch.
DefaultDependencies=no
After=systemd-modules-load.service local-fs.target
Before=multi-user.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
Environment=DISPLAY=:1
Environment=HOME=/home/ubuntu
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStartPre=+-/sbin/modprobe -q vsock
ExecStartPre=+-/sbin/modprobe -q hv_sock
ExecStart=/usr/local/bin/bromure-cmd-server 9226
Restart=on-failure
RestartSec=2
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
CMD_UNIT

    cat > /etc/systemd/system/bromure-title-poll.service <<'POLL_UNIT'
[Unit]
Description=Bromure terminal-title pusher (xdotool → AF_VSOCK 9224)
After=bromure-xsession.service

[Service]
Type=simple
User=ubuntu
Group=ubuntu
Environment=DISPLAY=:1
# AF_VSOCK requires the hv_sock module — load it before the
# pusher tries socket(AF_VSOCK, ...). Done as a + ExecStartPre
# so the failure (if module name differs) doesn't kill the unit;
# the actual socket() call will report the real error in journal.
ExecStartPre=+-/sbin/modprobe -q vsock
ExecStartPre=+-/sbin/modprobe -q hv_sock
ExecStart=/usr/local/bin/bromure-title-pusher 9224
Restart=on-failure
RestartSec=2
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
POLL_UNIT

    systemctl enable bromure-overlay-mount.service bromure-certs-mount.service \
        bromure-outbox-mount.service bromure-overlay-apply.service \
        bromure-overlay-fetch.service bromure-title-poll.service \
        bromure-cmd-server.service >/dev/null 2>&1 || true

    # systemd unit: X session = openbox + spice-vdagent + kitty
    # fullscreen. The session content lives in /etc/X11/xinit/xinitrc
    # which is shared with macOS (the macOS path runs it via getty
    # autologin → startx). On Windows there's no getty login (no real
    # console), so we just exec the same xinitrc with DISPLAY=:1 set
    # to point at our Xvnc — same WM, same client, same retry loop.
    cat > /etc/systemd/system/bromure-xsession.service <<'XSESSION_UNIT'
[Unit]
Description=Bromure X session — runs /etc/X11/xinit/xinitrc on Xvnc :1
After=bromure-xvnc.service bromure-overlay-apply.service
Requires=bromure-xvnc.service
Wants=bromure-overlay-apply.service

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/home/ubuntu
# Mirror the env a real login shell would set. Without these
# kitty inherits systemd's pristine env (no HOME, no SHELL, no
# LOGNAME) and starts in /. PAMName=login also opens a PAM
# session, which registers utmp so `w` / `who` work.
Environment=DISPLAY=:1
Environment=HOME=/home/ubuntu
Environment=USER=ubuntu
Environment=LOGNAME=ubuntu
Environment=SHELL=/bin/bash
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=LIBGL_ALWAYS_SOFTWARE=1
PAMName=login
RuntimeDirectory=user/1000
RuntimeDirectoryMode=0700
ExecStartPre=/bin/sh -c 'for i in $(seq 1 60); do [ -S /tmp/.X11-unix/X1 ] && exit 0; sleep 0.5; done; exit 1'
ExecStart=/bin/sh /etc/X11/xinit/xinitrc
Restart=on-failure
RestartSec=2
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
XSESSION_UNIT

    systemctl enable bromure-hvsock-proxy.service bromure-xvnc.service \
        bromure-xsession.service >/dev/null 2>&1 || true

    # On Windows we DON'T want the X11 / xinitrc / kitty-on-X path to
    # fight weston for the display. Disable the existing
    # spice-vdagent + getty autologin services that the macOS code
    # path enabled above (they're harmless if left running on
    # Windows but waste a getty + ~30 MB).
    systemctl disable getty@tty1.service >/dev/null 2>&1 || true

    log "BROMURE_HOST=windows — Xvnc + xterm stack installed"
fi

log "cleaning up apt caches"
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /tmp/nodesource.sh /tmp/bromure-build.env

log "chroot phase complete"
CHROOT_EOF

# ---------------------------------------------------------------------------
# macOS fonts copy — only meaningful when host is macOS sharing
# /System/Library/Fonts. On Windows the share isn't attached so this
# block silently no-ops.
# ---------------------------------------------------------------------------

log "copying macOS fonts into base image (no-op when share absent)"
mkdir -p /tmp/macfonts-sys /tmp/macfonts-usr
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
rmdir /tmp/macfonts-sys /tmp/macfonts-usr 2>/dev/null || true

chroot /mnt /bin/bash -c 'fc-cache -f >/dev/null 2>&1 || true'

log "unmounting target"
umount /mnt/dev/pts || true
umount /mnt/dev     || true
umount /mnt/proc    || true
umount /mnt/sys     || true
umount /mnt/boot/efi
umount /mnt
sync

log "all done"
echo "SANDBOX_SETUP_DONE"
