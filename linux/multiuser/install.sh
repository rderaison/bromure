#!/bin/bash
# linux/multiuser/install.sh [--bind ADDR] [--port N]: install the multi-user
# Bromure server (root). Binaries and the Swift runtime under
# /usr/local/lib/bromure-ac, the guest image under /var/lib/bromure-ac-image,
# the units, the gateway's account `bromure`; starts the gateway. Users come
# next: `bromure-ac admin add <name>`.
# Needs a release build (linux/ACLinux: swift build -c release), Firecracker
# (linux/firecracker/build.sh) and the baked image, from the invoking user.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "install.sh: run as root (sudo)" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
SRCUSER=${SUDO_USER:-root}; SRCHOME=$(getent passwd "$SRCUSER" | cut -d: -f6)
BIN=${BROMURE_BIN:-$ROOT/linux/ACLinux/.build/release/bromure-ac}
FC=${BROMURE_FIRECRACKER:-$SRCHOME/.local/share/bromure-ac/bin/firecracker}
IMAGE=${BROMURE_AC_IMAGE:-$SRCHOME/.local/share/bromure-ac/image-amd64}
BIND=0.0.0.0; PORT=2222
while [ $# -gt 0 ]; do case $1 in --bind) BIND=$2; shift 2;; --port) PORT=$2; shift 2;; *) echo "unknown $1" >&2; exit 2;; esac; done
for f in "$BIN" "$FC" "$IMAGE/base.img" "$IMAGE/vmlinuz"; do [ -e "$f" ] || { echo "install.sh: missing $f" >&2; exit 1; }; done

L=/usr/local/lib/bromure-ac
install -d -m 755 $L/bin $L/lib $L/vm-setup
install -m 755 "$BIN" $L/bin/bromure-ac.new && mv -f $L/bin/bromure-ac.new $L/bin/bromure-ac
install -m 755 "$FC" $L/bin/firecracker.new && mv -f $L/bin/firecracker.new $L/bin/firecracker
install -m 644 "$ROOT/Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py" $L/vm-setup/
# The Swift runtime the binary was linked against (a static stdlib build
# doesn't link Foundation on this toolchain).
ldd "$BIN" | awk '/=> \// {print $3}' | grep -E '/swift/|libFoundation|libswift|lib_FoundationICU|libdispatch|libBlocksRuntime' \
  | while read -r so; do install -m 644 "$so" $L/lib/; done
ln -sfn $L/bin/bromure-ac /usr/local/bin/bromure-ac

# The baked image, read-only for every user (sparse copy, ~1 s).
install -d -m 755 /var/lib/bromure-ac-image
for f in base.img vmlinuz initrd.img cmdline; do
  [ -e "$IMAGE/$f" ] && cp --sparse=always "$IMAGE/$f" /var/lib/bromure-ac-image/$f.new && mv -f /var/lib/bromure-ac-image/$f.new /var/lib/bromure-ac-image/$f
done
chmod 644 /var/lib/bromure-ac-image/*
install -d -m 755 /var/lib/bromure-ac /run/bromure-ac/sock

getent group bromure >/dev/null || groupadd --system bromure
getent passwd bromure >/dev/null || useradd --system --gid bromure --no-create-home --home-dir /var/lib/bromure-gw \
  --shell /usr/sbin/nologin --comment "Bromure SSH gateway" bromure

install -m 644 "$HERE/bromure-ac@.service" "$HERE/bromure-ac@.socket" "$HERE/bromure-gw.service" /etc/systemd/system/
install -d -m 700 -o bromure -g bromure /var/lib/bromure-gw
[ -e /var/lib/bromure-gw/gateway.json ] || { printf '{"port": %s, "bindAddress": "%s", "codeLogin": true, "socketDir": "/run/bromure-ac/sock"}\n' "$PORT" "$BIND" > /var/lib/bromure-gw/gateway.json; chown bromure:bromure /var/lib/bromure-gw/gateway.json; chmod 600 /var/lib/bromure-gw/gateway.json; }
systemctl daemon-reload
systemctl enable --now bromure-gw.service
systemctl restart bromure-gw.service
echo "installed; gateway: $(systemctl is-active bromure-gw.service). Add users: bromure-ac admin add <name>"
