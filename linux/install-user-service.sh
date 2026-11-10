#!/bin/bash
# install-user-service.sh: install bromure-ac as a systemd user service, without root.
#
#   - the binary         -> ~/.local/bin/bromure-ac        (from linux/ACLinux, release build)
#   - the guest scripts  -> ~/.local/share/bromure-ac/vm-setup/ (bromure-agentd.py and everything
#                           staged beside it: the guest sandbox's, the sentry's source, the
#                           cluster nodes'; what git tracks, swapped in whole)
#   - the PII model      -> ~/.local/share/BromureAC/Models/pii-rampart (scripts/fetch-pii-model.sh:
#                           pinned and SHA-256 checked; a failed fetch stops the install)
#   - the unit           -> ~/.config/systemd/user/bromure-ac.service, then enabled and started
#
# Lingering: a user service runs only while the user has a session, unless lingering is on.
# For a headless host that must run after boot with nobody logged in, enable it once (as root):
#     loginctl enable-linger <user>
# This script only reports whether it's on.
#
# Prerequisites it doesn't change:
#   - /dev/kvm usable by this user (the kvm udev rule,
#     or kvm group membership). A user unit can't add groups.
#   - the baked image in ~/.local/share/bromure-ac/image-amd64 (`bromure-ac image bake`) or
#     --image DIR, and passt.
#
# Usage: install-user-service.sh [--image DIR] [--no-start] [--uninstall] [--stage DIR]
#   --stage DIR: everything under DIR instead (bin/, share/, systemd-user/), and systemd
#                left alone: for packaging, or a test of the installed layout.
set -euo pipefail
# Host libraries the daemon links (linux/RELEASE_NOTES.md, Host requirements):
# library:package. Missing ones stop the install, named.
# The cache read once: `ldconfig -p | grep -q` fails under pipefail when grep
# stops early and ldconfig gets SIGPIPE (a present library read as missing).
LDCACHE=$(ldconfig -p)
for req in libz.so.1:zlib1g libbrotlidec.so.1:libbrotli1; do
  grep -q "${req%%:*} " <<<"$LDCACHE" || { echo "$(basename "$0"): missing ${req%%:*}: install the ${req##*:} package" >&2; exit 1; }
done
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
BIN=$HOME/.local/bin/bromure-ac
AGENTD=$DATA/bromure-ac/vm-setup/bromure-agentd.py
PIIMODEL=$DATA/BromureAC/Models/pii-rampart
IMAGE=$DATA/bromure-ac/image-amd64
START=1
STAGE=
while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE=$2; shift 2 ;;
    --no-start) START=0; shift ;;
    --stage)
      STAGE=$(mkdir -p "$2" && cd "$2" && pwd)
      BIN=$STAGE/bin/bromure-ac; DATA=$STAGE/share; UNIT_DIR=$STAGE/systemd-user
      AGENTD=$DATA/bromure-ac/vm-setup/bromure-agentd.py; PIIMODEL=$DATA/BromureAC/Models/pii-rampart
      shift 2 ;;
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
# Its build metadata (/state's "build"), beside it.
"$ROOT/linux/stamp-build-info.sh" "$BIN.build-info.json.new" && chmod 644 "$BIN.build-info.json.new" \
  && mv -f "$BIN.build-info.json.new" "$BIN.build-info.json" || exit 1
# The guest scripts: agentd and what the daemon stages beside it (a strict or
# OpenShell workspace isn't started without its scripts). Only what git
# tracks, built in vm-setup.new and swapped in whole.
VS=$(dirname "$AGENTD")
case "$VS" in */bromure-ac/vm-setup) ;; *) echo "$(basename "$0"): unexpected vm-setup path $VS" >&2; exit 1 ;; esac
rm -rf -- "$VS.new" "$VS.old"
mkdir -p "$VS.new"
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  git -c safe.directory="$ROOT" -C "$ROOT" ls-files -z Sources/AgentCoding/Resources/vm-setup \
    | tar -C "$ROOT" --null -T - -cf - | tar -C "$VS.new" --strip-components=4 --no-same-owner -xf -
else
  cp -R "$ROOT/Sources/AgentCoding/Resources/vm-setup/." "$VS.new/"
fi
for f in bromure-agentd.py bromure-attestd.py bromure-strict.py bromure-sandboxd sentry-dist/src/bromure_sentry.c; do
  [ -e "$VS.new/$f" ] || { echo "$(basename "$0"): the guest scripts didn't copy ($f)" >&2; exit 1; }
done
chmod -R u=rwX,go=rX "$VS.new"
[ -d "$VS" ] && mv "$VS" "$VS.old"
mv "$VS.new" "$VS"
rm -rf -- "$VS.old"
# The PII detector's model, where PIIDetector looks (macOS ships it in the app).
BROMURE_PII_CACHE=${BROMURE_PII_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/bromure-ac/pii-rampart} \
  "$ROOT/scripts/fetch-pii-model.sh" "$PIIMODEL" >/dev/null \
  || { echo "$(basename "$0"): the PII model couldn't be fetched (PII protection needs it): check the network, or put the pinned files in \$BROMURE_PII_CACHE, and run this again" >&2; exit 1; }
# A path as a quoted systemd value: % doubled (specifiers), \ and " escaped;
# then escaped again for sed's replacement (\, &, |).
unit_value() { printf '%s' "$1" | sed -e 's/%/%%/g' -e 's/[\\"]/\\&/g' -e 's/[\\&|]/\\&/g'; }
sed -e "s|@BIN@|$(unit_value "$BIN")|" -e "s|@IMAGE@|$(unit_value "$IMAGE")|" \
    -e "s|@AGENTD@|$(unit_value "$AGENTD")|" -e "s|@PIIMODEL@|$(unit_value "$PIIMODEL")|" \
  "$ROOT/linux/systemd/bromure-ac.service" > "$UNIT_DIR/bromure-ac.service"
if [ -n "$STAGE" ]; then echo "staged in $STAGE (systemd left alone)"; exit 0; fi
systemctl --user daemon-reload
if [ $START = 1 ]; then systemctl --user enable --now bromure-ac.service; else systemctl --user enable bromure-ac.service; fi
echo "installed: $UNIT_DIR/bromure-ac.service -> $BIN"
[ -d "$IMAGE" ] || echo "note: no image at $IMAGE yet (bromure-ac image bake)"
[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" = yes ] \
  || echo "note: lingering is off: the service stops when you log out (root: loginctl enable-linger $(id -un))"
[ -w /dev/kvm ] || echo "note: /dev/kvm isn't writable by $(id -un): VMs won't start until it is (kvm group or the udev rule)"
