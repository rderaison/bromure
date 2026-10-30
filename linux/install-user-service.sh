#!/bin/bash
# install-user-service.sh: install bromure-ac as a systemd user service, without root.
#
#   - the binary         -> ~/.local/bin/bromure-ac        (from linux/ACLinux, release build)
#   - the guest agent    -> ~/.local/share/bromure-ac/vm-setup/bromure-agentd.py
#   - the unit           -> ~/.config/systemd/user/bromure-ac.service, then enabled and started
#
# Lingering: a user service runs only while the user has a session, unless lingering is on.
# For a headless host that must run after boot with nobody logged in, enable it once (as root):
#     loginctl enable-linger <user>
# This script only reports whether it's on.
#
# Prerequisites it doesn't change:
#   - /dev/kvm, /dev/vhost-vsock and /dev/vhost-net usable by this user (the vhost udev rule,
#     or kvm group membership). A user unit can't add groups.
#   - the baked image in ~/.local/share/bromure-ac/image-amd64 (`bromure-ac image bake`) or
#     --image DIR, and passt.
#
# Usage: install-user-service.sh [--image DIR] [--no-start] [--uninstall]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
BIN=$HOME/.local/bin/bromure-ac
AGENTD=$DATA/bromure-ac/vm-setup/bromure-agentd.py
IMAGE=$DATA/bromure-ac/image-amd64
START=1
while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE=$2; shift 2 ;;
    --no-start) START=0; shift ;;
    --uninstall)
      systemctl --user disable --now bromure-ac.service 2>/dev/null || true
      rm -f "$UNIT_DIR/bromure-ac.service" "$BIN"
      systemctl --user daemon-reload
      echo "bromure-ac user service removed (VM state in ${XDG_STATE_HOME:-$HOME/.local/state}/bromure-ac kept)"
      exit 0 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" != 0 ] || { echo "run as the user who will own the VMs, not root" >&2; exit 1; }

[ -f "$HOME/.local/share/swiftly/env.sh" ] && . "$HOME/.local/share/swiftly/env.sh"
swift build --package-path "$ROOT/linux/ACLinux" -c release --product bromure-ac
mkdir -p "$(dirname "$BIN")" "$(dirname "$AGENTD")" "$UNIT_DIR"
install -m 0755 "$(swift build --package-path "$ROOT/linux/ACLinux" -c release --show-bin-path)/bromure-ac" "$BIN"
install -m 0644 "$ROOT/Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py" "$AGENTD"
sed -e "s|@BIN@|$BIN|" -e "s|@IMAGE@|$IMAGE|" -e "s|@AGENTD@|$AGENTD|" \
  "$ROOT/linux/systemd/bromure-ac.service" > "$UNIT_DIR/bromure-ac.service"
systemctl --user daemon-reload
if [ $START = 1 ]; then systemctl --user enable --now bromure-ac.service; else systemctl --user enable bromure-ac.service; fi
echo "installed: $UNIT_DIR/bromure-ac.service -> $BIN"
[ -d "$IMAGE" ] || echo "note: no image at $IMAGE yet (bromure-ac image bake)"
[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" = yes ] \
  || echo "note: lingering is off: the service stops when you log out (root: loginctl enable-linger $(id -un))"
[ -w /dev/vhost-vsock ] || echo "note: /dev/vhost-vsock isn't writable by $(id -un): VMs won't start until the vhost udev rule is in place"
