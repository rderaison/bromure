#!/bin/sh
# Install-and-launch check of the .deb for THIS machine's arch, in a clean
# container per distro (Jenkinsfile.client-linux runs it on each arch's agent).
#
#   smoke-host.sh <artifacts-dir> <results-dir>
#
# SMOKE_BASES: distro images to install on (default "ubuntu:24.04 debian:12").
# Each one: apt installs the .deb (its Depends must resolve), then smoke.sh
# checks the install and renders the app under Xvfb. Results (connect.png,
# smoke.log) land in <results-dir>/<arch>-<distro>/. Exits non-zero if any
# distro failed; without a .deb for this arch there's nothing to do.
set -eu
ART=$1
RES=$2
HERE=$(cd "$(dirname "$0")" && pwd)
case "$(uname -m)" in
    x86_64|amd64)  a=amd64; plat=linux/amd64 ;;
    aarch64|arm64) a=arm64; plat=linux/arm64 ;;
    *) echo "unsupported arch $(uname -m)"; exit 1 ;;
esac
deb=$(ls "$ART"/bromure-client_*_"$a".deb 2>/dev/null | head -1 || true)
[ -n "$deb" ] || { echo "No $a .deb in $ART: nothing to smoke-test on this agent."; exit 0; }

# Only the .deb and the two smoke files in the build context.
ctx=$(mktemp -d)
trap 'rm -rf "$ctx"' EXIT
cp "$deb" "$HERE/smoke.sh" "$HERE/Dockerfile.smoke" "$ctx/"

rc=0
for base in ${SMOKE_BASES:-ubuntu:24.04 debian:12}; do
    tag=$(printf '%s' "$base" | tr -c 'A-Za-z0-9.' '-')
    c="bcl-smoke-$a-$tag-${BUILD_NUMBER:-local}"
    img="bromure-client-linux-smoke:$a-$tag"
    echo "=== $(basename "$deb") on $base ($plat)"
    docker rm -f "$c" >/dev/null 2>&1 || true
    docker build --pull --platform "$plat" -q --build-arg BASE="$base" -f "$ctx/Dockerfile.smoke" -t "$img" "$ctx"
    docker run --platform "$plat" --name "$c" "$img" || { echo "!!! smoke failed on $base"; rc=1; }
    mkdir -p "$RES/$a-$tag"
    docker cp "$c:/home/tester/out/." "$RES/$a-$tag/" || true
    docker rm -f "$c" >/dev/null 2>&1 || true
    docker rmi -f "$img" >/dev/null 2>&1 || true
done
exit $rc
