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

TARGET_DEV=/dev/vda
TARGET_EFI=${TARGET_DEV}1
TARGET_ROOT=${TARGET_DEV}2

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

log "preparing alpine bootstrap toolchain (host arch: $(uname -m), guest: $DEB_ARCH)"
. /etc/os-release 2>/dev/null || true
ALPINE_VER="${VERSION_ID:-3.22}"
ALPINE_VER_SHORT=$(echo "$ALPINE_VER" | cut -d. -f1,2)
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
    retry apt-get update -y -qq
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
GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=0 vt.global_cursor_default=0 systemd.show_status=false rd.systemd.show_status=false"
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
    retry apt-get update -y -qq
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

RETRIES=0
while [ $RETRIES -lt 5 ]; do
    kitty --start-as=fullscreen
    EXIT=$?
    echo "kitty exited with $EXIT (attempt $((RETRIES+1)))"
    if [ $EXIT -eq 0 ]; then
        exit 0
    fi
    RETRIES=$((RETRIES+1))
    sleep 1
done

echo "kitty failed to stay up after 5 attempts — falling back to xterm"
exec xterm -fullscreen -fa 'JetBrains Mono' -fs 14 -bg '#0d1117' -fg '#c9d1d9'
EOX
chmod +x /etc/X11/xinit/xinitrc

install -d /etc/xdg/openbox
cat > /etc/xdg/openbox/rc.xml <<'EOO'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <applications>
    <application class="*">
      <decor>no</decor>
      <focus>yes</focus>
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

sync_to_monitor yes
repaint_delay 16
input_delay 10
update_check_interval 0

map super+c    copy_to_clipboard
map super+v    paste_from_clipboard
map super+a    select_all
map super+t    new_tab
map super+w    close_tab
map super+shift+left previous_tab
map super+shift+right next_tab
map super+plus change_font_size all +2.0
map super+minus change_font_size all -2.0
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
