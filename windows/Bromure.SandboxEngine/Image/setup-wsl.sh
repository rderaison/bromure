#!/bin/bash
# Bromure AC base-image bake — WSL2 edition.
#
# Runs inside a transient bake distro that was just imported from a
# source rootfs (Ubuntu Noble or similar). The host drives this from
# RootfsBaker.BakeAsync and watches stdout for SANDBOX_SETUP_DONE
# (success) or SANDBOX_SETUP_FAILED (any failure).
#
# Pipeline:
#   1. Configure /etc/wsl.conf (systemd, default user, interop off)
#   2. apt-get install GUI + agent CLIs
#   3. Create the bromure user + sudoers rule
#   4. Clean apt cache
#
# Things deliberately NOT done (vs the QEMU setup.sh):
#   * No kernel/grub install — WSL provides its own kernel
#   * No fstab — WSL handles 9p mounts automatically
#   * No X server / xinitrc — WSLg provides DISPLAY=:0 + Wayland
#   * No serial-console driver — wsl.exe is the host control plane
#   * No debootstrap — the bake's source IS already a rootfs

set -e
set -o pipefail

log() { printf '[bromure-bake] %s\n' "$*"; }
fail() { printf 'SANDBOX_SETUP_FAILED: %s\n' "$*"; exit 1; }

retry() {
    for i in 1 2 3; do
        "$@" && return 0
        log "retry $i/3 failed: $*"
        sleep 2
    done
    fail "command failed after 3 attempts: $*"
}

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# ---------------------------------------------------------------------
# /etc/wsl.conf — WSL behaviour for this distro.
# ---------------------------------------------------------------------
log "writing /etc/wsl.conf"
cat > /etc/wsl.conf <<'EOC'
[boot]
systemd=true

[user]
default=bromure

[interop]
# Block Windows binaries from being callable inside the distro;
# our threat model is "untrusted agent code". Bromure host drives
# everything via wsl.exe — the distro never needs to call back.
enabled=false
appendWindowsPath=false

[automount]
# /mnt/c is mounted by default; we want it (the user's project
# folders live there). Use metadata=on so chmod inside the distro
# does the right thing on NTFS.
options=metadata,uid=1000,gid=1000,umask=022
EOC

# ---------------------------------------------------------------------
# Package install. Three groups:
#   1. GUI: kitty + xterm fallback + fonts
#   2. Agent CLIs: claude, codex (npm), gh, glab, kubectl, doctl,
#      awscli, gcloud, azure-cli (subset for now; rest as needed)
#   3. Build/dev: git, build-essential, jq, vim, curl, openssh-client
# ---------------------------------------------------------------------
log "apt-get update"
retry apt-get update -y -qq

log "apt-get install GUI + dev base"
retry apt-get install -y -q --no-install-recommends \
    kitty xterm \
    fonts-jetbrains-mono fonts-noto-color-emoji fonts-firacode \
    ca-certificates curl wget jq \
    vim nano git \
    build-essential pkg-config \
    openssh-client \
    sudo

# Node.js 20 (needed for claude-code + codex npm globals).
log "apt-get install Node.js 20"
retry curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
retry apt-get install -y -q --no-install-recommends nodejs

log "npm install -g claude-code codex"
retry npm install -g --no-audit --no-fund @anthropic-ai/claude-code @openai/codex || \
    log "  agent CLI install had warnings (non-fatal — host can install per-profile later)"

# gh CLI from the official repo.
log "apt-get install gh"
retry curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /etc/apt/keyrings/githubcli-archive-keyring.gpg 2>/dev/null \
    || mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod 644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
retry apt-get update -y -qq
retry apt-get install -y -q --no-install-recommends gh

# ---------------------------------------------------------------------
# bromure user. The imported rootfs comes with whatever user was set
# at WSL distro creation (typically "ubuntu" with uid 1000). We
# overlay/rename to "bromure" for clarity in logs and to make the
# wsl.conf default user reference unambiguous.
# ---------------------------------------------------------------------
log "configure bromure user"
# bromure must take uid 1000 — that's what WSLg's /mnt/wslg/runtime-dir
# is provisioned for (the canonical "first user" on every WSL distro).
# Running kitty as a different uid produces "Wayland: failed to
# connect to display" because XDG_RUNTIME_DIR symlinks resolve to the
# uid-1000-owned tree. If a pre-existing user holds uid 1000 (the
# source rootfs may have come with one — Microsoft Store Ubuntu does),
# evict them.
existing_1000=$(getent passwd 1000 | cut -d: -f1 || true)
if [ -n "$existing_1000" ] && [ "$existing_1000" != "bromure" ]; then
    log "  removing pre-existing user $existing_1000 (uid 1000) to free the slot"
    userdel -r -f "$existing_1000" 2>/dev/null || userdel -f "$existing_1000" 2>/dev/null || true
    rm -rf "/home/$existing_1000" 2>/dev/null || true
fi
if ! id bromure >/dev/null 2>&1; then
    useradd -m -u 1000 -s /bin/bash -G sudo,video,audio bromure
fi
echo "bromure ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/bromure
chmod 0440 /etc/sudoers.d/bromure

# Pre-create the dirs that SessionHomeBuilder will populate at session
# start. install -d is idempotent and sets ownership in one shot.
install -d -m 0755 -o bromure -g bromure /home/bromure/.config
install -d -m 0755 -o bromure -g bromure /home/bromure/.config/kitty

# ---------------------------------------------------------------------
# Bromure CA cert directory. The actual CA cert is dropped in by the
# host at session start (not bake time) so each Bromure installation
# has its own root. update-ca-certificates is run on first session
# launch by the bromure-meta-mount equivalent.
# ---------------------------------------------------------------------
install -d -m 0755 /usr/local/share/ca-certificates/bromure

# ---------------------------------------------------------------------
# Cleanup — keeps the exported tarball small.
# ---------------------------------------------------------------------
log "apt-get autoremove + clean"
apt-get autoremove -y -qq
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Final marker — host watches for this.
echo "SANDBOX_SETUP_DONE"
