#!/bin/sh
# Runs inside ci/linux/Dockerfile (cwd = web-client). Typecheck, unit tests,
# build, package for $ARCHES, check the packages, collect them with their
# checksums in /home/node/artifacts.
set -eu
ARCHES="${ARCHES:-x64,arm64}"
ART=/home/node/artifacts
rm -rf "$ART" out && mkdir -p "$ART"

echo "=== node $(node -v) · npm $(npm -v) · $(uname -m) · packaging $ARCHES ==="
npm run typecheck
npm test
npm run build
npm run build:electron
node scripts/package.mjs linux "$ARCHES"

VERSION=$(node -p "require('./package.json').version")
fail() { echo "CHECK FAILED: $*" >&2; exit 1; }

for arch in $(echo "$ARCHES" | tr ',' ' '); do
    case "$arch" in x64) debarch=amd64; elf='X86-64' ;; arm64) debarch=arm64; elf='AArch64' ;; *) fail "unknown arch $arch" ;; esac
    deb="out/bromure-client_${VERSION}_${debarch}.deb"
    tgz="out/bromure-client-${VERSION}-linux-${arch}.tar.gz"
    echo "=== checking $deb"
    [ -f "$deb" ] || fail "missing $deb"
    [ -f "$tgz" ] || fail "missing $tgz"
    dpkg-deb --field "$deb" Package Version Architecture
    [ "$(dpkg-deb --field "$deb" Architecture)" = "$debarch" ] || fail "$deb: wrong Architecture"
    list=$(dpkg-deb --contents "$deb")
    echo "$list" | grep -Eq '^-rwsr-xr-x (root/root|0/0) .* \./opt/bromure-client/chrome-sandbox$' || fail "$deb: chrome-sandbox isn't setuid root"
    echo "$list" | grep -q ' \./usr/bin/bromure-client -> /opt/bromure-client/bromure-client$' || fail "$deb: no /usr/bin link"
    echo "$list" | grep -q ' \./usr/share/icons/hicolor/512x512/apps/io.bromure.client.png$' || fail "$deb: no icon"
    x=$(mktemp -d)
    dpkg-deb --extract "$deb" "$x"
    desktop-file-validate "$x/usr/share/applications/io.bromure.client.desktop"
    grep -qx 'MimeType=x-scheme-handler/bromure-client;' "$x/usr/share/applications/io.bromure.client.desktop" || fail "$deb: no scheme handler"
    # The right Electron for the arch (ELF machine field at offset 18).
    m=$(od -An -tx2 -j18 -N2 "$x/opt/bromure-client/bromure-client" | tr -d ' ')
    case "$elf:$m" in X86-64:003e|AArch64:00b7) ;; *) fail "$deb: binary machine $m, expected $elf" ;; esac
    # The network tunnel: its program (same arch, static) and its helper's units.
    t="$x/opt/bromure-client/resources/bromure-client-tunnel"
    [ -x "$t" ] || fail "$deb: no tunnel program"
    m=$(od -An -tx2 -j18 -N2 "$t" | tr -d ' ')
    case "$elf:$m" in X86-64:003e|AArch64:00b7) ;; *) fail "$deb: tunnel program machine $m, expected $elf" ;; esac
    grep -q '^ListenStream=/run/bromure-client-tunnel.sock$' "$x/usr/lib/systemd/system/bromure-client-tunnel.socket" || fail "$deb: tunnel socket unit"
    grep -qx 'ExecStart=/opt/bromure-client/resources/bromure-client-tunnel helper' "$x/usr/lib/systemd/system/bromure-client-tunnel@.service" || fail "$deb: tunnel service unit"
    dpkg-deb --field "$deb" Depends | grep -q 'iproute2' || fail "$deb: Depends lacks iproute2"
    rm -rf "$x"
    echo "=== checking $tgz"
    top=$(tar -tzf "$tgz" | head -1)
    [ "$top" = "bromure-client-${VERSION}-linux-${arch}/" ] || fail "$tgz: top folder '$top'"
    tar -tzf "$tgz" | grep -qx "bromure-client-${VERSION}-linux-${arch}/README-linux.txt" || fail "$tgz: no README-linux.txt"
    cp "$deb" "$tgz" "$ART/"
done

(cd "$ART" && sha256sum -- *.deb *.tar.gz > SHA256SUMS && cat SHA256SUMS)
echo "=== build OK"
