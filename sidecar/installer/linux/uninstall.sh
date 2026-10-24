#!/usr/bin/env bash
# Remove Bromure Sidecar from this user account.
#
#   installer/linux/uninstall.sh [--purge]
#
# --purge also deletes the data directory, which holds the SSH host key, the
# device record and sessions.json. Without it the data is left alone, so
# reinstalling returns to the same machine identity in your account.
set -euo pipefail

bin_dir="${BROMURE_BIN_DIR:-$HOME/.local/bin}"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
unit="bromure-sidecar.service"
data="${BROMURE_SIDECAR_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/BromureSidecar}"
purge=0
[ "${1:-}" = "--purge" ] && purge=1

: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
export XDG_RUNTIME_DIR

# Agents first, and through the daemon: it stops the pane host, which is
# what the agents actually live in. Killing the daemon alone would leave
# them running with nothing to report to.
if [ -x "$bin_dir/bromure-sidecar" ]; then
    echo "== stopping agents and the pane host"
    "$bin_dir/bromure-sidecar" shutdown 2>/dev/null || true
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now "$unit" 2>/dev/null || true
    rm -f "$unit_dir/$unit"
    systemctl --user daemon-reload 2>/dev/null || true
fi
rm -f "$bin_dir/bromure-sidecar"

if [ "$purge" = 1 ]; then
    echo "== removing $data"
    rm -rf "$data"
else
    echo "== kept $data (use --purge to remove the keys and sessions too)"
fi
echo "done. Lingering, if you enabled it, is still on:"
echo "  sudo loginctl disable-linger $(id -un)"
