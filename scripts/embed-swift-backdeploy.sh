#!/bin/bash
# embed-swift-backdeploy.sh — make a SwiftPM-built executable self-contained
# for older macOS releases.
#
# Building with a newer Swift toolchain than the deployment target links
# back-deployment shims (e.g. libswiftCompatibilitySpan.dylib for Swift 6.2's
# Span on macOS < 26) via @rpath, and SwiftPM adds an ABSOLUTE rpath into the
# Xcode toolchain to find them. On a user's Mac that path doesn't exist: the
# shim fails to load on macOS 14/15, and Gatekeeper/syspolicy rejects the app
# outright ("Bad Load Command … attempts to load /Applications/Xcode.app/…").
#
# This copies every @rpath/libswift*.dylib the binary links from those
# toolchain rpaths into Contents/Frameworks (signed), then removes the
# toolchain rpaths. The binary's rpath order (/usr/lib/swift first) keeps
# using the OS copy where the OS has one.
#
# Usage: embed-swift-backdeploy.sh <executable> <frameworks-dir> <sign-identity> [codesign args…]
# Run BEFORE signing the executable (install_name_tool invalidates signatures).
set -euo pipefail

BIN="$1"; FW_DIR="$2"; SIGN_ID="$3"; shift 3
SIGN_ARGS=("$@")

toolchain_rpaths=()
while IFS= read -r rp; do
    case "$rp" in
        */Xcode*.app/*|*.xctoolchain/*|*/CommandLineTools/*) toolchain_rpaths+=("$rp") ;;
    esac
done < <(otool -l "$BIN" | awk '/cmd LC_RPATH/{r=1} r && /path /{print $2; r=0}')

[ ${#toolchain_rpaths[@]} -eq 0 ] && exit 0

while IFS= read -r dep; do
    lib="${dep#@rpath/}"
    src=""
    for rp in "${toolchain_rpaths[@]}"; do
        [ -f "$rp/$lib" ] && { src="$rp/$lib"; break; }
    done
    if [ -z "$src" ]; then
        echo "embed-swift-backdeploy: $lib not found in the toolchain rpaths" >&2
        exit 1
    fi
    mkdir -p "$FW_DIR"
    cp -f "$src" "$FW_DIR/$lib"
    chmod 644 "$FW_DIR/$lib"
    codesign --force --sign "$SIGN_ID" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$FW_DIR/$lib"
    echo "Embedded Swift back-deployment library $lib."
done < <(otool -L "$BIN" | awk '/@rpath\/libswift[^ ]*\.dylib/ {print $1}')

for rp in "${toolchain_rpaths[@]}"; do
    install_name_tool -delete_rpath "$rp" "$BIN"
done
