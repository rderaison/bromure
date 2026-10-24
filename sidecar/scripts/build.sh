#!/usr/bin/env bash
# Cross-compiles Bromure Sidecar (Go) for every target into sidecar/dist/.
#   scripts/build.sh [version]
# Windows gets both exes (the tray built with -H windowsgui); macOS and
# Linux get the console binary only (the tray is Windows-only).
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:-$(git describe --tags --always 2>/dev/null || echo dev)}"
ldflags="-s -w -X main.version=${version}"
out=dist
rm -rf "$out"
mkdir -p "$out"
export CGO_ENABLED=0
for target in windows/amd64 windows/arm64 darwin/arm64 linux/amd64 linux/arm64; do
  os="${target%/*}"; arch="${target#*/}"
  dir="$out/$os-$arch"
  mkdir -p "$dir"
  ext=""; [ "$os" = windows ] && ext=".exe"
  echo "== $os/$arch"
  GOOS=$os GOARCH=$arch go build -trimpath -ldflags "$ldflags" -o "$dir/bromure-sidecar$ext" ./cmd/bromure-sidecar
  if [ "$os" = windows ]; then
    GOOS=$os GOARCH=$arch go build -trimpath -ldflags "$ldflags -H windowsgui" -o "$dir/BromureSidecar.exe" ./cmd/BromureSidecar
  fi
done
# Optional Authenticode signing: skipped unless a certificate is configured
# (SIGN_CERT = a .pfx path, SIGN_PASS its password; signtool on PATH).
if [ -n "${SIGN_CERT:-}" ] && command -v signtool >/dev/null 2>&1; then
  for f in "$out"/windows-*/*.exe; do
    signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /f "$SIGN_CERT" /p "${SIGN_PASS:-}" "$f"
  done
else
  echo "(signing skipped: no SIGN_CERT)"
fi
# Linux ships as a tarball with its installer, because there is no tray to
# put in a .exe and the whole install is one binary plus a systemd user unit.
# No .deb: a system package installing a per-USER service would have to guess
# which user, and the Sidecar runs the agents as a person with that person's
# credentials.
for arch in amd64 arm64; do
  d="$out/linux-$arch"
  [ -d "$d" ] || continue
  cp installer/linux/install.sh installer/linux/uninstall.sh \
     installer/linux/bromure-sidecar.service installer/linux/README.md "$d/"
  chmod 0755 "$d/install.sh" "$d/uninstall.sh"
  ( cd "$out" && tar czf "bromure-sidecar-linux-$arch.tar.gz" \
      --transform "s,^linux-$arch,bromure-sidecar-linux-$arch," "linux-$arch" )
done
( cd "$out" && find . -type f -name 'bromure-sidecar*' -o -type f -name 'BromureSidecar.exe' | sort | xargs sha256sum > SHA256SUMS )
echo "built $version into $out/"
