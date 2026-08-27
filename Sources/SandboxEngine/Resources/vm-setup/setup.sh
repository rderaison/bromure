#!/bin/sh
# Bromure VM setup script — installs Ubuntu (glibc) with Chromium.
#
# Runs inside the Alpine netboot installer environment driven by the host
# over the serial console (the installer stays Alpine — it's tiny and the
# whole console orchestration depends on it; only the TARGET rootfs is
# Ubuntu). debootstraps Ubuntu onto the whole-disk ext4 /dev/vda, then
# chroots to install the kernel, X, Chromium and the Bromure agents.
#
# Usage: setup.sh KEYBOARD_LAYOUT NATURAL_SCROLLING LOCALE DISPLAY_SCALE UBUNTU_RELEASE [BUILD_MODE]
# No set -e: non-critical sections (ad blocking) may fail gracefully
#
# BUILD_MODE:
#   user (default) — local build on the end-user's machine: bakes their
#                    macOS fonts.
#   foss           — redistributable build for the publish pipeline
#                    (bromure init-foss-image → dl.bromure.io/browser-images/):
#                    free software only — no Apple fonts — and a failed
#                    v4l2loopback dkms build FAILS the build instead of
#                    degrading. (Cloudflare WARP and Google Chrome are
#                    never installed here in either mode; they're
#                    browser-img-catalog.json postinstall steps.)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KB_LAYOUT_SPEC="${1:-us}"
NATURAL_SCROLLING="${2:-true}"
LOCALE="${3:-en_US}"
DISPLAY_SCALE="${4:-2}"
UBUNTU_RELEASE="${5:-noble}"
BUILD_MODE="${6:-user}"
CURSOR_SIZE=$((DISPLAY_SCALE * 24))

UBUNTU_MIRROR="${UBUNTU_MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"

# Parse layout:variant format (e.g. "ch:fr" → layout="ch", variant="fr")
case "$KB_LAYOUT_SPEC" in
    *:*) KB_LAYOUT="${KB_LAYOUT_SPEC%%:*}"; KB_VARIANT="${KB_LAYOUT_SPEC#*:}" ;;
    *)   KB_LAYOUT="$KB_LAYOUT_SPEC"; KB_VARIANT="" ;;
esac

# ---------------------------------------------------------------------------
# Host-side package proxy (same channel as the AC bake). When the host
# runs its HTTP→HTTPS proxy (AlpinePackageProxy) it passes the guest URL
# in ALPINE_REPO_BASE; the kernel cmdline's alpine_repo/modloop already
# point at it. Export it as http(s)_proxy so every other fetch — the
# installer's apk, debootstrap, the chroot's apt, the ad-block/Tranco
# lists — rides the host's TLS stack too (guest-direct TLS is unreliable
# on VPN/MITM hosts and the build server). The proxy host itself must be
# in no_proxy or requests to the proxy would recurse through it forever.
# ---------------------------------------------------------------------------

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
        echo "Using host package proxy at $ALPINE_REPO_BASE"
        ;;
esac

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

retry() {
    for i in 1 2 3; do
        "$@" && return 0
        echo "RETRY $i/3: $*"
        sleep 2
    done
    echo "SANDBOX_SETUP_FAILED: command failed after 3 attempts: $*"
    exit 1
}

install_config() {
    # install_config <source> <dest> [mode]
    cp "$SCRIPT_DIR/$1" "$2"
    [ -n "$3" ] && chmod "$3" "$2"
}

install_template() {
    # install_template <source> <dest> [mode]
    # Performs %%VAR%% substitution
    sed -e "s|%%KEYBOARD_LAYOUT%%|$KB_LAYOUT_SPEC|g" \
        -e "s|%%XKB_LAYOUT%%|$KB_LAYOUT|g" \
        -e "s|%%XKB_VARIANT%%|$KB_VARIANT|g" \
        -e "s|%%NATURAL_SCROLLING%%|$NATURAL_SCROLLING|g" \
        -e "s|%%LOCALE%%|$LOCALE|g" \
        "$SCRIPT_DIR/$1" > "$2"
    [ -n "$3" ] && chmod "$3" "$2"
}

# ---------------------------------------------------------------------------
# Network connectivity check
# ---------------------------------------------------------------------------

echo "Waiting for network..."

# Append well-known public DNS as fallback.  The kernel's ip=dhcp provides
# the vmnet gateway as nameserver, which forwards to the host's DNS.  This
# works most of the time, but fails when the host uses VPN-only, Private
# Relay, or corporate DNS that doesn't respond to queries from the VM subnet.
# Appending public servers lets the resolver fall back if the primary fails.
if ! grep -q '1\.1\.1\.1' /etc/resolv.conf 2>/dev/null; then
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    echo "nameserver 1.0.0.1" >> /etc/resolv.conf
fi

# Probe through the proxy when one is up — that's the exact path every
# later fetch takes. Proxy env cleared for the probe itself (plain HTTP
# straight to the listener; must not recurse through the proxy).
NET_PROBE="http://dl-cdn.alpinelinux.org/alpine/"
[ -n "$PROXIED" ] && NET_PROBE="$ALPINE_REPO_BASE/alpine/"
for i in $(seq 1 30); do
    http_proxy= https_proxy= wget -q -O /dev/null --spider "$NET_PROBE" 2>/dev/null && break
    sleep 1
done
http_proxy= https_proxy= wget -q -O /dev/null --spider "$NET_PROBE" 2>/dev/null || {
    echo "SANDBOX_SETUP_FAILED: no network connectivity — check your internet connection"
    exit 1
}

# ---------------------------------------------------------------------------
# Installer-side toolchain. debootstrap is in Alpine's community repo
# (already enabled in the netboot env). GNU tar + xz + zstd because
# debootstrap's dpkg-deb extractor shells out to tar and BusyBox tar
# fails on some Ubuntu .deb data tarballs; zstd for control.tar.zst.
# GNU wget + CA certs: the ad-block/Tranco fetches below use https URLs
# and busybox wget's proxy/TLS support isn't dependable.
# ---------------------------------------------------------------------------

modprobe ext4
retry apk add e2fsprogs wget ca-certificates debootstrap tar xz zstd
mkfs.ext4 -q -F /dev/vda
mkdir -p /mnt
mount -t ext4 /dev/vda /mnt

# ---------------------------------------------------------------------------
# debootstrap Ubuntu onto the target disk. Whole-disk ext4, no partition
# table — the image direct-kernel-boots via VZLinuxBootLoader.
# --variant=minbase keeps the rootfs small; everything else lands in the
# chroot phase below.
# ---------------------------------------------------------------------------

echo "SANDBOX_STEP_START:Installing Ubuntu base system"
retry debootstrap \
    --arch=arm64 \
    --variant=minbase \
    --include=ca-certificates,curl,gnupg,locales,tzdata \
    --components=main,universe \
    "$UBUNTU_RELEASE" /mnt "$UBUNTU_MIRROR"
echo "SANDBOX_STEP_DONE:Installing Ubuntu base system"

cat > /mnt/etc/apt/sources.list <<EOF
deb $UBUNTU_MIRROR $UBUNTU_RELEASE main universe
deb $UBUNTU_MIRROR ${UBUNTU_RELEASE}-updates main universe
deb $UBUNTU_MIRROR ${UBUNTU_RELEASE}-security main universe
EOF

echo "bromure" > /mnt/etc/hostname
cat > /mnt/etc/hosts <<'EOH'
127.0.0.1       localhost
127.0.1.1       bromure
::1             localhost ip6-localhost ip6-loopback
EOH

# The chroot needs a working resolver during the bake; the canonical
# static fallback is restored in the cleanup section (DHCP overwrites it
# at runtime anyway) so no build-time network detail leaks into the image.
cp /etc/resolv.conf /mnt/etc/resolv.conf

# Stash build-time vars so the chroot can read them back without us
# having to interpolate through a quoted heredoc.
mkdir -p /mnt/tmp
{
    echo "BROMURE_PROXY=$([ -n "$PROXIED" ] && echo "$ALPINE_REPO_BASE")"
    echo "LOCALE=$LOCALE"
    echo "BUILD_MODE=$BUILD_MODE"
} > /mnt/tmp/bromure-build.env

# Bind-mount for chroot. The netboot's /dev is a bare devtmpfs from the
# rdinit shim — materialise /dev/pts first or the bind of it fails.
[ -d /dev/pts ] || mkdir /dev/pts
mountpoint -q /dev/pts 2>/dev/null || mount -t devpts devpts /dev/pts
mount --bind /dev /mnt/dev
mount --bind /dev/pts /mnt/dev/pts
mount -t proc proc /mnt/proc
mount -t sysfs sys /mnt/sys

# ---------------------------------------------------------------------------
# Chroot phase: kernel, systemd, X, Chromium, agents' runtime, users,
# services. Single heredoc so this file stays the one script the host
# shares via virtiofs.
# ---------------------------------------------------------------------------

echo "SANDBOX_STEP_START:Installing packages"
chroot /mnt /bin/bash <<'CHROOT_EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
. /tmp/bromure-build.env

log() { printf '[bromure-chroot] %s (t+%ss)\n' "$*" "$SECONDS"; }
fail() { printf 'SANDBOX_SETUP_FAILED: %s\n' "$*"; exit 1; }

retry() {
    for i in 1 2 3; do
        "$@" && return 0
        log "retry $i/3 failed: $*"
        sleep 3
    done
    fail "command failed after 3 attempts: $*"
}

# Slim the image at the source: tell dpkg to drop documentation, man
# pages, and locale data as packages unpack, so the X/Chromium/tooling
# installs below never write ~100 MB we'd only delete afterward. The
# guest is a single-purpose disposable browser VM — none of it is user-
# facing. Set BEFORE the big apt installs. /usr/share/locale is kept for
# the browser session locales the product ships (re-rendered per install)
# plus en; everything else is excluded.
mkdir -p /etc/dpkg/dpkg.cfg.d
cat > /etc/dpkg/dpkg.cfg.d/01-bromure-slim <<'EOF'
path-exclude /usr/share/doc/*
path-exclude /usr/share/man/*
path-exclude /usr/share/groff/*
path-exclude /usr/share/info/*
path-exclude /usr/share/lintian/*
path-exclude /usr/share/locale/*
path-include /usr/share/locale/locale.alias
path-include /usr/share/doc/*/copyright
EOF

# Route every chroot HTTP(S) request through the host's proxy (see the
# outer proxy section). apt gets an explicit config on top of the env
# vars — defensive, and a visible record of the override (removed in
# cleanup; it points at a bake-time-only listener).
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

# Locales: the browser session locale plus en_US as the baseline.
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
grep -q "^${LOCALE}.UTF-8" /etc/locale.gen || echo "${LOCALE}.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

log "apt-get update"
retry apt-get update -y -qq
log "apt-get dist-upgrade (catch security + bug fixes)"
retry apt-get dist-upgrade -y -q -o Dpkg::Options::="--force-confnew"

# Kernel + init + network base. linux-image-virtual is the minimal
# generic kernel; modules-extra below adds virtio_snd, uinput, the V4L2
# core, and friends that the browser image needs.
log "apt-get install kernel + systemd + network base"
retry apt-get install -y -q --no-install-recommends \
    linux-image-virtual initramfs-tools kmod \
    systemd systemd-sysv udev dbus dbus-x11 \
    ifupdown isc-dhcp-client iproute2 iputils-ping netbase \
    ca-certificates wget curl gnupg

KVER=$(ls /lib/modules)
log "kernel $KVER — installing linux-modules-extra"
retry apt-get install -y -q --no-install-recommends "linux-modules-extra-$KVER"

# Pre-seed keyboard-configuration so the X install below never prompts
# and Xorg gets a coherent /etc/default/keyboard baseline (the real
# layout comes from the templated xorg.conf.d file the outer script
# installs).
echo "keyboard-configuration keyboard-configuration/layoutcode select us"       | debconf-set-selections
echo "keyboard-configuration keyboard-configuration/modelcode select pc105"     | debconf-set-selections
echo "keyboard-configuration keyboard-configuration/variantcode select"         | debconf-set-selections
echo "keyboard-configuration keyboard-configuration/optionscode select"         | debconf-set-selections
echo "keyboard-configuration keyboard-configuration/xkb-keymap select us"       | debconf-set-selections
echo "console-setup console-setup/codeset47 select Guess optimal character set" | debconf-set-selections

log "apt-get install X + WM + fonts + audio"
retry apt-get install -y -q --no-install-recommends \
    xserver-xorg-core xserver-xorg-legacy \
    xserver-xorg-input-libinput xserver-xorg-video-modesetting \
    xinit xauth x11-xserver-utils x11-xkb-utils \
    keyboard-configuration console-setup xkb-data \
    openbox xdotool \
    spice-vdagent \
    libgl1-mesa-dri \
    fonts-dejavu-core fonts-freefont-ttf fonts-liberation fonts-noto-color-emoji \
    adwaita-icon-theme \
    pipewire pipewire-pulse wireplumber pulseaudio-utils alsa-utils \
    fontconfig

log "apt-get install proxy/DNS/VPN tools"
# strongSwan plugin packs: Debian splits what Alpine ships in one
# package, and --no-install-recommends drops them — leaving charon
# without openssl (the ECDH ecp256/ecp384 groups and ECDSA certs in our
# proposals), gcm (every aes256gcm16 ESP proposal), or any eap-*
# (eap-mschapv2 is the default ikev2AuthMethod). Without these the
# tunnel negotiates nothing: charon runs, swanctl shows zero SAs.
#   libstrongswan-standard-plugins — openssl, gcm
#   libcharon-extra-plugins       — eap-identity/md5/tls/gtc/...
#   libcharon-extauth-plugins     — eap-mschapv2, xauth-generic
# libpcap + libtss2: the runtime libraries Cloudflare WARP's warp-svc /
# warp-cli link. WARP itself is non-free and stays a catalog postinstall
# step, but that step EXTRACTS the deb rather than apt-installing it —
# the deb's Depends drag in its tray GUI's stack (libwebkit2gtk +
# libayatana-appindicator, a huge closure Bromure never runs). With
# these baked, the postinstall downloads exactly one deb and nothing
# else. (esys pulls libtss2-mu itself; dbus/nss/iproute2/nftables/
# certutil/ca-certificates are already in this list or chromium's.)
retry apt-get install -y -q --no-install-recommends \
    squid dnsmasq proxychains4 cryptsetup inotify-tools jq python3 \
    v4l-utils libnss3-tools bash wireguard-tools \
    strongswan strongswan-swanctl charon-systemd \
    libstrongswan-standard-plugins libcharon-extra-plugins \
    libcharon-extauth-plugins openvpn openssl \
    libpcap0.8t64 libtss2-esys-3.0.2-0t64 libtss2-tctildr0t64 \
    doas nftables unzip

# ---------------------------------------------------------------------------
# Chromium — native deb from the xtradeb PPA (Ubuntu's own
# chromium-browser package is a transitional stub that installs the
# snap, unusable here: no snapd in this image). Static keyring, PPA
# pinned low so only Chromium ever comes from it.
# ---------------------------------------------------------------------------

log "adding xtradeb PPA (native Chromium debs)"
install -d -m 0755 /etc/apt/keyrings
retry sh -c 'curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x5301FA4FD93244FBC6F6149982BB6851C64F6880" \
    | gpg --dearmor > /etc/apt/keyrings/xtradeb.gpg'
echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/xtradeb.gpg] https://ppa.launchpadcontent.net/xtradeb/apps/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) main" \
    > /etc/apt/sources.list.d/xtradeb.list
cat > /etc/apt/preferences.d/xtradeb <<'EOP'
Package: *
Pin: release o=LP-PPA-xtradeb-apps
Pin-Priority: 100

Package: chromium chromium-*
Pin: release o=LP-PPA-xtradeb-apps
Pin-Priority: 500
EOP
retry apt-get update -y -qq
log "apt-get install chromium"
# xdg-utils: not needed by Chromium, but Google Chrome (151+) Depends on
# it and the catalog's Chrome postinstall step resolves against Google's
# repo list ONLY. Baking it here keeps that step on its cheap scoped
# `apt-get update` instead of falling back to a full ports.ubuntu.com
# refresh just to fetch this one package.
retry apt-get install -y -q --no-install-recommends chromium xdg-utils
apt-get install -y -q --no-install-recommends chromium-l10n || true

# Compat shim: every Bromure script and agent launches `chromium-browser`
# (the Alpine-era binary name). Keep that name working regardless of
# which browser package provides the real binary.
cat > /usr/local/bin/chromium-browser <<'EOSH'
#!/bin/sh
exec /usr/bin/chromium "$@"
EOSH
chmod 755 /usr/local/bin/chromium-browser

# The Debian-style /usr/bin/chromium wrapper sources /etc/chromium.d/*
# into every launch. Two fragments fight the host-owned session flags:
# default-flags injects --enable-gpu-rasterization unconditionally (even
# when the profile turned GPU off), and extensions enables remote
# extension loading + sweeps /usr/share/chromium/extensions. Remove
# them; their still-wanted switches (--no-default-browser-check,
# --disable-pings) live on xinitrc's launch line instead. KEEP apikeys
# (without it Chromium shows a missing-API-keys infobar every session)
# and dev-shm (--disable-dev-shm-usage crash guard — /dev/shm in these
# VMs is always under its 3.8 GB threshold).
rm -f /etc/chromium.d/default-flags /etc/chromium.d/extensions

# Google Chrome (installed later by a browser-img-catalog.json
# postinstall step) reads /etc/opt/chrome/{policies,native-messaging-hosts}.
# Point it at the Chromium tree so both browsers see the same Bromure
# policies and extension hosts.
mkdir -p /etc/opt /etc/chromium
ln -sfn /etc/chromium /etc/opt/chrome

# ---------------------------------------------------------------------------
# Users and permissions
# ---------------------------------------------------------------------------

passwd -d root
id chrome >/dev/null 2>&1 || useradd -m -s /bin/sh chrome
for g in video render input audio tty; do
    getent group "$g" >/dev/null || groupadd -r "$g"
done
usermod -a -G video,render,input,audio,tty chrome
# Suppress Ubuntu's motd/legal spam on the autologin consoles.
touch /home/chrome/.hushlogin /root/.hushlogin
chown chrome:chrome /home/chrome/.hushlogin

# ---------------------------------------------------------------------------
# Boot services (systemd replaces Alpine's OpenRC + inittab)
# ---------------------------------------------------------------------------

# Autologin chrome on tty1 (the graphical console; .profile starts X).
install -d /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'EOG'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin chrome --noclear %I $TERM
EOG

# Autologin root on the hvc0 serial console (host-side debug channel).
install -d /etc/systemd/system/serial-getty@hvc0.service.d
cat > /etc/systemd/system/serial-getty@hvc0.service.d/autologin.conf <<'EOG'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 %I $TERM
EOG
systemctl enable serial-getty@hvc0.service >/dev/null 2>&1 || true

# Classic ifupdown networking (reads /etc/network/interfaces, installed
# by the outer script) — same DHCP semantics as the Alpine image, and
# `ifdown eth0` releases the vmnet lease before poweroff.
systemctl enable networking >/dev/null 2>&1 || true

# spice-vdagentd is the system half of the clipboard bridge; the apt
# postinst enable doesn't always fire inside a debootstrap chroot.
systemctl enable spice-vdagentd.socket spice-vdagentd.service >/dev/null 2>&1 || true

# wg-quick aborts (rc=127) on configs with a DNS= line because Ubuntu's
# wireguard-tools has no resolvconf (Alpine's pulled in openresolv),
# tearing the tunnel down right after creating it. wireguard-agent owns
# VPN DNS itself (resolv.conf + dnsmasq upstream swap), so give wg-quick
# — and only wg-quick, via the PATH prefix wireguard-agent.py sets — a
# no-op resolvconf. Deliberately NOT on the system PATH: dhclient and
# charon probe for a resolvconf binary and must keep writing
# /etc/resolv.conf directly.
install -d /usr/local/libexec/bromure-noop-resolvconf
printf '#!/bin/sh\nexit 0\n' > /usr/local/libexec/bromure-noop-resolvconf/resolvconf
chmod 755 /usr/local/libexec/bromure-noop-resolvconf/resolvconf

# Ubuntu builds spice-vdagentd with systemd-logind session tracking: on
# agent connect it resolves the client's logind session and drops the
# connection when there is none. This guest has no logind sessions at all
# (agetty autologin + startx, no libpam-systemd), so the per-session
# spice-vdagent exited immediately and clipboard sync silently died.
# Alpine's build had no session integration, which is why this only broke
# with the Ubuntu move. -X disables the lookup; with a single X session
# the one connecting agent is simply treated as active.
echo 'SPICE_VDAGENTD_EXTRA_ARGS="-X"' > /etc/default/spice-vdagentd

# Daemons the agents start BY HAND per-profile (squid -N, dnsmasq -C,
# openvpn, charon) must not autostart as system services. Mask rather
# than disable: masking is symlink-to-/dev/null and cannot be undone by
# a later postinst/preset pass, and one systemctl call per unit so an
# unknown unit name can't short-circuit the rest.
for svc in squid dnsmasq openvpn strongswan-starter strongswan charon-systemd; do
    systemctl mask "$svc.service" >/dev/null 2>&1 || true
done
systemctl mask apt-daily.timer apt-daily-upgrade.timer motd-news.timer \
    e2scrub_all.timer fstrim.timer man-db.timer >/dev/null 2>&1 || true

# on-boot.sh first, then the Bromure agents (Alpine's inittab `::once`
# entries, one unit each; resilient-launch.sh supplies the restart loop).
cat > /etc/systemd/system/bromure-onboot.service <<'EOS'
[Unit]
Description=Bromure early boot setup
DefaultDependencies=no
After=local-fs.target systemd-tmpfiles-setup.service
Before=basic.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/on-boot.sh
[Install]
WantedBy=basic.target
EOS

cat > /etc/systemd/system/bromure-config-agent.service <<'EOS'
[Unit]
Description=Bromure config agent
After=bromure-onboot.service
Wants=bromure-onboot.service
[Service]
Type=simple
Restart=no
# config-agent applies the claim-time config, spawns the per-profile
# daemons (squid/routing-socks/warp-svc/download-guard via
# resilient-launch), then EXITS by design. Default KillMode
# (control-group) would reap those daemons the moment the main process
# exits — on Alpine's inittab they survived as orphans. process = only
# the main pid is ever signalled; the spawned daemons live on.
KillMode=process
ExecStart=/usr/local/bin/config-agent.py
[Install]
WantedBy=multi-user.target
EOS

bromure_agent_unit() {
    # bromure_agent_unit <name> <user> <script>
    cat > "/etc/systemd/system/bromure-$1.service" <<EOS
[Unit]
Description=Bromure $1
After=bromure-onboot.service
Wants=bromure-onboot.service
[Service]
Type=simple
User=$2
ExecStart=/usr/local/bin/resilient-launch.sh /usr/local/bin/$3
[Install]
WantedBy=multi-user.target
EOS
}

bromure_agent_unit file-agent            chrome file-agent.py
bromure_agent_unit webcam-agent          root   webcam-agent.py
bromure_agent_unit precision-scroll-agent root  precision-scroll-agent.py
bromure_agent_unit warp-agent            root   warp-agent.py
bromure_agent_unit wireguard-agent       root   wireguard-agent.py
bromure_agent_unit ikev2-agent           root   ikev2-agent.py
bromure_agent_unit openvpn-agent         root   openvpn-agent.py
bromure_agent_unit network-refresh-agent root   network-refresh-agent.py
bromure_agent_unit keyboard-agent        chrome keyboard-agent.py
bromure_agent_unit cjk-input-agent       chrome cjk-input-agent.py

systemctl enable bromure-onboot.service bromure-config-agent.service \
    bromure-file-agent.service bromure-webcam-agent.service \
    bromure-precision-scroll-agent.service bromure-warp-agent.service \
    bromure-wireguard-agent.service bromure-ikev2-agent.service \
    bromure-openvpn-agent.service bromure-network-refresh-agent.service \
    bromure-keyboard-agent.service bromure-cjk-input-agent.service \
    >/dev/null 2>&1

# ---------------------------------------------------------------------------
# initramfs: make sure the virtio boot path is present, then rebuild.
# ---------------------------------------------------------------------------

for m in virtio_blk virtio_pci virtio_console ext4; do
    grep -qx "$m" /etc/initramfs-tools/modules 2>/dev/null || echo "$m" >> /etc/initramfs-tools/modules
done
update-initramfs -u -k "$KVER" || update-initramfs -c -k "$KVER"

# ---------------------------------------------------------------------------
# v4l2loopback via dkms (webcam sharing). Ubuntu has no prebuilt module;
# build it against the installed kernel, then purge the toolchain.
#
# The built .ko must be STASHED before the cleanup: removing the dkms
# package (which apt-get autoremove does once gcc/make/headers are gone,
# leaving it with no reverse-deps) runs its prerm `dkms remove`, which
# deletes the module from /lib/modules. So copy the .ko to a plain file
# outside the dkms tree first, run the cleanup, then restore it and
# depmod — the shipped module is then an ordinary file the package
# manager no longer tracks. (This mirrors the old Alpine image, which
# copied a prebuilt .ko in rather than building in place.)
# ---------------------------------------------------------------------------

log "building v4l2loopback (dkms)"
V4L2_OK=true
# zstd: this kernel's modules are all .ko.zst, and dkms 3.x shells out
# to the `zstd` CLI to compress what it builds. Without it the install
# silently produces no usable module ("zstd: command not found", then an
# empty updates/dkms). It's a build-time tool only — modprobe/kmod
# decompress zstd modules on their own — so it's purged with the rest of
# the toolchain below.
apt-get install -y -q --no-install-recommends \
    dkms "linux-headers-$KVER" gcc make zstd || V4L2_OK=false
if [ "$V4L2_OK" = "true" ]; then
    apt-get install -y -q --no-install-recommends v4l2loopback-dkms || V4L2_OK=false
fi
V4L2_KO=$(ls "/lib/modules/$KVER/updates/dkms/v4l2loopback.ko"* 2>/dev/null | head -1)
if [ -n "$V4L2_KO" ]; then
    cp "$V4L2_KO" "/tmp/v4l2loopback.ko.stash"
    log "V4L2LOOPBACK_INSTALLED_OK"
else
    V4L2_OK=false
    log "warning: v4l2loopback module missing — webcam sharing will not work"
fi
if [ "$BUILD_MODE" = "foss" ] && [ "$V4L2_OK" != "true" ]; then
    fail "v4l2loopback dkms build failed for $KVER — a distribution build must not degrade"
fi
apt-get purge -y -q "linux-headers-*" gcc make dkms v4l2loopback-dkms zstd >/dev/null 2>&1 || true
apt-get autoremove -y -q >/dev/null 2>&1 || true
# Restore the stashed module now that the toolchain (and the dkms
# bookkeeping that would delete it) is gone. Gzip it so it matches how
# depmod/modprobe expect compressed modules on Ubuntu and to save space.
if [ -f /tmp/v4l2loopback.ko.stash ]; then
    mkdir -p "/lib/modules/$KVER/updates"
    case "$V4L2_KO" in
        *.zst) cp /tmp/v4l2loopback.ko.stash "/lib/modules/$KVER/updates/v4l2loopback.ko.zst" ;;
        *.gz)  cp /tmp/v4l2loopback.ko.stash "/lib/modules/$KVER/updates/v4l2loopback.ko.gz" ;;
        *)     cp /tmp/v4l2loopback.ko.stash "/lib/modules/$KVER/updates/v4l2loopback.ko" ;;
    esac
    rm -f /tmp/v4l2loopback.ko.stash
fi
depmod "$KVER"

# ---------------------------------------------------------------------------
# Image slimming. The guest is a single-purpose disposable browser VM, so
# strip packages nothing here uses. dpkg path-excludes (set at the top of
# the chroot) already kept docs/man/locale out of everything installed
# after debootstrap; below removes the rest.
# ---------------------------------------------------------------------------

log "slimming: reclaiming orphans + docs/man/locale"
# Package removal here is DELIBERATELY limited to autoremove of genuine
# orphans (the dkms-toolchain transitives). Do NOT purge named packages:
# the print stack (libcups2 → libgs10/ghostscript) and even the Ubuntu
# icon themes turned out to be load-bearing — purging any of them
# cascades and takes Chromium + all of GTK/X with it. autoremove only
# touches auto-installed packages nothing manual still needs, so Chromium
# (explicitly installed = manual) and its dependency tree are safe.
apt-get autoremove -y -q --purge >/dev/null 2>&1 || true

# The path-excludes stop NEW docs/man/locale, but debootstrap's own
# minbase set was unpacked before the exclude file existed — clear it.
# In /usr/share/doc keep the copyright files (license compliance for the
# redistributable image); drop everything else there and the rest wholesale.
find /usr/share/doc -type f ! -name copyright -delete 2>/dev/null || true
find /usr/share/doc -type l -delete 2>/dev/null || true
rm -rf /usr/share/man/* /usr/share/info/* /usr/share/groff/* \
       /usr/share/lintian/* /var/cache/apt/archives/*.deb 2>/dev/null || true
# Keep only the locales the product ships (session locales + en); drop the
# rest of /usr/share/locale left by minbase.
( cd /usr/share/locale 2>/dev/null && for d in */; do
    case "${d%/}" in
        en|en_US|en_GB|fr|de|es|pt|pt_BR|ja|zh|zh_CN|zh_TW|zh_Hans|zh_Hant|locale.alias) ;;
        *) rm -rf "$d" ;;
    esac
done ) || true

log "chroot phase complete"
CHROOT_EOF
[ $? -eq 0 ] || { echo "SANDBOX_SETUP_FAILED: chroot provisioning failed"; exit 1; }
echo "SANDBOX_STEP_DONE:Installing packages"

ls -la /mnt/sbin/init || {
    echo "SANDBOX_SETUP_FAILED: /sbin/init not found — package installation likely failed"
    exit 1
}

# ---------------------------------------------------------------------------
# Configuration files (static)
# ---------------------------------------------------------------------------

# Proxy & DNS
mkdir -p /mnt/etc/proxychains
install_config configs/proxychains.conf /mnt/etc/proxychains/proxychains.conf

mkdir -p /mnt/etc/pihole /mnt/var/log/pihole /mnt/etc/dnsmasq.d
for i in 1 2 3; do
    wget -qO /mnt/etc/pihole/gravity.list \
        'https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts' && break
    sleep 2
done
touch /mnt/etc/pihole/local.list /mnt/etc/pihole/custom.list
install_config configs/pihole-setupVars.conf /mnt/etc/pihole/setupVars.conf
install_config configs/dnsmasq-pihole.conf   /mnt/etc/dnsmasq.d/pihole.conf

# Chromium policies
mkdir -p /mnt/etc/chromium/policies/managed
install_config configs/chromium-policy.json /mnt/etc/chromium/policies/managed/bromure.json

# Squid
install_config configs/squid.conf /mnt/etc/squid/squid.conf

# Sysctl
install_config configs/sysctl-bromure.conf /mnt/etc/sysctl.d/99-bromure.conf
install_config configs/sysctl-warp.conf    /mnt/etc/sysctl.d/warp.conf

# Network
install_config configs/network-interfaces /mnt/etc/network/interfaces
install_config configs/fstab              /mnt/etc/fstab
# Pin the virtio NIC to eth0 regardless of the booting app's cmdline
# (net.ifnames=0 or not) — see the .link file's header.
mkdir -p /mnt/etc/systemd/network
install_config configs/10-bromure-eth0.link /mnt/etc/systemd/network/10-bromure-eth0.link

# Font rendering (match macOS Core Text: no hinting, stem darkening, SF Pro default)
install_config configs/fontconfig-local.conf /mnt/etc/fonts/local.conf

# GTK3 settings (Chromium reads these for its UI chrome font)
mkdir -p /mnt/home/chrome/.config/gtk-3.0
install_config configs/gtk3-settings.ini /mnt/home/chrome/.config/gtk-3.0/settings.ini

# doas (opendoas on Ubuntu reads the single /etc/doas.conf)
install_config configs/doas-chrome.conf /mnt/etc/doas.conf
chmod 0400 /mnt/etc/doas.conf

# ---------------------------------------------------------------------------
# Configuration files (templated)
# ---------------------------------------------------------------------------

install_template configs/locale.sh /mnt/etc/profile.d/locale.sh

# ---------------------------------------------------------------------------
# Display and input
# ---------------------------------------------------------------------------

# Udev
mkdir -p /mnt/etc/udev/rules.d
install_config configs/70-dri.rules /mnt/etc/udev/rules.d/70-dri.rules
install_config configs/71-hvc0.rules /mnt/etc/udev/rules.d/71-hvc0.rules

# Cursor theme
mkdir -p /mnt/usr/share/icons/default
install_config configs/cursor-index.theme /mnt/usr/share/icons/default/index.theme

# Xorg
mkdir -p /mnt/etc/X11/xorg.conf.d
install_config   configs/xorg-10-virtio.conf   /mnt/etc/X11/xorg.conf.d/10-virtio.conf
install_template configs/xorg-20-keyboard.conf /mnt/etc/X11/xorg.conf.d/20-keyboard.conf
install_config   configs/xorg-20-bromure-scroll.conf /mnt/etc/X11/xorg.conf.d/20-bromure-scroll.conf
install_template configs/xorg-30-scrolling.conf /mnt/etc/X11/xorg.conf.d/30-scrolling.conf
install_config   configs/Xwrapper.conf         /mnt/etc/X11/Xwrapper.config

# ---------------------------------------------------------------------------
# Scripts and user config
# ---------------------------------------------------------------------------

install_config   scripts/resize-watcher.sh  /mnt/usr/local/bin/resize-watcher.sh 755
install_config   scripts/apply-config.sh   /mnt/usr/local/bin/apply-config.sh 755
install_config   scripts/install-mtls.sh   /mnt/usr/local/bin/install-mtls.sh 755
install_config   scripts/on-boot.sh        /mnt/usr/local/bin/on-boot.sh 755
install_template scripts/xinitrc           /mnt/home/chrome/.xinitrc
chroot /mnt chown chrome:chrome /home/chrome/.xinitrc

install_config scripts/debug.sh        /mnt/root/debug.sh          755
install_config scripts/root-profile.sh /mnt/root/.profile

# Openbox
mkdir -p /mnt/home/chrome/.config/openbox
mkdir -p /mnt/home/chrome/.cache/openbox/sessions
install_config configs/openbox-rc.xml          /mnt/home/chrome/.config/openbox/rc.xml
install_config configs/openbox-rc-nativetabs.xml /mnt/home/chrome/.config/openbox/rc-nativetabs.xml
install_config configs/openbox-menu.xml /mnt/home/chrome/.config/openbox/menu.xml

# Browser preferences — same seed for both browsers (a session without a
# persistent profile disk uses the default dotdir of whichever browser
# the profile selects).
mkdir -p /mnt/home/chrome/.config/chromium/Default
install_config configs/chromium-preferences.json /mnt/home/chrome/.config/chromium/Default/Preferences
mkdir -p /mnt/home/chrome/.config/google-chrome/Default
install_config configs/chromium-preferences.json /mnt/home/chrome/.config/google-chrome/Default/Preferences
chroot /mnt chown -R chrome:chrome /home/chrome/.config /home/chrome/.cache

# ---------------------------------------------------------------------------
# macOS fonts (shared from host via VirtioFS for web rendering parity).
# NEVER in a foss/distribution build: Apple fonts are not redistributable
# — end-user installs copy them from the user's own Mac during
# postinstall.sh instead (the host attaches no font shares in foss mode).
# ---------------------------------------------------------------------------

mkdir -p /mnt/usr/share/fonts/macos
if [ "$BUILD_MODE" != "foss" ]; then
    MAX_FONTS_BYTES=734003200  # 700 MB cap to avoid filling the disk
    # Mount all font shares, collect paths with sizes, copy smallest-first up to the cap,
    # then unmount. This avoids filling the disk when the host has many user-installed fonts.
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
    echo "Copied $MACOS_FONT_COUNT macOS font files"
else
    echo "foss build: skipping macOS fonts (copied during end-user postinstall)"
fi

# Pre-compute font cache so X11/Chromium don't scan fonts on first boot
chroot /mnt fc-cache -f

# Chrome user profile (auto-starts X)
install_config scripts/chrome-profile.sh /mnt/home/chrome/.profile
chroot /mnt chown chrome:chrome /home/chrome/.profile

# ---------------------------------------------------------------------------
# File transfer agent
# ---------------------------------------------------------------------------

install_config scripts/file-agent.py        /mnt/usr/local/bin/file-agent.py        755
install_config scripts/file-picker-host.py  /mnt/usr/local/bin/file-picker-host.py  755
install_config scripts/link-agent.py        /mnt/usr/local/bin/link-agent.py        755
install_config scripts/mtls-reload-agent.py /mnt/usr/local/bin/mtls-reload-agent.py 755
install_config scripts/webcam-agent.py      /mnt/usr/local/bin/webcam-agent.py      755
install_config scripts/precision-scroll-agent.py      /mnt/usr/local/bin/precision-scroll-agent.py      755
install_config scripts/warp-agent.py        /mnt/usr/local/bin/warp-agent.py        755
install_config scripts/wireguard-agent.py  /mnt/usr/local/bin/wireguard-agent.py  755
install_config scripts/ikev2-agent.py     /mnt/usr/local/bin/ikev2-agent.py     755
install_config scripts/openvpn-agent.py   /mnt/usr/local/bin/openvpn-agent.py   755
install_config scripts/network-refresh-agent.py /mnt/usr/local/bin/network-refresh-agent.py 755
install_config scripts/keyboard-agent.py    /mnt/usr/local/bin/keyboard-agent.py    755
install_config scripts/cjk-input-agent.py  /mnt/usr/local/bin/cjk-input-agent.py  755
install_config scripts/routing-socks.py     /mnt/usr/local/bin/routing-socks.py     755
install_config scripts/config-agent.py      /mnt/usr/local/bin/config-agent.py      755
install_config scripts/cdp-agent.py         /mnt/usr/local/bin/cdp-agent.py         755
install_config scripts/tab-agent.py         /mnt/usr/local/bin/tab-agent.py         755
install_config scripts/bromure-hostkey      /mnt/usr/local/bin/bromure-hostkey      755
install_config scripts/shell-agent.py       /mnt/usr/local/bin/shell-agent.py       755
install_config scripts/trace-agent.py      /mnt/usr/local/bin/trace-agent.py      755
install_config scripts/resilient-launch.sh /mnt/usr/local/bin/resilient-launch.sh 755
install_config scripts/download-guard.sh    /mnt/usr/local/bin/download-guard.sh    755
install_config scripts/test-runner.sh      /mnt/usr/local/bin/test-runner.sh       755

# ---------------------------------------------------------------------------
# Credential bridge (passkeys + passwords)
# ---------------------------------------------------------------------------

install_config scripts/credential-agent.py /mnt/usr/local/bin/credential-agent.py 755

# Chrome extension
mkdir -p /mnt/opt/bromure/extensions/credential-bridge
for f in manifest.json content-main.js content-isolated.js background.js; do
    [ -f "$SCRIPT_DIR/extensions/credential-bridge/$f" ] && \
        cp "$SCRIPT_DIR/extensions/credential-bridge/$f" /mnt/opt/bromure/extensions/credential-bridge/
done

# Native messaging host manifest (system-wide)
mkdir -p /mnt/etc/chromium/native-messaging-hosts
install_config configs/com.bromure.credential_bridge.json /mnt/etc/chromium/native-messaging-hosts/com.bromure.credential_bridge.json

# ---------------------------------------------------------------------------
# Phishing guard extension + analysis agent
# ---------------------------------------------------------------------------

install_config scripts/phishing-agent.py /mnt/usr/local/bin/phishing-agent.py 755

mkdir -p /mnt/opt/bromure/extensions/phishing-guard
for f in manifest.json background.js content.js jsQR.min.js clickfix-inject.js popup.html popup.css popup.js blocked.html blocked.css blocked.js; do
    [ -f "$SCRIPT_DIR/extensions/phishing-guard/$f" ] && \
        cp "$SCRIPT_DIR/extensions/phishing-guard/$f" /mnt/opt/bromure/extensions/phishing-guard/
done

# Native messaging host manifest for phishing analysis
install_config configs/com.bromure.phishing_guard.json /mnt/etc/chromium/native-messaging-hosts/com.bromure.phishing_guard.json

# ---------------------------------------------------------------------------
# Link sender extension
# ---------------------------------------------------------------------------

mkdir -p /mnt/opt/bromure/extensions/link-sender
for f in manifest.json background.js; do
    [ -f "$SCRIPT_DIR/extensions/link-sender/$f" ] && \
        cp "$SCRIPT_DIR/extensions/link-sender/$f" /mnt/opt/bromure/extensions/link-sender/
done

# ---------------------------------------------------------------------------
# File picker extension
# ---------------------------------------------------------------------------

mkdir -p /mnt/opt/bromure/extensions/file-picker
for f in manifest.json background.js content.js schema.json; do
    [ -f "$SCRIPT_DIR/extensions/file-picker/$f" ] && \
        cp "$SCRIPT_DIR/extensions/file-picker/$f" /mnt/opt/bromure/extensions/file-picker/
done

# ---------------------------------------------------------------------------
# WebRTC block extension (conditionally loaded at runtime)
# ---------------------------------------------------------------------------

mkdir -p /mnt/opt/bromure/extensions/webrtc-block
for f in manifest.json block.js; do
    [ -f "$SCRIPT_DIR/extensions/webrtc-block/$f" ] && \
        cp "$SCRIPT_DIR/extensions/webrtc-block/$f" /mnt/opt/bromure/extensions/webrtc-block/
done

# IP-register extension (only loaded for managed sessions at runtime;
# heartbeats the browser's egress IP to analytics.bromure.io so the
# control plane can keep customer SaaS allowlists in sync).
mkdir -p /mnt/opt/bromure/extensions/ip-register
for f in manifest.json background.js; do
    [ -f "$SCRIPT_DIR/extensions/ip-register/$f" ] && \
        cp "$SCRIPT_DIR/extensions/ip-register/$f" /mnt/opt/bromure/extensions/ip-register/
done

# Corporate Guard extension (managed-session only; banner mode or
# redirect-to-incognito, configured per managed profile via
# chrome.storage.managed).
mkdir -p /mnt/opt/bromure/extensions/corporate-guard
for f in manifest.json schema.json common.js background.js content.js blocked.html; do
    [ -f "$SCRIPT_DIR/extensions/corporate-guard/$f" ] && \
        cp "$SCRIPT_DIR/extensions/corporate-guard/$f" /mnt/opt/bromure/extensions/corporate-guard/
done

# Trace extension
mkdir -p /mnt/opt/bromure/extensions/trace
for f in manifest.json background.js form-capture.js; do
    [ -f "$SCRIPT_DIR/extensions/trace/$f" ] && \
        cp "$SCRIPT_DIR/extensions/trace/$f" /mnt/opt/bromure/extensions/trace/
done

# VPN-connecting splash page (shown by xinitrc before Chrome when a
# connect-at-startup VPN is configured — prevents IP leak during handshake).
mkdir -p /mnt/opt/bromure/splash
install_config splash/splash.html /mnt/opt/bromure/splash/splash.html
install_config splash/night.jpg   /mnt/opt/bromure/splash/night.jpg
install_config splash/day.jpg     /mnt/opt/bromure/splash/day.jpg

# Native messaging hosts (link sender + file picker + trace + corporate guard)
mkdir -p /mnt/etc/chromium/native-messaging-hosts
install_config configs/com.bromure.link_sender.json \
    /mnt/etc/chromium/native-messaging-hosts/com.bromure.link_sender.json
install_config configs/com.bromure.file_picker.json \
    /mnt/etc/chromium/native-messaging-hosts/com.bromure.file_picker.json
install_config configs/com.bromure.trace.json \
    /mnt/etc/chromium/native-messaging-hosts/com.bromure.trace.json


# Download Tranco top domains list (research-grade popularity ranking)
echo "SANDBOX_STEP_START:Downloading popular domains list"
TRANCO_URL="https://tranco-list.eu/top-1m.csv.zip"
TRANCO_ZIP="/tmp/tranco-top-1m.csv.zip"
apk add unzip || true
if wget -q -O "$TRANCO_ZIP" "$TRANCO_URL"; then
    unzip -o -q "$TRANCO_ZIP" -d /tmp/
    # Extract top 10,000 domains (CSV format: rank,domain), build JSON array
    {
        echo "["
        head -n 100000 /tmp/top-1m.csv | tr -d '\r' | cut -d',' -f2 | \
            sed 's/.*/"&"/' | paste -sd',' -
        echo "]"
    } > /mnt/opt/bromure/extensions/phishing-guard/top-domains.json
    DOMAIN_COUNT=$(head -n 100000 /tmp/top-1m.csv | wc -l)
    echo "Loaded $DOMAIN_COUNT popular domains from Tranco list"
    rm -f "$TRANCO_ZIP" /tmp/top-1m.csv
else
    echo "Warning: Could not download Tranco list, using empty domain list"
    echo "[]" > /mnt/opt/bromure/extensions/phishing-guard/top-domains.json
fi
echo "SANDBOX_STEP_DONE:Downloading popular domains list"

# ---------------------------------------------------------------------------
# Pack the extensions as signed CRXs for Google Chrome. Branded Chrome
# ignores --load-extension (Chromium honours it), so Chrome force-installs
# them via ExtensionInstallForcelist from a self-hosted update manifest —
# which needs each extension packed + signed. crx-pack.py does that in the
# chroot (has chromium + python3), keyed by the committed signing keys
# whose public halves are each manifest's "key", so both browsers resolve
# the same extension id. The keys are removed afterward — only the .crx +
# update.xml land in the image.
# ---------------------------------------------------------------------------

if [ -d "$SCRIPT_DIR/crx-keys" ]; then
    echo "SANDBOX_STEP_START:Packing browser extensions"
    rm -rf /mnt/tmp/crx-keys
    cp -r "$SCRIPT_DIR/crx-keys" /mnt/tmp/crx-keys
    install_config scripts/crx-pack.py /mnt/usr/local/bin/crx-pack.py 755
    chroot /mnt /usr/local/bin/crx-pack.py || echo "warning: CRX packing failed — Chrome will have no extensions"
    rm -rf /mnt/tmp/crx-keys
    echo "SANDBOX_STEP_DONE:Packing browser extensions"
fi

# ---------------------------------------------------------------------------
# Kernel modules loaded at boot. Ubuntu's kernel has rtc-pl031 built in
# (Alpine's virt kernel needed an out-of-tree build); v4l2loopback was
# dkms-built in the chroot phase.
# ---------------------------------------------------------------------------

cat "$SCRIPT_DIR/configs/modules" >> /mnt/etc/modules

# ---------------------------------------------------------------------------
# Swap file (256 MB) — activated via the fstab entry. Small on purpose: the
# VM has 2-3 GB RAM plus a memory balloon, the session is disposable, and
# every megabyte of swap is a megabyte of the (now 5 GB) disk the browser
# can't use — swap is just OOM insurance, not working storage.
# ---------------------------------------------------------------------------

dd if=/dev/zero of=/mnt/swap bs=1M count=256
chmod 600 /mnt/swap
mkswap /mnt/swap

# ---------------------------------------------------------------------------
# Cleanup and finish
# ---------------------------------------------------------------------------

# The shipped image must not carry bake-time-only state: the proxy conf
# points at a listener that only exists during the bake, and the apt
# lists/caches are dead weight.
rm -f /mnt/etc/apt/apt.conf.d/99-bromure-proxy
chroot /mnt apt-get clean
rm -rf /mnt/var/lib/apt/lists/*
rm -f /mnt/tmp/bromure-build.env

# Static public DNS as the baked fallback; DHCP overwrites it at boot.
printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' > /mnt/etc/resolv.conf

# A chroot step may have left a process running (dpkg triggers, dbus);
# its open fds would keep /mnt busy. Kill anything still rooted there —
# this teardown runs with root '/', so it never matches itself.
for p in /proc/[0-9]*; do
    [ -e "$p/root" ] || continue
    case "$(readlink "$p/root" 2>/dev/null)" in
        /mnt|/mnt/*) kill -9 "${p#/proc/}" 2>/dev/null || true ;;
    esac
done

# ---------------------------------------------------------------------------
# Scrub free space. Files deleted during the bake (apt archives, extracted
# tarballs) otherwise survive as free-but-nonzero blocks in the raw image —
# ~1.2 GB of mostly already-compressed .deb payload that inflates
# base.img.gz by ~800 MB. fstrim (Ubuntu's, via chroot — busybox may lack
# it) punches the freed blocks out as host-side holes when the virtio disk
# supports discard; if it doesn't, overwrite all free space with zeros so
# it at least compresses to nothing. The fill dd is EXPECTED to fail with
# ENOSPC — filling the disk is the point.
# ---------------------------------------------------------------------------
if chroot /mnt fstrim -v /; then
    echo "sandbox-setup: free space trimmed"
else
    echo "sandbox-setup: fstrim unsupported — zero-filling free space"
    dd if=/dev/zero of=/mnt/.zerofill bs=4M 2>/dev/null || true
    sync
    rm -f /mnt/.zerofill
fi
sync

# debootstrap/apt stack extra mounts inside the target (a second /proc,
# /dev/shm, …) — unmount each point repeatedly until it's clear, or the
# final umount /mnt fails EBUSY and the extract phase inherits a dirty,
# still-mounted filesystem.
for m in /mnt/dev/pts /mnt/dev/shm /mnt/dev /mnt/sys /mnt/proc; do
    while mountpoint -q "$m" 2>/dev/null; do
        umount "$m" 2>/dev/null || break
    done
done
umount /mnt || { sleep 2; umount /mnt; } || {
    echo "SANDBOX_SETUP_FAILED: could not cleanly unmount /mnt"
    exit 1
}

echo SANDBOX_SETUP_DONE
