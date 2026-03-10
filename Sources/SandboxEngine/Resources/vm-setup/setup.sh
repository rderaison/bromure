#!/bin/sh
# Bromure VM setup script — installs Alpine Linux with Chromium
# Usage: setup.sh KEYBOARD_LAYOUT NATURAL_SCROLLING LOCALE DISPLAY_SCALE ALPINE_VERSION
# No set -e: non-critical sections (WARP, ad blocking) may fail gracefully

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KB_LAYOUT="${1:-us}"
NATURAL_SCROLLING="${2:-true}"
LOCALE="${3:-en_US}"
DISPLAY_SCALE="${4:-2}"
ALPINE_VERSION="${5:-3.23}"
CURSOR_SIZE=$((DISPLAY_SCALE * 24))

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
    sed -e "s|%%KEYBOARD_LAYOUT%%|$KB_LAYOUT|g" \
        -e "s|%%NATURAL_SCROLLING%%|$NATURAL_SCROLLING|g" \
        -e "s|%%LOCALE%%|$LOCALE|g" \
        -e "s|%%DISPLAY_SCALE%%|$DISPLAY_SCALE|g" \
        -e "s|%%CURSOR_SIZE%%|$CURSOR_SIZE|g" \
        "$SCRIPT_DIR/$1" > "$2"
    [ -n "$3" ] && chmod "$3" "$2"
}

# ---------------------------------------------------------------------------
# Network connectivity check
# ---------------------------------------------------------------------------

echo "Waiting for network..."
for i in $(seq 1 30); do
    wget -q -O /dev/null --spider http://dl-cdn.alpinelinux.org/alpine/ 2>/dev/null && break
    sleep 1
done
wget -q -O /dev/null --spider http://dl-cdn.alpinelinux.org/alpine/ 2>/dev/null || {
    echo "SANDBOX_SETUP_FAILED: no network connectivity — check your internet connection"
    exit 1
}

# ---------------------------------------------------------------------------
# Format and mount target disk
# ---------------------------------------------------------------------------

modprobe ext4
retry apk add e2fsprogs
mkfs.ext4 -q -F /dev/vda
mkdir -p /mnt
mount -t ext4 /dev/vda /mnt

# ---------------------------------------------------------------------------
# Install Alpine base system
# ---------------------------------------------------------------------------

retry apk add alpine-base --root /mnt --initdb \
    --keys-dir /etc/apk/keys --repositories-file /etc/apk/repositories

mkdir -p /mnt/etc/apk
printf '%s\n' \
    "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main" \
    "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community" \
    > /mnt/etc/apk/repositories

cp /etc/resolv.conf /mnt/etc/resolv.conf

# Bind-mount for chroot
mount -t proc proc /mnt/proc
mount -t sysfs sys /mnt/sys
mount --bind /dev /mnt/dev

# ---------------------------------------------------------------------------
# Install packages
# ---------------------------------------------------------------------------

retry chroot /mnt apk update
retry chroot /mnt apk add openrc linux-virt linux-firmware-none mkinitfs e2fsprogs
retry chroot /mnt apk add \
    chromium xorg-server xinit mesa-dri-gallium mesa-egl mesa-gl mesa-gles \
    mesa-gbm eudev dbus ttf-freefont ttf-dejavu font-noto-emoji font-liberation \
    xf86-input-libinput agetty util-linux openbox xrandr xdotool setxkbmap \
    pulseaudio pulseaudio-alsa alsa-utils alsa-plugins-pulse adwaita-icon-theme \
    spice-vdagent

ls -la /mnt/sbin/init || {
    echo "SANDBOX_SETUP_FAILED: /sbin/init not found — package installation likely failed"
    exit 1
}

# ---------------------------------------------------------------------------
# Cloudflare WARP (glibc binary on musl Alpine)
# ---------------------------------------------------------------------------

retry chroot /mnt apk add gcompat libstdc++ ca-certificates nftables iproute2 \
    glib nss nspr libgcc
retry apk add binutils

WARP_DEB=$(wget -qO- 'https://pkg.cloudflareclient.com/dists/bookworm/main/binary-arm64/Packages' \
    | grep '^Filename:' | tail -1 | cut -d' ' -f2)
for i in 1 2 3; do
    wget -q "https://pkg.cloudflareclient.com/$WARP_DEB" -O /tmp/warp.deb && break
    sleep 2
done
cd /tmp && ar x warp.deb 2>/dev/null
tar xf /tmp/data.tar.* -C /mnt 2>/dev/null || echo "WARP_EXTRACT_FAILED"
rm -f /tmp/warp.deb /tmp/data.tar.* /tmp/control.tar.* /tmp/debian-binary
mkdir -p /mnt/var/lib/cloudflare-warp /mnt/var/log/cloudflare-warp
ls -la /mnt/bin/warp-cli 2>/dev/null && echo "WARP_INSTALLED_OK" || echo "WARP_INSTALL_FAILED"

# Build glibc resolver stub (gcompat lacks __res_init)
retry apk add gcc musl-dev
cp "$SCRIPT_DIR/configs/resolv-stub.c" /tmp/resolv_stub.c
gcc -shared -o /mnt/usr/lib/libresolv_stub.so /tmp/resolv_stub.c
rm -f /tmp/resolv_stub.c

# ---------------------------------------------------------------------------
# Install proxy and DNS tools
# ---------------------------------------------------------------------------

retry chroot /mnt apk add squid dnsmasq proxychains-ng cryptsetup inotify-tools jq python3

# ---------------------------------------------------------------------------
# Configuration files (static)
# ---------------------------------------------------------------------------

# Proxy & DNS
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

# ---------------------------------------------------------------------------
# Configuration files (templated)
# ---------------------------------------------------------------------------

install_template configs/locale.sh /mnt/etc/profile.d/locale.sh

# ---------------------------------------------------------------------------
# Users and permissions
# ---------------------------------------------------------------------------

chroot /mnt sh -c 'echo "root:" | chpasswd'
chroot /mnt adduser -D -s /bin/sh chrome
chroot /mnt addgroup chrome video
chroot /mnt addgroup chrome render
chroot /mnt addgroup chrome input
chroot /mnt addgroup chrome audio
retry chroot /mnt apk add doas
install_config configs/doas-chrome.conf /mnt/etc/doas.d/chrome.conf

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------

chroot /mnt rc-update add devfs sysinit
chroot /mnt rc-update add dmesg sysinit
chroot /mnt rc-update add udev sysinit
chroot /mnt rc-update add networking boot
chroot /mnt rc-update add modules boot
chroot /mnt rc-update add dbus default
chroot /mnt rc-update add spice-vdagentd default

# ---------------------------------------------------------------------------
# Console and login
# ---------------------------------------------------------------------------

sed -i 's|^tty1::.*|tty1::respawn:/bin/login -f chrome|' /mnt/etc/inittab
echo 'hvc0::respawn:/bin/login -f root' >> /mnt/etc/inittab

install_config scripts/debug.sh        /mnt/root/debug.sh          755
install_config scripts/root-profile.sh /mnt/root/.profile

# ---------------------------------------------------------------------------
# Display and input
# ---------------------------------------------------------------------------

# Udev
mkdir -p /mnt/etc/udev/rules.d
install_config configs/70-dri.rules /mnt/etc/udev/rules.d/70-dri.rules

# Cursor theme
mkdir -p /mnt/usr/share/icons/default
install_config configs/cursor-index.theme /mnt/usr/share/icons/default/index.theme

# Xorg
mkdir -p /mnt/etc/X11/xorg.conf.d
install_config   configs/xorg-10-virtio.conf   /mnt/etc/X11/xorg.conf.d/10-virtio.conf
install_template configs/xorg-20-keyboard.conf /mnt/etc/X11/xorg.conf.d/20-keyboard.conf
install_template configs/xorg-30-scrolling.conf /mnt/etc/X11/xorg.conf.d/30-scrolling.conf
install_config   configs/Xwrapper.conf         /mnt/etc/X11/Xwrapper.config

# ---------------------------------------------------------------------------
# Scripts and user config
# ---------------------------------------------------------------------------

install_config   scripts/resize-watcher.sh  /mnt/usr/local/bin/resize-watcher.sh 755
install_config   scripts/apply-config.sh   /mnt/usr/local/bin/apply-config.sh 755
install_config   scripts/on-boot.sh        /mnt/usr/local/bin/on-boot.sh 755
install_template scripts/xinitrc           /mnt/home/chrome/.xinitrc
chroot /mnt chown chrome:chrome /home/chrome/.xinitrc

# Openbox
mkdir -p /mnt/home/chrome/.config/openbox
mkdir -p /mnt/home/chrome/.cache/openbox/sessions
install_config configs/openbox-rc.xml   /mnt/home/chrome/.config/openbox/rc.xml
install_config configs/openbox-menu.xml /mnt/home/chrome/.config/openbox/menu.xml

# Chromium preferences
mkdir -p /mnt/home/chrome/.config/chromium/Default
install_config configs/chromium-preferences.json /mnt/home/chrome/.config/chromium/Default/Preferences
chroot /mnt chown -R chrome:chrome /home/chrome/.config /home/chrome/.cache

# Chrome user profile (auto-starts X)
install_config scripts/chrome-profile.sh /mnt/home/chrome/.profile
chroot /mnt chown chrome:chrome /home/chrome/.profile

# ---------------------------------------------------------------------------
# File transfer agent
# ---------------------------------------------------------------------------

install_config scripts/file-agent.sh /mnt/usr/local/bin/file-agent.sh 755

# ---------------------------------------------------------------------------
# Phishing guard extension
# ---------------------------------------------------------------------------

mkdir -p /mnt/opt/bromure/extensions/phishing-guard
for f in manifest.json background.js content.js popup.html popup.css popup.js blocked.html blocked.css blocked.js; do
    [ -f "$SCRIPT_DIR/extensions/phishing-guard/$f" ] && \
        cp "$SCRIPT_DIR/extensions/phishing-guard/$f" /mnt/opt/bromure/extensions/phishing-guard/
done

# Download Tranco top domains list (research-grade popularity ranking)
echo "SANDBOX_STEP_START:Downloading popular domains list"
TRANCO_URL="https://tranco-list.eu/top-1m.csv.zip"
TRANCO_ZIP="/tmp/tranco-top-1m.csv.zip"
retry apk add unzip
if wget -q -O "$TRANCO_ZIP" "$TRANCO_URL"; then
    unzip -o -q "$TRANCO_ZIP" -d /tmp/
    # Extract top 10,000 domains (CSV format: rank,domain), build JSON array
    {
        echo "["
        head -n 10000 /tmp/top-1m.csv | cut -d',' -f2 | \
            sed 's/.*/"&"/' | paste -sd',' -
        echo "]"
    } > /mnt/opt/bromure/extensions/phishing-guard/top-domains.json
    DOMAIN_COUNT=$(head -n 10000 /tmp/top-1m.csv | wc -l)
    echo "Loaded $DOMAIN_COUNT popular domains from Tranco list"
    rm -f "$TRANCO_ZIP" /tmp/top-1m.csv
else
    echo "Warning: Could not download Tranco list, using empty domain list"
    echo "[]" > /mnt/opt/bromure/extensions/phishing-guard/top-domains.json
fi
echo "SANDBOX_STEP_DONE:Downloading popular domains list"

# ---------------------------------------------------------------------------
# Kernel and initramfs
# ---------------------------------------------------------------------------

install_config configs/mkinitfs.conf /mnt/etc/mkinitfs/mkinitfs.conf
chroot /mnt ls /etc/mkinitfs/features.d/ 2>/dev/null || true
chroot /mnt sh -c 'mkinitfs $(ls /lib/modules/)'

# Kernel modules
cat "$SCRIPT_DIR/configs/modules" >> /mnt/etc/modules

# ---------------------------------------------------------------------------
# Cleanup and finish
# ---------------------------------------------------------------------------

umount /mnt/dev
umount /mnt/sys
umount /mnt/proc
umount /mnt

echo SANDBOX_SETUP_DONE
