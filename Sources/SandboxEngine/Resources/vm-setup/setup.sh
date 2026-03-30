#!/bin/sh
# Bromure VM setup script — installs Alpine Linux with Chromium
# Usage: setup.sh KEYBOARD_LAYOUT NATURAL_SCROLLING LOCALE DISPLAY_SCALE ALPINE_VERSION
# No set -e: non-critical sections (WARP, ad blocking) may fail gracefully

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KB_LAYOUT_SPEC="${1:-us}"
NATURAL_SCROLLING="${2:-true}"
LOCALE="${3:-en_US}"
DISPLAY_SCALE="${4:-2}"
ALPINE_VERSION="${5:-3.22}"
CURSOR_SIZE=$((DISPLAY_SCALE * 24))

# Parse layout:variant format (e.g. "ch:fr" → layout="ch", variant="fr")
case "$KB_LAYOUT_SPEC" in
    *:*) KB_LAYOUT="${KB_LAYOUT_SPEC%%:*}"; KB_VARIANT="${KB_LAYOUT_SPEC#*:}" ;;
    *)   KB_LAYOUT="$KB_LAYOUT_SPEC"; KB_VARIANT="" ;;
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

# Write well-known public DNS as initial resolv.conf for the installed image.
# DHCP (eth0 inet dhcp) will overwrite this at boot, but it serves as a sane
# fallback if DHCP is slow or the DHCP-provided DNS doesn't work.
# Don't copy the installer's resolv.conf — it contains the vmnet gateway IP
# from the build-time vmnet instance, which may differ at runtime.
printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' > /mnt/etc/resolv.conf

# Bind-mount for chroot
mount -t proc proc /mnt/proc
mount -t sysfs sys /mnt/sys
mount --bind /dev /mnt/dev

# ---------------------------------------------------------------------------
# Install packages
# ---------------------------------------------------------------------------

retry chroot /mnt apk update
retry chroot /mnt apk add openrc linux-lts linux-firmware-none mkinitfs e2fsprogs
retry chroot /mnt apk add \
    chromium chromium-lang xorg-server xinit mesa-dri-gallium mesa-egl mesa-gl mesa-gles \
    mesa-gbm eudev dbus dbus-x11 ttf-freefont ttf-dejavu font-noto-emoji font-liberation \
    xf86-input-libinput agetty util-linux openbox xrandr xdotool setxkbmap \
    pipewire pipewire-pulse wireplumber pipewire-tools alsa-utils alsa-plugins-pulse adwaita-icon-theme \
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

retry chroot /mnt apk add squid dnsmasq proxychains-ng cryptsetup inotify-tools jq python3 \
    v4l-utils nss-tools bash wireguard-tools

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

# Font rendering (match macOS Core Text: no hinting, stem darkening, SF Pro default)
install_config configs/fontconfig-local.conf /mnt/etc/fonts/local.conf

# GTK3 settings (Chromium reads these for its UI chrome font)
mkdir -p /mnt/home/chrome/.config/gtk-3.0
install_config configs/gtk3-settings.ini /mnt/home/chrome/.config/gtk-3.0/settings.ini

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
chroot /mnt addgroup -S render 2>/dev/null || true
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
echo '::once:/usr/local/bin/config-agent.py' >> /mnt/etc/inittab
echo '::once:/usr/local/bin/resilient-launch.sh su -s /bin/sh chrome -c /usr/local/bin/file-agent.py' >> /mnt/etc/inittab
echo '::once:/usr/local/bin/resilient-launch.sh /usr/local/bin/webcam-agent.py' >> /mnt/etc/inittab
echo '::once:/usr/local/bin/resilient-launch.sh /usr/local/bin/warp-agent.py' >> /mnt/etc/inittab
echo '::once:/usr/local/bin/resilient-launch.sh /usr/local/bin/wireguard-agent.py' >> /mnt/etc/inittab
echo '::once:/usr/local/bin/resilient-launch.sh su -s /bin/sh chrome -c /usr/local/bin/keyboard-agent.py' >> /mnt/etc/inittab
echo '::once:/usr/local/bin/resilient-launch.sh su -s /bin/sh chrome -c /usr/local/bin/cjk-input-agent.py' >> /mnt/etc/inittab

install_config scripts/debug.sh        /mnt/root/debug.sh          755
install_config scripts/root-profile.sh /mnt/root/.profile

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

# ---------------------------------------------------------------------------
# macOS fonts (shared from host via VirtioFS for web rendering parity)
# ---------------------------------------------------------------------------

mkdir -p /mnt/usr/share/fonts/macos
for tag in fonts userfonts; do
    FMNT="/tmp/$tag"
    mkdir -p "$FMNT"
    mount -t virtiofs "$tag" "$FMNT" 2>/dev/null || continue
    # Copy TrueType, OpenType, and TrueType Collection fonts (skip .dfont — Linux can't use them)
    find "$FMNT" -type f \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' \) \
        -exec cp {} /mnt/usr/share/fonts/macos/ \;
    umount "$FMNT"
done
MACOS_FONT_COUNT=$(find /mnt/usr/share/fonts/macos/ -type f 2>/dev/null | wc -l)
echo "Copied $MACOS_FONT_COUNT macOS font files"

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
install_config scripts/webcam-agent.py      /mnt/usr/local/bin/webcam-agent.py      755
install_config scripts/warp-agent.py        /mnt/usr/local/bin/warp-agent.py        755
install_config scripts/wireguard-agent.py  /mnt/usr/local/bin/wireguard-agent.py  755
install_config scripts/keyboard-agent.py    /mnt/usr/local/bin/keyboard-agent.py    755
install_config scripts/cjk-input-agent.py  /mnt/usr/local/bin/cjk-input-agent.py  755
install_config scripts/routing-socks.py     /mnt/usr/local/bin/routing-socks.py     755
install_config scripts/config-agent.py      /mnt/usr/local/bin/config-agent.py      755
install_config scripts/cdp-agent.py         /mnt/usr/local/bin/cdp-agent.py         755
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
# Phishing guard extension
# ---------------------------------------------------------------------------

mkdir -p /mnt/opt/bromure/extensions/phishing-guard
for f in manifest.json background.js content.js popup.html popup.css popup.js blocked.html blocked.css blocked.js; do
    [ -f "$SCRIPT_DIR/extensions/phishing-guard/$f" ] && \
        cp "$SCRIPT_DIR/extensions/phishing-guard/$f" /mnt/opt/bromure/extensions/phishing-guard/
done

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
for f in manifest.json background.js content.js; do
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

# Trace extension
mkdir -p /mnt/opt/bromure/extensions/trace
for f in manifest.json background.js form-capture.js; do
    [ -f "$SCRIPT_DIR/extensions/trace/$f" ] && \
        cp "$SCRIPT_DIR/extensions/trace/$f" /mnt/opt/bromure/extensions/trace/
done

# Native messaging hosts (link sender + file picker + trace)
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
retry apk add unzip
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
# v4l2loopback (virtual webcam device, pre-built for linux-lts)
# ---------------------------------------------------------------------------

KVER=$(ls /mnt/lib/modules/)
if [ -f "$SCRIPT_DIR/v4l2loopback/v4l2loopback.ko.gz" ]; then
    mkdir -p "/mnt/lib/modules/$KVER/extra"
    cp "$SCRIPT_DIR/v4l2loopback/v4l2loopback.ko.gz" "/mnt/lib/modules/$KVER/extra/"
    gunzip "/mnt/lib/modules/$KVER/extra/v4l2loopback.ko.gz"
    chroot /mnt depmod "$KVER"
    echo "V4L2LOOPBACK_INSTALLED_OK"
else
    echo "Warning: v4l2loopback.ko not found — webcam sharing will not work"
fi

# ---------------------------------------------------------------------------
# Kernel and initramfs
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# RTC PL031 (Virtualization.framework virtual RTC, pre-built for linux-lts)
# ---------------------------------------------------------------------------

KVER=$(ls /mnt/lib/modules/)
if [ -f "$SCRIPT_DIR/rtc-pl031/rtc-pl031.ko.gz" ]; then
    mkdir -p "/mnt/lib/modules/$KVER/extra"
    cp "$SCRIPT_DIR/rtc-pl031/rtc-pl031.ko.gz" "/mnt/lib/modules/$KVER/extra/"
    gunzip "/mnt/lib/modules/$KVER/extra/rtc-pl031.ko.gz"
    chroot /mnt depmod "$KVER"
    echo "rtc-pl031" >> /mnt/etc/modules
    echo "RTC_PL031_INSTALLED_OK"
elif [ -f "$SCRIPT_DIR/rtc-pl031/rtc-pl031.ko" ]; then
    mkdir -p "/mnt/lib/modules/$KVER/extra"
    cp "$SCRIPT_DIR/rtc-pl031/rtc-pl031.ko" "/mnt/lib/modules/$KVER/extra/"
    chroot /mnt depmod "$KVER"
    echo "rtc-pl031" >> /mnt/etc/modules
    echo "RTC_PL031_INSTALLED_OK"
else
    echo "Warning: rtc-pl031.ko not found — guest clock will need manual sync"
fi

install_config configs/mkinitfs.conf /mnt/etc/mkinitfs/mkinitfs.conf
chroot /mnt ls /etc/mkinitfs/features.d/ 2>/dev/null || true
chroot /mnt sh -c 'mkinitfs $(ls /lib/modules/)'

# Kernel modules
cat "$SCRIPT_DIR/configs/modules" >> /mnt/etc/modules

# ---------------------------------------------------------------------------
# Swap file (1 GB)
# ---------------------------------------------------------------------------

dd if=/dev/zero of=/mnt/swap bs=1M count=1024
chmod 600 /mnt/swap
mkswap /mnt/swap
chroot /mnt rc-update add swap boot

# ---------------------------------------------------------------------------
# Cleanup and finish
# ---------------------------------------------------------------------------

umount /mnt/dev
umount /mnt/sys
umount /mnt/proc
umount /mnt

echo SANDBOX_SETUP_DONE
