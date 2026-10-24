#!/usr/bin/env bash
# Build the Linux packages: .deb and .rpm, amd64 and arm64.
#
#   scripts/package-linux.sh [version]
#
# Needs nfpm (go install github.com/goreleaser/nfpm/v2/cmd/nfpm@v2.48.0).
# Output in dist/packages/. The tarball from scripts/build.sh stays as the
# no-root alternative; this is for the Bromure package repo (packaging/REPO.md).
set -euo pipefail
cd "$(dirname "$0")/.."

raw="${1:-$(git describe --tags --always 2>/dev/null || echo 0.0.0)}"
# One version string both formats accept: rpm refuses '-' in a version and
# deb refuses a leading 'v', so everything that is not alphanumeric or a dot
# becomes a dot. "v1.2.3-4-gabc123" -> "1.2.3.4.gabc123".
version="$(printf '%s' "${raw#v}" | tr -c 'A-Za-z0-9.' '.' | sed 's/\.\{2,\}/./g; s/^\.//; s/\.$//')"
[ -n "$version" ] || { echo "package: empty version from '$raw'" >&2; exit 1; }

command -v nfpm >/dev/null 2>&1 || {
    echo "package: nfpm is not on PATH." >&2
    echo "         go install github.com/goreleaser/nfpm/v2/cmd/nfpm@v2.48.0" >&2
    exit 1
}

out=dist/packages
rm -rf "$out"
mkdir -p "$out"
export PKG_VERSION="$version"
export PKG_MAINTAINER="${PKG_MAINTAINER:-Bromure <support@bromure.io>}"

echo "== bromure-sidecar $version (from '$raw')"
for arch in amd64 arm64; do
    stage="dist/stage-$arch"
    rm -rf "$stage"
    mkdir -p "$stage"

    # $raw, not $version: the binary reports its true build identity
    # ("v1.2.3-4-gabc123"), while the package version has to be sanitised for
    # rpm. So `bromure-sidecar version` and `dpkg -l` differ by punctuation,
    # deliberately -- the git description is what a bug report needs.
    CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -trimpath \
        -ldflags "-s -w -X main.version=${raw}" \
        -o "$stage/bromure-sidecar" ./cmd/bromure-sidecar

    # The packaged unit comes from the tarball's unit, with one line changed:
    # a package installs the binary in /usr/bin, the tarball in ~/.local/bin.
    # Generated rather than kept as a second file, so the two cannot drift --
    # and the substitution is CHECKED, because a reworded ExecStart would
    # otherwise ship a unit pointing at a path the package never installs.
    sed 's|^ExecStart=%h/\.local/bin/bromure-sidecar serve$|ExecStart=/usr/bin/bromure-sidecar serve|' \
        installer/linux/bromure-sidecar.service > "$stage/bromure-sidecar.service"
    grep -qx 'ExecStart=/usr/bin/bromure-sidecar serve' "$stage/bromure-sidecar.service" || {
        echo "package: the ExecStart rewrite did not match." >&2
        echo "         installer/linux/bromure-sidecar.service must contain exactly:" >&2
        echo "           ExecStart=%h/.local/bin/bromure-sidecar serve" >&2
        exit 1
    }
    # And the packaged unit must not still refer to the home-relative path
    # anywhere (PATH= uses %h on purpose; ExecStart must not).
    ! grep -q '^ExecStart=.*%h' "$stage/bromure-sidecar.service" || {
        echo "package: the packaged unit still has a %h ExecStart." >&2; exit 1; }

    # Render the config rather than relying on nfpm expanding ${…} itself:
    # measured with nfpm 2.48, a `${PKG_STAGE}` inside `contents[].src` is
    # NOT expanded and fails as `Glob failed: ${PKG_STAGE}/bromure-sidecar`.
    # Substituting here is explicit and does not depend on which fields a
    # given nfpm version expands.
    cfg="$stage/nfpm.yaml"
    sed -e "s|\${PKG_ARCH}|$arch|g" \
        -e "s|\${PKG_STAGE}|$stage|g" \
        -e "s|\${PKG_VERSION}|$version|g" \
        -e "s|\${PKG_MAINTAINER}|$PKG_MAINTAINER|g" \
        packaging/nfpm.yaml > "$cfg"
    ! grep -q '\${PKG_' "$cfg" || {
        echo "package: unsubstituted placeholders left in $cfg:" >&2
        grep -n '\${PKG_' "$cfg" >&2
        exit 1
    }
    for fmt in deb rpm; do
        nfpm package --config "$cfg" --packager "$fmt" --target "$out/"
    done
    rm -rf "$stage"
done

( cd "$out" && sha256sum ./* > SHA256SUMS )
echo
ls -1 "$out"
echo
echo "built into $out/"
