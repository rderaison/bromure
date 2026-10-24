#!/usr/bin/env bash
# Install Bromure Sidecar on Linux, per user, with no root.
#
#   installer/linux/install.sh [path/to/bromure-sidecar]
#
# With no argument it builds from this checkout (needs Go), otherwise it
# installs the binary given -- which is how the release tarball uses it.
#
# Per user on purpose: the Sidecar runs the user's coding agents with the
# user's credentials and the user's git identity. A system service would run
# them as somebody else, and every agent path (~/.claude, ~/.codex, the
# worktrees under ~/.bromure) belongs to a person.
set -euo pipefail

bin_dir="${BROMURE_BIN_DIR:-$HOME/.local/bin}"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
here="$(cd "$(dirname "$0")" && pwd)"
unit="bromure-sidecar.service"

src="${1:-}"
if [ -z "$src" ]; then
    root="$(cd "$here/../.." && pwd)"
    command -v go >/dev/null 2>&1 || {
        echo "install: no Go toolchain, and no binary given." >&2
        echo "          installer/linux/install.sh /path/to/bromure-sidecar" >&2
        exit 1
    }
    echo "== building from $root"
    src="$root/dist/install/bromure-sidecar"
    mkdir -p "$(dirname "$src")"
    ( cd "$root" && CGO_ENABLED=0 go build -trimpath -o "$src" ./cmd/bromure-sidecar )
fi
[ -x "$src" ] || { echo "install: $src is not an executable" >&2; exit 1; }

echo "== installing to $bin_dir"
mkdir -p "$bin_dir"
# Replace by rename, so a running daemon keeps its open inode and nothing is
# ever a half-written file on PATH.
install -m 0755 "$src" "$bin_dir/.bromure-sidecar.new"
mv -f "$bin_dir/.bromure-sidecar.new" "$bin_dir/bromure-sidecar"

have_systemd=0
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    have_systemd=1
fi

if [ "$have_systemd" = 1 ]; then
    echo "== installing the user service to $unit_dir"
    mkdir -p "$unit_dir"
    install -m 0644 "$here/$unit" "$unit_dir/$unit"
    # `systemctl --user` needs the user bus. On a bare SSH login without
    # XDG_RUNTIME_DIR set, every call fails with "Failed to connect to bus",
    # which reads as a broken install rather than a missing variable.
    : "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
    export XDG_RUNTIME_DIR
    if systemctl --user daemon-reload 2>/dev/null; then
        systemctl --user enable --now "$unit"
        echo "== started; systemctl --user status $unit"
    else
        echo "!! the user bus isn't reachable from this shell."
        echo "   Installed the unit anyway. From a real login session, run:"
        echo "     systemctl --user daemon-reload && systemctl --user enable --now $unit"
    fi
else
    echo "!! no systemd here. Run the daemon yourself:"
    echo "     $bin_dir/bromure-sidecar serve &"
fi

cat <<EOF

Installed: $bin_dir/bromure-sidecar

HEADLESS SERVERS: enable lingering, or the service stops when you log out
and never starts at boot. systemd only keeps a user manager running for a
user who has a session, unless lingering is on:

    sudo loginctl enable-linger $(id -un)

Check it with: loginctl show-user $(id -un) -p Linger   (want Linger=yes)

Next:
    bromure-sidecar status            # where this machine stands
    bromure-sidecar enroll            # prints a URL to open on your laptop
    bromure-sidecar sessions          # the agent sessions on this machine
    bromure-sidecar logs -f           # follow the daemon log

If \$HOME/.local/bin isn't on your PATH, add it:
    echo 'export PATH="\$HOME/.local/bin:\$PATH"' >> ~/.bashrc
EOF
