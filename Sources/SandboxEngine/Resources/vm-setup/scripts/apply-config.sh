#!/bin/sh
# apply-config.sh — Configure services and write chrome-env.
#
# Called by the host over the serial console after the VM has booted.
# All configuration is passed via environment variables:
#
#   DARK_MODE=1           Force dark mode in Chromium
#   USE_PROXY=1           Route traffic through local squid proxy
#   DISABLE_GPU=1         Disable GPU acceleration
#   DISABLE_WEBGL=1       Disable WebGL and 3D APIs
#   PHISHING_GUARD=1      Load phishing-guard extension
#   PROFILE_DIR=<path>    Use a custom Chromium user-data-dir
#   RESTORE_SESSION=1     Restore tabs from previous session
#   CHROME_URL=<url>      Home page / initial URL
#   SWAP_CMD_CTRL=1       Remap Cmd↔Ctrl keys
#   FILE_TRANSFER=1       Enable vsock file transfer agent
#   CLIPBOARD=1           Enable clipboard sharing via SPICE agent
#   BLOCK_MALWARE=1       Use Cloudflare security DNS (1.1.1.2)
#   AD_BLOCKING=1         Enable Pi-hole ad blocking
#   ENABLE_WARP=1         Route traffic through Cloudflare WARP
#   LINK_SENDER=1         Enable "Send link to other session" context menu
#   WEBCAM=1              Enable webcam sharing from host via vsock + v4l2loopback
#   AUDIO=1               Enable audio output (start PipeWire in the guest)
#   MICROPHONE=1          Enable microphone sharing from host via virtio-snd
#   CUSTOM_CAS=N          Number of custom root CAs in /tmp/bromure/custom-cas/
#   PROFILE_DISK=1        Mount virtio-fs share and loop-mount profile.img
#   PROFILE_MOUNT=<path>  Mount point for the profile disk (e.g. /home/chrome/.UUID)
#   PROFILE_DISK_KEY=<key> LUKS encryption key (omit for unencrypted)

ENVFILE="/tmp/bromure/chrome-env"

# Escape a value for safe single-quoting in chrome-env.
sh_escape() { printf "'" ; printf '%s' "$1" | sed "s/'/'\\\\''/g" ; printf "'" ; }

# --- Wait for on-boot.sh to finish (dbus startup, etc.) ---

# --- Mount profile disk (persistent profiles only) ---

if [ "$PROFILE_DISK" = "1" ] && [ -n "$PROFILE_MOUNT" ]; then
    mount -t virtiofs share /mnt/share
    DISK_PATH="/mnt/share/profile.img"

    if [ -n "$PROFILE_DISK_KEY" ]; then
        # Encrypted: LUKS format (if new), unlock, and mount via loop
        LOOP=$(losetup -f) && losetup $LOOP "$DISK_PATH"
        echo -n "$PROFILE_DISK_KEY" | cryptsetup isLuks $LOOP 2>/dev/null || \
            echo -n "$PROFILE_DISK_KEY" | cryptsetup luksFormat --batch-mode $LOOP -
        echo -n "$PROFILE_DISK_KEY" | cryptsetup open $LOOP profile_data -
        mkdir -p "$PROFILE_MOUNT"
        blkid /dev/mapper/profile_data >/dev/null 2>&1 || mkfs.ext4 -q /dev/mapper/profile_data
        mount /dev/mapper/profile_data "$PROFILE_MOUNT"
        chown chrome:chrome "$PROFILE_MOUNT"
    else
        # Unencrypted: format if new, then loop-mount
        mkdir -p "$PROFILE_MOUNT"
        blkid "$DISK_PATH" >/dev/null 2>&1 || mkfs.ext4 -q "$DISK_PATH"
        mount -o loop "$DISK_PATH" "$PROFILE_MOUNT"
        chown chrome:chrome "$PROFILE_MOUNT"
    fi
fi

# --- Build EXTRA_FLAGS for Chromium ---

EXTRA_FLAGS=""
ENABLE_FEATURES=""

[ "$DARK_MODE" = "1" ] && \
    EXTRA_FLAGS="$EXTRA_FLAGS --force-dark-mode" && \
    ENABLE_FEATURES="${ENABLE_FEATURES:+$ENABLE_FEATURES,}WebContentsForceDark"

if [ -n "$PROXY_HOST" ] && [ -n "$PROXY_PORT" ]; then
    if [ -n "$PROXY_USERNAME" ] && [ -n "$PROXY_PASSWORD" ]; then
        EXTRA_FLAGS="$EXTRA_FLAGS --proxy-server=http://$PROXY_USERNAME:$PROXY_PASSWORD@$PROXY_HOST:$PROXY_PORT"
    else
        EXTRA_FLAGS="$EXTRA_FLAGS --proxy-server=http://$PROXY_HOST:$PROXY_PORT"
    fi
else
    # Always route through internal squid proxy (required for dynamic
    # WARP toggling — squid is restarted with/without proxychains).
    EXTRA_FLAGS="$EXTRA_FLAGS --proxy-server=http://127.0.0.1:3128"
fi

[ "$DISABLE_GPU" = "1" ] && \
    EXTRA_FLAGS="$EXTRA_FLAGS --disable-gpu"

[ "$DISABLE_WEBGL" = "1" ] && \
    EXTRA_FLAGS="$EXTRA_FLAGS --disable-webgl --disable-3d-apis"

EXTENSIONS=""
[ "$PHISHING_GUARD" = "1" ] && \
    EXTENSIONS="${EXTENSIONS:+$EXTENSIONS,}/opt/bromure/extensions/phishing-guard"
[ "$LINK_SENDER" = "1" ] && \
    EXTENSIONS="${EXTENSIONS:+$EXTENSIONS,}/opt/bromure/extensions/link-sender"
if [ "$FILE_TRANSFER" = "1" ]; then
    EXTRA_FLAGS="$EXTRA_FLAGS --silent-debugger-extension-api"
    EXTENSIONS="${EXTENSIONS:+$EXTENSIONS,}/opt/bromure/extensions/file-picker"
fi
# WebRTC block extension: loaded only when both webcam and microphone are off
if [ "$WEBCAM" != "1" ] && [ "$MICROPHONE" != "1" ]; then
    EXTENSIONS="${EXTENSIONS:+$EXTENSIONS,}/opt/bromure/extensions/webrtc-block"
fi
if [ -n "$EXTENSIONS" ]; then
    EXTRA_FLAGS="$EXTRA_FLAGS --load-extension=$EXTENSIONS"
fi

[ -n "$PROFILE_DIR" ] && \
    EXTRA_FLAGS="$EXTRA_FLAGS --user-data-dir=$PROFILE_DIR" && \
    ENABLE_FEATURES="${ENABLE_FEATURES:+$ENABLE_FEATURES,}WebAuthenticationNewPasskeyUI"

[ "$RESTORE_SESSION" = "1" ] && \
    EXTRA_FLAGS="$EXTRA_FLAGS --restore-last-session"

# Media device access: run audio in-process (out-of-process can't find PipeWire).
DISABLE_FEATURES=""
[ "$MICROPHONE" = "1" ] && \
    DISABLE_FEATURES="${DISABLE_FEATURES:+$DISABLE_FEATURES,}AudioServiceOutOfProcess"

# Disable WebRTC when both webcam and microphone are off
if [ "$WEBCAM" != "1" ] && [ "$MICROPHONE" != "1" ]; then
    EXTRA_FLAGS="$EXTRA_FLAGS --force-webrtc-ip-handling-policy=disable_non_proxied_udp"
    EXTRA_FLAGS="$EXTRA_FLAGS --enforce-webrtc-ip-permission-check"
fi

[ -n "$ENABLE_FEATURES" ] && \
    EXTRA_FLAGS="$EXTRA_FLAGS --enable-features=$ENABLE_FEATURES"
[ -n "$DISABLE_FEATURES" ] && \
    EXTRA_FLAGS="$EXTRA_FLAGS --disable-features=$DISABLE_FEATURES"

# --- Write dynamic Chrome policy (media capture, WebRTC) ---

POLICY_DIR="/etc/chromium/policies/managed"
mkdir -p "$POLICY_DIR"
SESSION_POLICY="$POLICY_DIR/session.json"
echo "{" > "$SESSION_POLICY"
if [ "$WEBCAM" = "1" ]; then
    echo '  "VideoCaptureAllowed": true,' >> "$SESSION_POLICY"
else
    echo '  "VideoCaptureAllowed": false,' >> "$SESSION_POLICY"
fi
if [ "$MICROPHONE" = "1" ]; then
    echo '  "AudioCaptureAllowed": true' >> "$SESSION_POLICY"
else
    echo '  "AudioCaptureAllowed": false' >> "$SESSION_POLICY"
fi
if [ "$WEBCAM" != "1" ] && [ "$MICROPHONE" != "1" ]; then
    # Replace last line to add comma, then add WebRTC policies
    sed -i '$ s/$/,/' "$SESSION_POLICY"
    echo '  "WebRtcIPHandlingPolicy": "disable_non_proxied_udp",' >> "$SESSION_POLICY"
    echo '  "WebRtcUdpPortRange": "0-0",' >> "$SESSION_POLICY"
    echo '  "WebRtcLocalIpsAllowedUrls": []' >> "$SESSION_POLICY"
fi
echo "}" >> "$SESSION_POLICY"

# --- Write chrome-env ---

: > "$ENVFILE"
[ -n "$EXTRA_FLAGS" ] && printf 'EXTRA_FLAGS=%s\n' "$(sh_escape "$EXTRA_FLAGS")" >> "$ENVFILE"
# Don't open the home page when restoring a previous session
[ "$RESTORE_SESSION" != "1" ] && printf 'CHROME_URL=%s\n' "$(sh_escape "${CHROME_URL:-about:blank}")" >> "$ENVFILE"
[ "$SWAP_CMD_CTRL" = "1" ] && echo "SWAP_CMD_CTRL=1" >> "$ENVFILE"
[ "$FILE_TRANSFER" = "1" ] && echo "FILE_TRANSFER=1" >> "$ENVFILE"
[ "$CLIPBOARD" = "1" ] && echo "CLIPBOARD=1" >> "$ENVFILE"
[ "$LINK_SENDER" = "1" ] && echo "LINK_SENDER=1" >> "$ENVFILE"
if [ "$WEBCAM" = "1" ]; then
    echo "WEBCAM=1" >> "$ENVFILE"
    [ -n "$WEBCAM_WIDTH" ] && echo "WEBCAM_WIDTH=$WEBCAM_WIDTH" >> "$ENVFILE"
    [ -n "$WEBCAM_HEIGHT" ] && echo "WEBCAM_HEIGHT=$WEBCAM_HEIGHT" >> "$ENVFILE"
fi
[ "$AUDIO" = "1" ] && echo "AUDIO=1" >> "$ENVFILE"
[ "$MICROPHONE" = "1" ] && echo "MICROPHONE=1" >> "$ENVFILE"

# --- Background: Webcam setup (modprobe + device wait) ---

if [ "$WEBCAM" = "1" ]; then
    (
        modprobe v4l2loopback video_nr=0 card_label="Bromure Camera" exclusive_caps=1 2>/dev/null
        for i in $(seq 1 30); do [ -e /dev/video0 ] && break; sleep 0.1; done
        chown root:video /dev/video0 2>/dev/null
        chmod 660 /dev/video0 2>/dev/null
    ) &
fi

# --- Background: Custom root CAs ---

if [ -n "$CUSTOM_CAS" ] && [ -d /tmp/bromure/custom-cas ]; then
    (
        for f in /tmp/bromure/custom-cas/*.crt; do
            [ -f "$f" ] && cp "$f" /usr/local/share/ca-certificates/
        done
        update-ca-certificates 2>/dev/null
        mkdir -p /home/chrome/.pki/nssdb
        for f in /usr/local/share/ca-certificates/*.crt; do
            [ -f "$f" ] && certutil -d sql:/home/chrome/.pki/nssdb -A -t "C,," \
                -n "$(basename "$f" .crt)" -i "$f" 2>/dev/null
        done
        chown -R chrome:chrome /home/chrome/.pki
    ) &
fi

# --- Configure DNS/proxy services ---

if [ "$BLOCK_MALWARE" = "1" ]; then
    sed -i 's/^server=1\.1\.1\.1/server=1.1.1.2/' /etc/dnsmasq.d/pihole.conf
    sed -i 's/^server=1\.0\.0\.1/server=1.0.0.2/' /etc/dnsmasq.d/pihole.conf
fi

# Start dnsmasq for DNS filtering (ad-blocking, malware blocking, or WARP)
if [ "$AD_BLOCKING" = "1" ] || [ "$ENABLE_WARP" = "1" ] || [ "$BLOCK_MALWARE" = "1" ]; then
    dnsmasq -C /etc/dnsmasq.d/pihole.conf
fi

# Configure squid DNS: use dnsmasq when ad-blocking or malware-blocking is on
if [ "$AD_BLOCKING" = "1" ] || [ "$BLOCK_MALWARE" = "1" ]; then
    sed -i 's/^dns_nameservers.*/dns_nameservers 127.0.0.1/' /etc/squid/squid.conf
else
    sed -i '/^dns_nameservers/d' /etc/squid/squid.conf
fi

# Start routing SOCKS5 proxy on :40001 + squid through proxychains.
# routing-socks switches between warp-svc (:40000) and direct per-connection.
# Squid is never restarted.
if [ -z "$PROXY_HOST" ] || [ -z "$PROXY_PORT" ]; then
    /usr/local/bin/routing-socks.py &
    proxychains4 -q -f /etc/proxychains/proxychains.conf squid -N -f /etc/squid/squid.conf &
fi

# --- Seed default Chromium preferences for persistent profiles ---

if [ -n "$PROFILE_DIR" ]; then
    PREFS_DIR="$PROFILE_DIR/Default"
    if [ ! -f "$PREFS_DIR/Preferences" ]; then
        mkdir -p "$PREFS_DIR"
        cp /home/chrome/.config/chromium/Default/Preferences "$PREFS_DIR/Preferences"
        chown -R chrome:chrome "$PROFILE_DIR"
    fi

    # Clean up crash state so Chromium doesn't show "restore pages?" bubble
    PREFS="$PROFILE_DIR/Default/Preferences"
    if [ -f "$PREFS" ]; then
        sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "$PREFS"
        sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "$PREFS"
    fi
fi

# --- Wait for background tasks, then signal xinitrc ---

wait
touch /tmp/bromure/chrome-ready
echo APPLY_CONFIG_DONE
