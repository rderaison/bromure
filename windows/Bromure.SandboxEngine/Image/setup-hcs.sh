#!/bin/bash
# Bromure HCS guest setup — runs once at bake time inside a transient VM.
# Produces an image that boots into:
#   - 9p mounts for /home/bromure overlay, CA cert, and shared folders
#   - update-ca-certificates (from the certs share)
#   - weston with rdp-backend.so listening on hvsocket port 3389
#   - kitty as the weston session client
#   - hvsocket boot-signal byte on port 50100 once everything is up
#
# This script REPLACES setup-wsl.sh. It is shipped as an embedded resource
# in Bromure.SandboxEngine.dll and pulled out at bake time.
#
# It runs inside a transient HCS VM that has the source rootfs mounted
# at / and a host-side directory for the bake artefacts mounted via 9p.

set -euo pipefail
DONE_MARKER="SANDBOX_SETUP_DONE"
FAIL_MARKER="SANDBOX_SETUP_FAILED"
trap 'echo "$FAIL_MARKER" >&2' ERR

GUEST_USER="${GUEST_USER:-bromure}"
GUEST_UID="${GUEST_UID:-1000}"

# 1) Base packages.
# - kitty: the terminal we render through RDP
# - weston: Wayland compositor with rdp-backend support
# - xwayland: X11 fallback for the agent CLI's that aren't pure Wayland
# - microsoft/wslg userland (built from source below) provides the
#   weston-rdp shell-mode integration; for this spike we use the
#   stock weston rdp-backend, which gives a single-RDP-session
#   whole-desktop view rather than seamless windowing.
# - ca-certificates + update-ca-certificates: HTTPS_PROXY MITM trust
# - jq + nodejs + gh: agent toolchain (matches setup-wsl.sh)
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    ca-certificates curl jq \
    kitty xterm fonts-jetbrains-mono \
    weston xwayland \
    libfreerdp2-2 libwinpr2-2 \
    nodejs npm \
    gh \
    systemd-sysv \
    9mount \
    sudo

# 2) bromure user, sudoers NOPASSWD (matches WSL bake).
if ! id -u "$GUEST_USER" >/dev/null 2>&1; then
    useradd -m -u "$GUEST_UID" -s /bin/bash "$GUEST_USER"
fi
echo "$GUEST_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/90-bromure
chmod 0440 /etc/sudoers.d/90-bromure

# 3) Pre-create dirs the per-session shares mount onto.
install -d -m 0755 -o "$GUEST_USER" -g "$GUEST_USER" \
    "/home/$GUEST_USER/.config/kitty"
install -d -m 0755 /usr/local/share/ca-certificates/bromure
install -d -m 0755 /mnt/bromure-overlay
install -d -m 0755 /mnt/bromure-certs

# 4) Boot-time 9p mount unit. Reads the share-port-map file the host
# stages alongside the VHDX (TBD wire) and mounts each tag at the
# right place. For the spike we hardcode the well-known shares
# (overlay@50001, certs@50002, additional shares@50003+).
cat > /etc/systemd/system/bromure-overlay-mount.service <<'EOF'
[Unit]
Description=Mount Bromure home-overlay 9p share
After=systemd-modules-load.service
Wants=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/modprobe 9p
ExecStartPre=/sbin/modprobe 9pnet_virtio
ExecStartPre=/sbin/modprobe hv_sock
ExecStart=/bin/mount -t 9p -o trans=hyperv,port=50001,version=9p2000.L,access=client bromure-overlay /mnt/bromure-overlay
ExecStop=/bin/umount /mnt/bromure-overlay

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/bromure-certs-mount.service <<'EOF'
[Unit]
Description=Mount Bromure CA certs 9p share
After=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/modprobe 9p
ExecStartPre=/sbin/modprobe 9pnet_virtio
ExecStartPre=/sbin/modprobe hv_sock
ExecStart=/bin/mount -t 9p -o trans=hyperv,port=50002,version=9p2000.L,access=client bromure-certs /usr/local/share/ca-certificates/bromure
ExecStop=/bin/umount /usr/local/share/ca-certificates/bromure

[Install]
WantedBy=multi-user.target
EOF

# 5) Apply home overlay + install CA certs.
cat > /usr/local/sbin/bromure-overlay-apply <<'EOF'
#!/bin/bash
set -euo pipefail
GUEST_USER="${GUEST_USER:-bromure}"
SRC=/mnt/bromure-overlay
DST="/home/$GUEST_USER"
if [ -d "$SRC" ] && [ -n "$(ls -A "$SRC" 2>/dev/null)" ]; then
    cp -a "$SRC"/. "$DST/"
    chown -R "$GUEST_USER:$GUEST_USER" "$DST"
    if [ -f "$DST/.bromure-env" ]; then
        install -m 0644 "$DST/.bromure-env" /etc/profile.d/bromure-env.sh
    fi
fi
exit 0
EOF
chmod 0755 /usr/local/sbin/bromure-overlay-apply

cat > /etc/systemd/system/bromure-overlay-apply.service <<'EOF'
[Unit]
Description=Apply Bromure home overlay
After=bromure-overlay-mount.service
Requires=bromure-overlay-mount.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/bromure-overlay-apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/bromure-ca-install.service <<'EOF'
[Unit]
Description=Install Bromure CA certs and refresh trust store
After=bromure-certs-mount.service
Requires=bromure-certs-mount.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/update-ca-certificates
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 6) weston-rdp listener. Replaces WSLg.
# We expose weston's rdp-backend on hvsocket port 3389 so mstsc.exe
# (embedded in the WPF shell via AxMSTSCLib) can connect.
#
# For the spike we use the stock weston rdp-backend in "whole desktop"
# mode — kitty fullscreen inside one RDP session. RAIL/seamless
# windowing is a TODO that requires the WSLg-built weston with
# rdp-shell-mode + a Windows-side mstsc shim. The bake artefact list
# already includes microsoft/wslg sources but we don't apply them here
# yet.
mkdir -p /etc/weston
cat > /etc/weston/weston.ini <<'EOF'
[core]
backend=rdp-backend.so
shell=desktop-shell.so
idle-time=0

[rdp]
refresh-rate=60
tls-key=
tls-cert=
no-clients-resize=false

[shell]
locking=false
animation=none
panel-position=none
background-color=0xff000000

[autolaunch]
path=/usr/bin/kitty
EOF

cat > /etc/systemd/system/bromure-weston.service <<EOF
[Unit]
Description=Bromure weston RDP backend
After=bromure-overlay-apply.service bromure-ca-install.service
Wants=bromure-overlay-apply.service

[Service]
User=$GUEST_USER
Group=$GUEST_USER
Environment=XDG_RUNTIME_DIR=/run/user/$GUEST_UID
Environment=WLR_BACKENDS=rdp
ExecStartPre=/bin/install -d -m 0700 -o $GUEST_USER -g $GUEST_USER /run/user/$GUEST_UID
ExecStart=/usr/bin/weston --backend=rdp-backend.so --rdp-port=3389
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# 7) Boot signal — write 0x01 to hvsocket port 50100 once weston is up.
# The Windows host's HcsSession.WaitForBootSignalAsync polls this port.
cat > /usr/local/sbin/bromure-boot-signal <<'EOF'
#!/bin/bash
# Wait for weston to bind 3389, then signal ready.
for _ in $(seq 1 60); do
    if ss -lH "src 3389" 2>/dev/null | grep -q .; then break; fi
    sleep 0.5
done
# hv_sock domain socket: write one byte to port 50100.
exec python3 - <<'PY'
import socket, struct
HV = 34
s = socket.socket(HV, socket.SOCK_STREAM)
# AF_HYPERV listener address: HV_GUID_PARENT to reach the host.
PARENT = bytes.fromhex("a4 2e 7c da d0 3f 48 0c 9c c2 a4 de 20 ab b8 78".replace(" ",""))
PORT = 50100
# Service GUID = port (BE) || FACB-11E6-BD58-64006A7986D3
import struct
svc = struct.pack(">I", PORT) + bytes.fromhex("FACB11E6BD5864006A7986D3")
addr = struct.pack("<HH", HV, 0) + PARENT + svc
s.connect(addr)
s.sendall(b"\x01")
s.close()
PY
EOF
chmod 0755 /usr/local/sbin/bromure-boot-signal

cat > /etc/systemd/system/bromure-boot-signal.service <<'EOF'
[Unit]
Description=Bromure boot-signal handshake
After=bromure-weston.service
Requires=bromure-weston.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/bromure-boot-signal
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 8) Enable everything.
systemctl enable \
    bromure-overlay-mount.service \
    bromure-certs-mount.service \
    bromure-overlay-apply.service \
    bromure-ca-install.service \
    bromure-weston.service \
    bromure-boot-signal.service

# 9) Cleanup apt cache so the VHDX is leaner.
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "$DONE_MARKER"
