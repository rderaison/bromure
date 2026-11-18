#!/bin/bash
# linux/multiuser/install.sh [--bind ADDR] [--port N]: install the multi-user
# Bromure server (root). Binaries and the Swift runtime under
# /usr/local/lib/bromure-ac, the guest image under /var/lib/bromure-ac-image,
# the units, the gateway's account `bromure`; starts the gateway, with P2P on
# (`bromure-ac admin p2p off` turns it off). Users come next:
# `bromure-ac admin add <name>`.
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
# Host libraries the daemon links (linux/RELEASE_NOTES.md, Host requirements):
# library:package. Missing ones stop the install, named.
# The cache read once: `ldconfig -p | grep -q` fails under pipefail when grep
# stops early and ldconfig gets SIGPIPE (a present library read as missing).
LDCACHE=$(ldconfig -p)
for req in libz.so.1:zlib1g libbrotlidec.so.1:libbrotli1; do
  grep -q "${req%%:*} " <<<"$LDCACHE" || { echo "$(basename "$0"): missing ${req%%:*}: install the ${req##*:} package" >&2; exit 1; }
done

L=/usr/local/lib/bromure-ac
install -d -m 755 $L/bin $L/lib
install -m 755 "$BIN" $L/bin/bromure-ac.new && mv -f $L/bin/bromure-ac.new $L/bin/bromure-ac
# Its build metadata (/state's "build"), beside it.
"$ROOT/linux/stamp-build-info.sh" $L/bin/bromure-ac.build-info.json.new && chmod 644 $L/bin/bromure-ac.build-info.json.new \
  && mv -f $L/bin/bromure-ac.build-info.json.new $L/bin/bromure-ac.build-info.json || exit 1
install -m 755 "$FC" $L/bin/firecracker.new && mv -f $L/bin/firecracker.new $L/bin/firecracker
# agentd runs from the resources' vm-setup/ (bromure-ac@.service's
# BROMURE_AGENTD), beside the guest scripts the daemon stages with it; the
# old lone copy goes.
rm -rf /usr/local/lib/bromure-ac/vm-setup
# The PII detector's model, beside the binary: where PIIDetector looks first
# (Bundle.main's resources: macOS ships it in the app), for every user.
# Pinned and SHA-256 checked; a failed fetch stops the install.
BROMURE_PII_CACHE=${BROMURE_PII_CACHE:-/var/cache/bromure-ac/pii-rampart} \
  "$ROOT/scripts/fetch-pii-model.sh" $L/bin/pii-rampart >/dev/null \
  || { echo "install.sh: the PII model couldn't be fetched (PII protection needs it): check the network, or put the pinned files in \$BROMURE_PII_CACHE, and run this again" >&2; exit 1; }
chmod -R u=rwX,go=rX $L/bin/pii-rampart
# The app's resources (catalog, vm-setup scripts: cluster nodes, registry,
# probes, ...): the daemons can't read the source tree. Only what git
# tracks, so a stray local file never becomes world-readable. Swapped in whole.
rm -rf /usr/local/lib/bromure-ac/resources.new /usr/local/lib/bromure-ac/resources.old
install -d -m 755 $L/resources.new
git -c safe.directory="$ROOT" -C "$ROOT" ls-files -z Sources/AgentCoding/Resources \
  | tar -C "$ROOT" --null -T - -cf - | tar -C $L/resources.new --strip-components=3 --no-same-owner -xf -
[ -e $L/resources.new/catalog.json ] || { echo "install.sh: the resources didn't copy" >&2; exit 1; }
for f in bromure-agentd.py bromure-attestd.py bromure-strict.py bromure-sandboxd sentry-dist/src/bromure_sentry.c; do
  [ -e $L/resources.new/vm-setup/$f ] || { echo "install.sh: the guest scripts didn't copy ($f)" >&2; exit 1; }
done
chmod -R u=rwX,go=rX $L/resources.new
[ -d $L/resources ] && mv $L/resources $L/resources.old
mv $L/resources.new $L/resources
rm -rf /usr/local/lib/bromure-ac/resources.old
# The Swift runtime the binary was linked against (a static stdlib build
# doesn't link Foundation on this toolchain).
ldd "$BIN" | awk '/=> \// {print $3}' | grep -E '/swift/|libFoundation|libswift|lib_FoundationICU|libdispatch|libBlocksRuntime' \
  | while read -r so; do install -m 644 "$so" $L/lib/; done
ln -sfn $L/bin/bromure-ac /usr/local/bin/bromure-ac

# The baked image, read-only for every user (sparse copy, ~1 s).
install -d -m 755 /var/lib/bromure-ac-image
for f in base.img vmlinuz initrd.img cmdline kernel-release base.version image-state.json; do
  [ -e "$IMAGE/$f" ] && cp --sparse=always "$IMAGE/$f" /var/lib/bromure-ac-image/$f.installing && mv -f /var/lib/bromure-ac-image/$f.installing /var/lib/bromure-ac-image/$f
done
chmod 644 /var/lib/bromure-ac-image/*
# The system side (accounts, directories, config, units, services): shared
# with the Debian package's postinst.
"$HERE/configure.sh" --bind "$BIND" --port "$PORT" --units "$HERE" --bin /usr/local/bin/bromure-ac
