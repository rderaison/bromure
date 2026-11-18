#!/bin/bash
# linux/packaging/build-deb.sh [OUT_DIR]: the multi-user Bromure server as a
# Debian package, bromure-ac-<version>_<arch>.deb, into OUT_DIR (default
# ./out). Run from a source tree (a git archive is enough) in the
# Dockerfile.toolchain environment; Jenkinsfile.linux runs it.
#
# TARGET_ARCH (x86_64 | aarch64, default x86_64): the package's
# architecture. Not the builder's: cross-built with the Swift SDK and the
# musl cross compiler the toolchain image installed.
# BROMURE_BUILD_VERSION / BROMURE_BUILD_COMMIT: `git describe --tags` and
# the short commit (a tree without .git can't say); BUILD_NUMBER: Jenkins'.
#
# The package carries what linux/multiuser/install.sh installs (the binary,
# its build info, the Swift runtime, Firecracker, the PII model, the
# resources), under /usr/lib/bromure-ac, the units under
# /usr/lib/systemd/system, and runs install.sh's system half
# (configure.sh) from its postinst. The guest image isn't in it: it is
# built for the server's own KVM, `bromure-image-install` after the install.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(mkdir -p "${1:-$PWD/out}" && cd "${1:-$PWD/out}" && pwd)
TARGET_ARCH=${TARGET_ARCH:-x86_64}
HOST_ARCH=$(uname -m)
die() { echo "build-deb.sh: $*" >&2; exit 1; }
step() { echo "=== $*"; }

case $TARGET_ARCH in
  x86_64) DEB_ARCH=amd64;;
  aarch64) DEB_ARCH=arm64;;
  *) die "unsupported TARGET_ARCH $TARGET_ARCH";;
esac

# --- version ------------------------------------------------------------------
# agentic-coding-v5.4.4-722-g019771733 -> 5.4.4+722 (the commit count orders
# it; the commit is in bromure-ac.build-info.json); no tag -> 0.0.0+<date>.<commit>.
# A Jenkins build number makes rebuilds of one commit ordered.
DESCRIBE=${BROMURE_BUILD_VERSION:-$(git -C "$ROOT" describe --tags --always --match 'agentic-coding-v*' 2>/dev/null || true)}
COMMIT=${BROMURE_BUILD_COMMIT:-$(git -C "$ROOT" rev-parse --short=8 HEAD 2>/dev/null || true)}
case $DESCRIBE in
  agentic-coding-v*) V=${DESCRIBE#agentic-coding-v}; BASEV=${V%%-*}; REST=${V#"$BASEV"}; REST=${REST#-}; REST=${REST%-g*}
                     DEB_VERSION=$BASEV${REST:++${REST//-/.}};;
  *) DEB_VERSION=0.0.0+$(date -u +%Y%m%d).${COMMIT:-unknown};;
esac
[ -n "${BUILD_NUMBER:-}" ] && DEB_VERSION=$DEB_VERSION.b$BUILD_NUMBER
echo "$DEB_VERSION" | grep -Eq '^[0-9][A-Za-z0-9.+~]*$' || die "bad package version '$DEB_VERSION' (from '$DESCRIBE')"
step "bromure-ac $DEB_VERSION ($DEB_ARCH) from ${DESCRIBE:-?}, on $HOST_ARCH"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PKG=$WORK/pkg
L=$PKG/usr/lib/bromure-ac

# --- bromure-ac -----------------------------------------------------------------
step "swift build ($TARGET_ARCH)"
# The packaged runtime ($ORIGIN/../lib) only: no RUNPATH to the build's toolchain.
SWIFT_ARGS=(-c release --product bromure-ac -Xswiftc -no-toolchain-stdlib-rpath -Xlinker -rpath -Xlinker '$ORIGIN/../lib')
if [ "$TARGET_ARCH" != "$HOST_ARCH" ]; then
  SDK=$(swift sdk list | grep -E "_${TARGET_ARCH}\$|${TARGET_ARCH}-unknown-linux-gnu" | head -1)
  [ -n "$SDK" ] || die "no Swift SDK for $TARGET_ARCH (swift sdk list): build Dockerfile.toolchain with TARGET_ARCH=$TARGET_ARCH"
  SWIFT_ARGS+=(--swift-sdk "$SDK")
fi
(cd "$ROOT/linux/ACLinux" && swift build "${SWIFT_ARGS[@]}")
BIN=$(cd "$ROOT/linux/ACLinux" && swift build "${SWIFT_ARGS[@]}" --show-bin-path)/bromure-ac
[ -x "$BIN" ] || die "no binary at $BIN"
file "$BIN" | grep -q "$( [ "$TARGET_ARCH" = x86_64 ] && echo x86-64 || echo aarch64 )" || die "$BIN isn't a $TARGET_ARCH binary: $(file "$BIN")"

install -d -m 755 "$L/bin" "$L/lib" "$L/libexec" "$PKG/usr/bin" "$PKG/usr/sbin" "$PKG/usr/lib/systemd/system" \
  "$PKG/usr/share/doc/bromure-ac" "$PKG/DEBIAN"
install -m 755 "$BIN" "$L/bin/bromure-ac"
"$ROOT/linux/stamp-build-info.sh" "$L/bin/bromure-ac.build-info.json"
chmod 644 "$L/bin/bromure-ac.build-info.json"
ln -s ../lib/bromure-ac/bin/bromure-ac "$PKG/usr/bin/bromure-ac"

# The Swift runtime it links (readelf works on either architecture), from
# the target's Swift libraries: the SDK's, or this toolchain's when native.
step "Swift runtime"
if [ "$TARGET_ARCH" != "$HOST_ARCH" ]; then
  SWIFTLIB=$(dirname "$(find "$HOME/.swiftpm/swift-sdks" "${XDG_CONFIG_HOME:-$HOME/.config}/swiftpm/swift-sdks" \
    -path "*$TARGET_ARCH*" -path '*/swift/linux/libswiftCore.so' 2>/dev/null | head -1)")
else
  SWIFTLIB=$(swiftc -print-target-info | python3 -c 'import json, sys; print(json.load(sys.stdin)["paths"]["runtimeLibraryPaths"][0])')
fi
[ -f "$SWIFTLIB/libswiftCore.so" ] || die "the target's Swift libraries weren't found ($SWIFTLIB)"
needed() { readelf -d "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'; }
queue=("$BIN"); declare -A seen=()
while [ ${#queue[@]} -gt 0 ]; do
  f=${queue[0]}; queue=("${queue[@]:1}")
  for so in $(needed "$f"); do
    [ -n "${seen[$so]:-}" ] && continue; seen[$so]=1
    if [ -f "$SWIFTLIB/$so" ]; then
      install -m 644 "$SWIFTLIB/$so" "$L/lib/$so"
      queue+=("$SWIFTLIB/$so")
    fi
  done
done
ls "$L/lib" | sed 's/^/  /'
# What's left is the system's: the package's Depends.
step "system libraries: $(for so in "${!seen[@]}"; do [ -e "$L/lib/$so" ] || printf '%s ' "$so"; done)"

# --- Firecracker ------------------------------------------------------------------
step "Firecracker ($TARGET_ARCH)"
BROMURE_FC_ARCH=$TARGET_ARCH BROMURE_FC_SRC=$WORK/firecracker-src "$ROOT/linux/firecracker/build.sh" "$L/bin"
file "$L/bin/firecracker" | grep -Eq 'static(-pie)? linked|statically linked' || die "firecracker isn't static: $(file "$L/bin/firecracker")"

# --- the PII model, the resources -------------------------------------------------
step "PII model"
BROMURE_PII_CACHE=$WORK/pii "$ROOT/scripts/fetch-pii-model.sh" "$L/bin/pii-rampart" >/dev/null
step "resources"
install -d -m 755 "$L/resources"
tar -C "$ROOT/Sources/AgentCoding/Resources" -cf - . | tar -C "$L/resources" --no-same-owner -xf -
[ -e "$L/resources/catalog.json" ] || die "the resources didn't copy"
for f in bromure-agentd.py bromure-attestd.py bromure-strict.py bromure-sandboxd sentry-dist/src/bromure_sentry.c setup.sh; do
  [ -e "$L/resources/vm-setup/$f" ] || die "the guest scripts didn't copy ($f)"
done

# --- the system side ----------------------------------------------------------------
install -m 755 "$ROOT/linux/multiuser/configure.sh" "$L/libexec/configure.sh"
install -m 755 "$ROOT/linux/multiuser/bromure-setup-environment" "$PKG/usr/sbin/bromure-setup-environment"
IMAGE_VERSION=$(sed -n 's/.*static let imageVersion = "\([^"]*\)".*/\1/p' "$ROOT/Sources/AgentCoding/UbuntuImageManager.swift" | head -1)
[ -n "$IMAGE_VERSION" ] || die "UbuntuImageManager.imageVersion not found"
sed "s|@IMAGE_VERSION@|$IMAGE_VERSION|" "$ROOT/linux/packaging/bromure-image-install" > "$PKG/usr/sbin/bromure-image-install"
chmod 755 "$PKG/usr/sbin/bromure-image-install"
for u in bromure-ac@.service bromure-ac@.socket bromure-gw.service bromure-gw-p2p.socket bromure-lan.service; do
  sed 's|/usr/local/lib/bromure-ac|/usr/lib/bromure-ac|g' "$ROOT/linux/multiuser/$u" > "$PKG/usr/lib/systemd/system/$u"
  chmod 644 "$PKG/usr/lib/systemd/system/$u"
done
! grep -rq /usr/local/lib/bromure-ac "$PKG/usr/lib/systemd/system" || die "a unit still names /usr/local/lib/bromure-ac"
install -m 644 "$ROOT/linux/RELEASE_NOTES.md" "$PKG/usr/share/doc/bromure-ac/RELEASE_NOTES.md"
install -m 644 "$ROOT/linux/packaging/README.Debian" "$PKG/usr/share/doc/bromure-ac/README.Debian"

# --- DEBIAN/ --------------------------------------------------------------------------
for s in postinst prerm postrm; do install -m 755 "$ROOT/linux/packaging/debian/$s" "$PKG/DEBIAN/$s"; done
SIZE=$(du -sk --exclude=DEBIAN "$PKG" | cut -f1)
cat > "$PKG/DEBIAN/control" <<EOF
Package: bromure-ac
Version: $DEB_VERSION
Architecture: $DEB_ARCH
Maintainer: Bromure <support@bromure.io>
Installed-Size: $SIZE
Section: admin
Priority: optional
Depends: libc6 (>= 2.39), libstdc++6, libgcc-s1, zlib1g, libbrotli1, libcurl4t64 | libcurl4, passt, virtiofsd, iproute2, e2fsprogs, openssh-client, python3, systemd, passwd, procps
Recommends: btrfs-progs, libpam0g, curl
Suggests: libonnxruntime1.23
Homepage: https://bromure.io
Description: Bromure Agentic Coding server (multi-user, Firecracker)
 Runs coding agents (Claude Code, Codex, Grok, Kimi, omp, Hermes) in
 disposable Firecracker microVMs, one daemon per user, driven from the
 Bromure apps over SSH. Includes the SSH gateway, the LAN address helper,
 Firecracker and the Swift runtime.
 .
 After installing: bromure-setup-environment (btrfs storage),
 bromure-image-install (the guest image), bromure-ac admin add <user>.
EOF
step "dpkg-deb"
DEB=$OUT/bromure-ac-${DEB_VERSION}_${DEB_ARCH}.deb
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$DEB" >/dev/null
dpkg-deb --info "$DEB" | sed -n '1,/Description/p'
(cd "$OUT" && sha256sum "$(basename "$DEB")" > "$(basename "$DEB").sha256")
echo "$DEB"
