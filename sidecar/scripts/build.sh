#!/usr/bin/env bash
# Cross-compiles Bromure Sidecar (Go) for every target into sidecar/dist/.
#   scripts/build.sh [version]
# Windows gets both exes (the tray built with -H windowsgui); macOS and
# Linux get the console binary only (the tray is Windows-only).
set -euo pipefail
cd "$(dirname "$0")/.."
# A release passes X.Y.Z (the updater compares it); a local build is "dev"
# (it never offers updates).
version="${1:-dev}"
ldflags="-s -w -X main.version=${version}"
out=dist
rm -rf "$out"
mkdir -p "$out"
export CGO_ENABLED=0
# The version in the executables' resources (Explorer's Details tab, the
# installer); the committed objects say 0.0.0 again afterwards.
resver="$version"; [ "$resver" = dev ] && resver=0.0.0
go run ./tools/mkicons -syso-only -version "$resver" >/dev/null
trap 'go run ./tools/mkicons -syso-only -version 0.0.0 >/dev/null' EXIT
for target in windows/amd64 windows/arm64 darwin/arm64 linux/amd64; do
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
# Unsigned: scripts/installer.ps1 signs the Windows executables on Windows
# (and updates their lines in SHA256SUMS).
( cd "$out" && find . -type f -name 'bromure-sidecar*' -o -type f -name 'BromureSidecar.exe' | sort | xargs sha256sum > SHA256SUMS )
echo "built $version into $out/"
