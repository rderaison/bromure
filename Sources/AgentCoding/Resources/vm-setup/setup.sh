#!/bin/sh
# Bromure Agentic Coding — base image build script.
#
# Runs inside an Alpine Linux netboot installer driven by the host over
# the serial console. The host watches stdout for the SANDBOX_SETUP_DONE
# marker (success) or SANDBOX_SETUP_FAILED (any failure).
#
# Pipeline:
#   1. Partition vda (GPT, EFI + ext4) and format.
#   2. debootstrap Ubuntu 24.04 (Noble) for ARM64 onto /mnt.
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
UBUNTU_MIRROR="${UBUNTU_MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
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

log "preparing alpine bootstrap toolchain"
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

log "debootstrapping Ubuntu $UBUNTU_RELEASE (this is the slow step, ~3-5 min)"
retry debootstrap \
    --arch=arm64 \
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
# Virtiofs entries use `nofail` so that when the host doesn't attach the
# share (e.g. profile without a project folder) boot still completes.
cat > /mnt/etc/fstab <<'EOF'
LABEL=root     /               ext4     defaults,noatime  0  1
LABEL=EFI      /boot/efi       vfat     umask=0077        0  2
bromure-home   /home/ubuntu            virtiofs  nofail,defaults     0  0
bromure-meta   /mnt/bromure-meta       virtiofs  nofail,ro,defaults  0  0
bromure-outbox /mnt/bromure-outbox     virtiofs  nofail,defaults     0  0
share-1        /mnt/bromure-share-1    virtiofs  nofail,defaults     0  0
share-2        /mnt/bromure-share-2    virtiofs  nofail,defaults     0  0
share-3        /mnt/bromure-share-3    virtiofs  nofail,defaults     0  0
share-4        /mnt/bromure-share-4    virtiofs  nofail,defaults     0  0
share-5        /mnt/bromure-share-5    virtiofs  nofail,defaults     0  0
share-6        /mnt/bromure-share-6    virtiofs  nofail,defaults     0  0
share-7        /mnt/bromure-share-7    virtiofs  nofail,defaults     0  0
share-8        /mnt/bromure-share-8    virtiofs  nofail,defaults     0  0
EOF
# Pre-create mount points. /home/ubuntu is handled by useradd below.
# share-{1..8} are pre-allocated slots — each profile-folder picks one.
mkdir -p /mnt/mnt/bromure-meta /mnt/mnt/bromure-outbox \
         /mnt/mnt/bromure-share-1 /mnt/mnt/bromure-share-2 \
         /mnt/mnt/bromure-share-3 /mnt/mnt/bromure-share-4 \
         /mnt/mnt/bromure-share-5 /mnt/mnt/bromure-share-6 \
         /mnt/mnt/bromure-share-7 /mnt/mnt/bromure-share-8

# Hostname + hosts. Write the full /etc/hosts so loopback resolution works
# even when debootstrap leaves the file empty/missing.
echo "bromure-ac" > /mnt/etc/hostname
cat > /mnt/etc/hosts <<'EOH'
127.0.0.1       localhost
127.0.1.1       bromure-ac
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOH

# Stash the build-time scale so the chroot can read it back without us
# having to interpolate every variable through the heredoc.
mkdir -p /mnt/tmp
echo "DISPLAY_SCALE=$DISPLAY_SCALE" > /mnt/tmp/bromure-build.env

# Resolv: cloud-init isn't running here; copy the installer's resolv.conf.
# Runtime systemd-resolved will replace this on first boot.
cp /etc/resolv.conf /mnt/etc/resolv.conf

# ---------------------------------------------------------------------------
# Bind-mount + enter chroot for the rest of provisioning.
# Phase-2 logic lives in this heredoc. setup.sh stays a single file so the
# host only has to share one script via virtiofs.
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
# Disable apt's pseudo-graphical progress so we don't get stuck looking at
# a redrawn line that doesn't show forward motion.
export DEBIAN_PRIORITY=critical
# Bring in build-time vars (DISPLAY_SCALE etc.) stashed by outer setup.sh.
. /tmp/bromure-build.env
KITTY_FONT_SIZE=$((14 * DISPLAY_SCALE))

log() { printf '[ac-chroot] %s (t+%ss)\n' "$*" "$SECONDS"; }
fail() { printf 'SANDBOX_SETUP_FAILED: %s\n' "$*"; exit 1; }

# Wrap a command with begin/end markers + duration so silent steps can be
# distinguished from genuinely hung ones in the host's serial tail.
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

# Locale.
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

# ---------------------------------------------------------------------------
# Kernel + EFI bootloader.
# ---------------------------------------------------------------------------

step "apt-get update" \
    retry apt-get update -y -qq
# Pull every security + bug-fix update that landed since the base
# noble release. Without this, `apt upgrade` on first launch in the
# user's VM would surface a wall of pending updates immediately —
# we'd rather ship a base image that's already current.
step "apt-get dist-upgrade (catch security + bug fixes)" \
    retry apt-get dist-upgrade -y -q -o Dpkg::Options::="--force-confnew"
step "apt-get install kernel+grub+systemd+base" \
    retry apt-get install -y -q --no-install-recommends \
        linux-image-virtual initramfs-tools \
        grub-efi-arm64 grub-efi-arm64-bin efibootmgr \
        systemd systemd-sysv systemd-resolved udev \
        iproute2 iputils-ping netbase isc-dhcp-client \
        openssh-client git build-essential pkg-config \
        less nano vim screen tmux \
        docker.io \
        fontconfig

# Boot straight into the default kernel — no menu, no timeout. Hides
# the GRUB prompt entirely unless the user holds Shift at boot.
# `console=hvc0` only (no tty1) so the kernel doesn't paint boot logs onto
# the framebuffer the user sees — they go to the host serial instead.
# `loglevel=0` + `vt.global_cursor_default=0` further suppresses any
# residual console output before X starts.
cat > /etc/default/grub <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_RECORDFAIL_TIMEOUT=0
GRUB_DISTRIBUTOR=Ubuntu
GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=0 vt.global_cursor_default=0"
# arm64.nosme: disable ARM Scalable Matrix Extension. Same option the
# browser sets — Apple Silicon doesn't expose SME and some kernel
# configs break early-boot when probing it.
GRUB_CMDLINE_LINUX="console=hvc0 root=LABEL=root rootfstype=ext4 arm64.nosme"
GRUB_TERMINAL=console
EOF

log "installing GRUB to EFI partition (removable mode)"
grub-install --target=arm64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=BOOTAA64 \
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

# Install the X stack + the keyboard-configuration debconf chain that
# gives Xorg a coherent /etc/default/keyboard. Without it, Xorg falls
# back to compiling a default keymap that can fail when xkb-data ships
# newer keysyms (XF86Sos, XF86CameraAccessEnable, …) than libxkbfile
# knows about. With it, everything resolves to the pre-seeded `us`
# layout and we still get setxkbmap so the host-side KeyboardBridge can
# switch layouts at runtime.
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

# Force the keyboard config Xorg picks up at start-up — empty fields
# below let setxkbmap override at runtime without conflicting with
# whatever keyboard-configuration's postinst wrote.
cat > /etc/default/keyboard <<'EOK'
XKBMODEL="pc105"
XKBLAYOUT="us"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOK

# Drop a matching Xorg input config so the server doesn't probe for
# layouts itself (which is what triggered the XF86Sos cascade) — it
# just trusts what we wrote in /etc/default/keyboard.
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

# ---------------------------------------------------------------------------
# socket.dev CLI — used to wrap subsequent npm installs for supply-chain
# scanning per project policy.
# ---------------------------------------------------------------------------

step "npm install -g @socketsecurity/cli" \
    retry npm install -g --silent @socketsecurity/cli

socket_npm() {
    npx --yes @socketsecurity/cli npm "$@"
}

# ---------------------------------------------------------------------------
# Coding agents (Claude Code, Codex)
# ---------------------------------------------------------------------------

step "npm install -g @anthropic-ai/claude-code (via socket)" \
    retry socket_npm install -g --silent @anthropic-ai/claude-code

step "install codex (GitHub release binary, not npm)" \
    sh -c '
        ARCH=$(uname -m)
        # Use the musl target. The gnu (glibc) artifact has been
        # observed to fail at runtime on this image; the static musl
        # build is the path that historically Just Worked here, and
        # it matches what the per-launch ~/.bashrc fallback installer
        # in Profile.swift downloads.
        case "$ARCH" in
            aarch64|arm64) TARGET=aarch64-unknown-linux-musl ;;
            x86_64)        TARGET=x86_64-unknown-linux-musl  ;;
            *) echo "  unsupported arch $ARCH — skipping codex"; exit 0 ;;
        esac
        # Buffer the API response to a temp file so the trailing
        # `grep -m1` doesn'"'"'t close the pipe early and trip curl
        # exit-23 ("failure writing output to destination").
        TMP=$(mktemp -d)
        if ! curl -fsSL https://api.github.com/repos/openai/codex/releases/latest \
                  -o "$TMP/release.json"; then
            echo "  could not fetch codex release metadata; continuing without"
            rm -rf "$TMP"; exit 0
        fi
        TAG=$(grep -m1 "\"tag_name\"" "$TMP/release.json" | cut -d"\"" -f4)
        if [ -z "$TAG" ]; then
            echo "  could not resolve latest codex tag; continuing without"
            rm -rf "$TMP"; exit 0
        fi
        URL="https://github.com/openai/codex/releases/download/${TAG}/codex-${TARGET}.tar.gz"
        echo "  fetching $URL"
        curl -fsSL "$URL" -o "$TMP/codex.tar.gz"
        tar -xzf "$TMP/codex.tar.gz" -C "$TMP"
        BIN=$(find "$TMP" -type f -name "codex-*" ! -name "*.tar.gz" | head -1)
        [ -z "$BIN" ] && BIN=$(find "$TMP" -type f -name "codex" | head -1)
        if [ -z "$BIN" ]; then
            echo "  codex binary not found in tarball; skipping"
            rm -rf "$TMP"; exit 0
        fi
        install -m 755 "$BIN" /usr/local/bin/codex
        rm -rf "$TMP"
        echo "  installed codex $TAG"
    '

# ---------------------------------------------------------------------------
# wezterm — latest GitHub release deb
# ---------------------------------------------------------------------------

# kitty has a documented --start-as=fullscreen flag, which sidestepped a
# pile of grief we hit trying to fullscreen wezterm via WM cooperation.
# xterm stays as a tiny fallback if kitty fails for any reason.
step "apt-get install kitty (+ xterm fallback)" \
    retry apt-get install -y -q --no-install-recommends kitty xterm

step "apt-get install terminal multiplexers (screen + tmux)" \
    retry apt-get install -y -q --no-install-recommends screen tmux

# ---------------------------------------------------------------------------
# GitHub CLI (gh) — official apt repo. Picks up ~/.config/gh/hosts.yml the
# host writes from a profile's HTTPS-token credential.
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
# GitLab CLI (glab) — single-binary release from gitlab.com/gitlab-org/cli.
# No apt repo upstream; we grab the latest .deb. Failure is non-fatal so a
# transient gitlab.com / GitHub-releases hiccup doesn't kill the whole base.
# Picks up ~/.config/glab-cli/config.yml the host writes from a profile's
# HTTPS-token credential.
# ---------------------------------------------------------------------------

step "install glab from latest GitLab release deb (best effort)" \
    sh -c '
        set -e
        ARCH=$(dpkg --print-architecture)
        # Resolve the latest release tag via the public API. Fall back to
        # a known-good tag if the API is rate-limited / unreachable.
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
# kubectl: stable release from dl.k8s.io.
# doctl: GitHub release tarball.
# awscli v2: official aws bundle (works for arm64 + amd64).
# gcloud: Google Cloud SDK tarball.
# Each install is best-effort with `|| true` so a single failure
# doesn't take down the rest.
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

step "install doctl (DigitalOcean CLI, GitHub release)" \
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
        # awscli requires unzip — install it best-effort.
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
        # Non-interactive install: skip components, no PATH munging
        # (we add /opt/google-cloud-sdk/bin via .bashrc PATH below).
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
        # Azure publishes their own apt repo. Best-effort: errors are
        # logged but not fatal.
        curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
            | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ noble main" \
            > /etc/apt/sources.list.d/azure-cli.list
        apt-get update -y -qq
        apt-get install -y -q --no-install-recommends azure-cli
        echo "  installed azure-cli $(/usr/bin/az version 2>/dev/null | head -3 | tail -1)"
    ' || true

# ---------------------------------------------------------------------------
# Default user account (ubuntu) with passwordless sudo.
# Phase B will rotate this through the profile system; for now we hard-code.
# ---------------------------------------------------------------------------

if ! id ubuntu >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo,docker ubuntu
fi
# /home/ubuntu is mounted from the host at runtime — anything we put in
# it during install gets shadowed. We only need the empty directory and
# the right ownership so the mount point exists.
chown ubuntu:ubuntu /home/ubuntu

echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-ubuntu
chmod 440 /etc/sudoers.d/90-ubuntu

# Welcome banner is now printed once per session by .bashrc itself
# (which the host writes to the home share at profile-create time). The
# old /etc/profile.d/bromure-init.sh + /home/ubuntu/.bash_profile path
# is gone — both would be shadowed by the home virtiofs mount anyway.

# bromure-open: tiny script kitty (and anything else) calls to open URLs
# on the macOS host instead of inside the VM. Drops a file into the
# bromure-outbox virtiofs share; the host polls + relays to NSWorkspace.
cat > /usr/local/bin/bromure-open <<'EOO'
#!/bin/sh
# Usage: bromure-open <URL>
# Sends the URL to the macOS host's default browser via the outbox share.
URL="$1"
[ -z "$URL" ] && exit 1
OUTBOX=/mnt/bromure-outbox
if [ ! -d "$OUTBOX" ]; then
    echo "bromure-open: outbox share not mounted; cannot relay $URL" >&2
    exit 2
fi
# Unique filename per call so concurrent opens don't collide.
F="$OUTBOX/url-$(date +%s)-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n').txt"
printf '%s\n' "$URL" > "$F"
EOO
chmod +x /usr/local/bin/bromure-open

# ---------------------------------------------------------------------------
# Auto-login on tty1 → startx → wezterm fullscreen, no WM.
# ---------------------------------------------------------------------------

log "configuring auto-login + X startup (system-wide)"

# Tell xorg to use modesetting on virtio-gpu (DRI/KMS path). Without this,
# X auto-detection can't find a screen on Apple Virtualization framework's
# virtio-gpu device and bails with "no screens found".
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

# Allow non-root to start X (startx from .bash_profile).
install -d /etc/X11
cat > /etc/X11/Xwrapper.config <<'EOW'
allowed_users=anybody
needs_root_rights=yes
EOW

# Make sure ubuntu can talk to /dev/dri/card0 + /dev/fb0.
usermod -a -G video,input,tty ubuntu

install -d /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'EOG'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ubuntu --noclear %I $TERM
EOG

# Defense-in-depth: if the host hasn't pre-populated /home/ubuntu (e.g.
# someone runs the VM without going through ProfileStore), give the
# guest a bare-minimum .bash_profile via /etc/skel. The host's own
# version (written by Profile.prepareHomeDirectory) handles X auto-start
# + .bashrc sourcing more thoroughly.
install -d /etc/skel
cat > /etc/skel/.bash_profile <<'EOB'
if [ -z "${DISPLAY-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx
fi
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
EOB

# System-wide xinitrc — startx falls back to this when ~/.xinitrc is
# missing (which it always is here, since /home/ubuntu mounts empty from
# the host on first boot until prepareHomeDirectory writes dotfiles).
install -d /etc/X11/xinit
cat > /etc/X11/xinit/xinitrc <<'EOX'
#!/bin/sh
exec > /tmp/xinitrc.log 2>&1
set -x

xsetroot -solid '#0d1117'
xset s off -dpms

# Force mesa software rendering — virtio-gpu's GL stack under VZ isn't
# reliable enough for kitty's 3.3 core profile requirement.
export LIBGL_ALWAYS_SOFTWARE=1

openbox &
sleep 0.3
spice-vdagent &
sleep 0.2

# Restart kitty in a loop — closing it (e.g. exiting the agent shell)
# shouldn't drop us to a different terminal stacked beneath. Bail to
# xterm only if kitty repeatedly fails to start at all.
RETRIES=0
while [ $RETRIES -lt 5 ]; do
    kitty --start-as=fullscreen
    EXIT=$?
    echo "kitty exited with $EXIT (attempt $((RETRIES+1)))"
    if [ $EXIT -eq 0 ]; then
        # Clean exit (user really meant to close it). Exit the X session.
        exit 0
    fi
    RETRIES=$((RETRIES+1))
    sleep 1
done

echo "kitty failed to stay up after 5 attempts — falling back to xterm"
exec xterm -fullscreen -fa 'JetBrains Mono' -fs 14 -bg '#0d1117' -fg '#c9d1d9'
EOX
chmod +x /etc/X11/xinit/xinitrc

# System-wide openbox config (lives under /etc/xdg, openbox falls back
# to it when no per-user file exists).
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
# System-wide kitty config (kitty also looks at /etc/xdg/kitty before
# the user file). Heredoc unquoted so ${KITTY_FONT_SIZE} interpolates.
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
sync_to_monitor no

# macOS muscle memory: ⌘C / ⌘V come through as Super + C / V because the
# host's VZVirtualMachineView is set to capturesSystemKeys = true. Also
# keep the default Ctrl+Shift+C/V working for muscle memory the other way.
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

# Send URL clicks to the macOS host's default browser instead of
# trying to open them inside the headless VM.
open_url_with /usr/local/bin/bromure-open
EOK

# DHCP on the single virtio NIC.
cat > /etc/systemd/network/10-eth.network <<'EON'
[Match]
Name=en* eth*

[Network]
DHCP=yes
EON
# systemd-networkd ships as part of `systemd`; systemd-resolved is its own
# package (added above). `systemctl enable` will return non-zero if a unit
# is missing — guard with || true so we don't fail the whole chroot.
systemctl enable systemd-networkd systemd-resolved >/dev/null 2>&1 || true
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Slim the image down a bit.
log "cleaning up apt caches"
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /tmp/nodesource.sh /tmp/bromure-build.env

log "chroot phase complete"
CHROOT_EOF

# ---------------------------------------------------------------------------
# Copy macOS fonts into the installed system BEFORE we unmount /mnt.
# The host shares /System/Library/Fonts (and optionally /Library/Fonts)
# read-only via virtiofs; we mount them, cp -a into /usr/share/fonts/macos/,
# then fc-cache so the in-chroot fontconfig picks them up.
# ---------------------------------------------------------------------------

log "copying macOS fonts into base image"
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

# /proc /sys /dev are still bound from the chroot phase — fc-cache just
# needs them to read /etc/fonts/conf.d/* normally.
chroot /mnt /bin/bash -c 'fc-cache -f >/dev/null 2>&1 || true'

# ---------------------------------------------------------------------------
# Tear down chroot mounts and unmount target.
# ---------------------------------------------------------------------------

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
