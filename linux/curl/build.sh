#!/bin/bash
# build.sh OUT_LIB_DIR: libcurl for bromure-ac's Foundation, the pinned
# upstream release with WebSockets, as OUT_LIB_DIR/libcurl.so.4.
#
# Why not the distribution's: swift-corelibs-foundation's
# URLSessionWebSocketTask is libcurl's ws/wss. Ubuntu 24.04's libcurl (8.5)
# is built without them (WebSockets were off by default before curl 8.11),
# so there the P2P device channel (DeviceChannel: wss://…/device-channel)
# never connects: the server shows offline on bromure.io, with no error.
# The package's libFoundationNetworking.so finds this one first (its
# RUNPATH is $ORIGIN, the package's lib directory).
#
# The same interface as the distribution's: versioned symbols
# (CURL_OPENSSL_4, which Foundation's imports carry), OpenSSL, HTTP/2
# (nghttp2), zlib, brotli, zstd; linked to the system's own libraries
# (libssl3, libnghttp2-14, libzstd1, libbrotli1, zlib1g), without the
# protocols Foundation doesn't use (LDAP, RTMP, SSH, SMB…), libpsl or IDN.
#
# Cross build: BROMURE_CURL_ARCH=x86_64 (or aarch64), with
# $ARCH-linux-gnu-gcc and BROMURE_CURL_SYSROOT, a directory holding the
# target's -dev packages and their libraries, unpacked (usr/include,
# usr/lib/$ARCH-linux-gnu); linux/packaging/build-deb.sh makes it from the
# toolchain's /opt/target-debs. Native: the system's headers (libssl-dev,
# libnghttp2-dev, libzstd-dev, libbrotli-dev, zlib1g-dev).
set -euo pipefail

VERSION=8.18.0
SHA256=40df79166e74aa20149365e11ee4c798a46ad57c34e4f68fd13100e2c9a91946
URL=https://curl.se/download/curl-$VERSION.tar.xz

OUT=${1:?usage: $0 OUT_LIB_DIR}
HOST_ARCH=$(uname -m)
ARCH=${BROMURE_CURL_ARCH:-$HOST_ARCH}
case $ARCH in x86_64|aarch64) ;; *) echo "build.sh: unsupported arch $ARCH" >&2; exit 1;; esac
die() { echo "build.sh: $*" >&2; exit 1; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

curl -fsSL --retry 3 -o "$WORK/curl.tar.xz" "$URL"
echo "$SHA256  $WORK/curl.tar.xz" | sha256sum -c --quiet - || die "curl-$VERSION.tar.xz doesn't match its pinned sha256"
tar -xJf "$WORK/curl.tar.xz" -C "$WORK"
cd "$WORK/curl-$VERSION"

ENV=()
CONF=(--prefix=/usr --enable-shared --disable-static --enable-versioned-symbols
      --with-openssl --with-nghttp2 --with-zlib --with-brotli --with-zstd
      --enable-websockets --without-libpsl --without-libidn2 --without-librtmp --without-libssh
      --without-libssh2 --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet
      --disable-tftp --disable-pop3 --disable-imap --disable-smtp --disable-gopher --disable-mqtt
      --disable-smb --disable-manual --disable-docs
      --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt --with-ca-path=/etc/ssl/certs)
if [ "$ARCH" != "$HOST_ARCH" ]; then
    ROOT=${BROMURE_CURL_SYSROOT:?a cross build needs BROMURE_CURL_SYSROOT}
    TRIPLE=$ARCH-linux-gnu
    command -v "$TRIPLE-gcc" >/dev/null || die "$TRIPLE-gcc not found"
    LIBDIR=$ROOT/usr/lib/$TRIPLE
    ENV=(CC="$TRIPLE-gcc" CPPFLAGS="-I$ROOT/usr/include -I$ROOT/usr/include/$TRIPLE"
         LDFLAGS="-L$LIBDIR -Wl,-rpath-link,$LIBDIR"
         PKG_CONFIG_LIBDIR="$LIBDIR/pkgconfig:$ROOT/usr/share/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$ROOT")
    CONF+=(--host="$TRIPLE")
fi
# The CA store where the distribution's looks (ca-certificates).
env "${ENV[@]}" ./configure -q "${CONF[@]}" >"$WORK/configure.log" 2>&1 \
    || { tail -40 "$WORK/configure.log" >&2; tail -60 config.log >&2; die "configure failed"; }
# (On by default since 8.11: only their absence is recorded.)
! grep -q '^#define CURL_DISABLE_WEBSOCKETS 1' lib/curl_config.h || die "configured without WebSockets"
make -s -j"$(nproc)" -C lib >"$WORK/make.log" 2>&1 || { tail -40 "$WORK/make.log" >&2; die "make failed"; }

SO=$(readlink -f lib/.libs/libcurl.so.4)
[ -f "$SO" ] || die "no libcurl.so.4 built"
# What Foundation imports: the CURL_OPENSSL_4 version.
objdump -T "$SO" | grep -q 'CURL_OPENSSL_4' || die "libcurl.so.4 carries no CURL_OPENSSL_4 symbols"
# Runs on Ubuntu 24.04: no symbol from a newer glibc than 2.39.
newest=$(objdump -T "$SO" | grep -o 'GLIBC_[0-9.]*' | sort -t. -k2,2n -k3,3n -u | tail -1)
[ "$(printf '%s\n' "$newest" GLIBC_2.39 | sort -t. -k2,2n -k3,3n | tail -1)" = GLIBC_2.39 ] \
    || die "libcurl needs $newest: newer than Ubuntu 24.04's glibc 2.39"
# The library's own protocol list (curl_version_info), where it runs.
if [ "$ARCH" = "$HOST_ARCH" ]; then
    printf '#include <curl/curl.h>\n#include <stdio.h>\n#include <string.h>\nint main(void){const curl_version_info_data*v=curl_version_info(CURLVERSION_NOW);int ws=0,wss=0;for(const char*const*p=v->protocols;*p;p++){ws|=!strcmp(*p,"ws");wss|=!strcmp(*p,"wss");}printf("%%s ws=%%d wss=%%d\\n",v->version,ws,wss);return ws&&wss?0:1;}\n' > "$WORK/v.c"
    cc -Iinclude -o "$WORK/v" "$WORK/v.c" -Llib/.libs -lcurl
    LD_LIBRARY_PATH=lib/.libs "$WORK/v" || die "the built libcurl lists no ws/wss"
fi
mkdir -p "$OUT"
install -m 644 "$SO" "$OUT/libcurl.so.4.new"
mv -f "$OUT/libcurl.so.4.new" "$OUT/libcurl.so.4"
echo "$OUT/libcurl.so.4: curl $VERSION for $ARCH, WebSockets, needs $newest; links $(readelf -d "$OUT/libcurl.so.4" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
