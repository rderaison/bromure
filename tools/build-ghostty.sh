#!/bin/bash
# Build GhosttyKit.xcframework from the pinned ghostty commit and stage it
# into vendor/ for the bromure-ac SPM binaryTarget.
#
#   vendor/GhosttyKit.xcframework   — static lib + ghostty.h module
#   vendor/ghostty-resources/       — terminfo + shell-integration/themes,
#                                     copied into the app bundle by build.sh
#
# Everything heavy is cached under ~/.cache/bromure-ghostty keyed on the
# pinned commit (tools/ghostty.commit), so re-runs are no-ops. CI: cache that
# directory, or at least vendor/, keyed on the same file.
#
# Xcode 26.4+ note: those SDKs dropped the arm64-macos slice from their tbd
# stubs, which zig 0.15.x's linker can't reconcile (fixed in zig 0.16; see
# ziglang #31658). When we detect that, we clone the SDK via APFS
# copy-on-write, textually re-add arm64-macos beside arm64e-macos in every
# tbd, and answer `xcrun --show-sdk-path` with the patched clone through a
# PATH wrapper. Ugly, self-contained, and removable once ghostty moves to a
# zig with the fix.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMIT="$(cat "$REPO_ROOT/tools/ghostty.commit")"
CACHE="${BROMURE_GHOSTTY_CACHE:-$HOME/.cache/bromure-ghostty}"
ZIG_VERSION="0.15.2"
ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-aarch64-macos-${ZIG_VERSION}.tar.xz"

VENDOR="$REPO_ROOT/vendor"
STAMP="$VENDOR/GhosttyKit.xcframework/.bromure-ghostty-commit"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$COMMIT" ]; then
    echo "GhosttyKit.xcframework up to date ($COMMIT)"
    exit 0
fi

mkdir -p "$CACHE"

# --- zig toolchain -----------------------------------------------------------
if [ ! -x "$CACHE/zig/zig" ]; then
    echo "Downloading zig ${ZIG_VERSION}…"
    curl -fsSL "$ZIG_URL" -o "$CACHE/zig.tar.xz"
    tar xf "$CACHE/zig.tar.xz" -C "$CACHE"
    rm -rf "$CACHE/zig"
    mv "$CACHE/zig-aarch64-macos-$ZIG_VERSION" "$CACHE/zig"
fi

# --- ghostty source at the pinned commit -------------------------------------
if [ ! -d "$CACHE/src/.git" ] || [ "$(git -C "$CACHE/src" rev-parse HEAD)" != "$COMMIT" ]; then
    echo "Fetching ghostty @ ${COMMIT}…"
    rm -rf "$CACHE/src"
    git init -q "$CACHE/src"
    git -C "$CACHE/src" remote add origin https://github.com/ghostty-org/ghostty
    git -C "$CACHE/src" fetch -q --depth 1 origin "$COMMIT"
    git -C "$CACHE/src" checkout -q FETCH_HEAD
fi

# --- Metal toolchain (separate download since Xcode 26) ----------------------
if ! /usr/bin/xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    echo "Metal toolchain missing — downloading (xcodebuild -downloadComponent MetalToolchain)…"
    xcodebuild -downloadComponent MetalToolchain
fi

# --- toolchain wrappers --------------------------------------------------------
mkdir -p "$CACHE/bin"
BUILD_PATH="$CACHE/bin:$PATH"

# zig 0.15's archive writer emits members that aren't 8-byte aligned; Xcode
# 26's libtool warns about them and silently DROPS them from the combined
# archive — including ghostty's entire main compilation unit, leaving a
# libghostty-fat.a with no C API. Repack every input archive with Apple ar
# (which writes aligned members) before the real libtool combines them.
cat > "$CACHE/bin/libtool" <<'SH'
#!/bin/bash
set -euo pipefail
args=("$@")
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
n=0
for i in "${!args[@]}"; do
    a="${args[$i]}"
    case "$a" in
        *.a)
            [ -f "$a" ] || continue
            case "$a" in /*) abs="$a" ;; *) abs="$PWD/$a" ;; esac
            d="$tmp/$n"; n=$((n+1))
            mkdir -p "$d"
            (cd "$d" && /usr/bin/ar x "$abs")
            # zig records mode 000 on archive members; ar x preserves that,
            # leaving files we can't read back. Normalize before repacking.
            chmod 644 "$d"/*
            # Drop extracted symbol tables: repacked as ordinary members they
            # can land ahead of libtool's fresh TOC and shadow it, making the
            # merged archive look symbol-less to nm/ld.
            rm -f "$d"/__.SYMDEF*
            repacked="$tmp/repacked-$n.a"
            /usr/bin/ar rcs "$repacked" "$d"/*
            args[$i]="$repacked"
            ;;
    esac
done
exec /usr/bin/libtool "${args[@]}"
SH
chmod +x "$CACHE/bin/libtool"

# --- Xcode 26.4+ tbd workaround ----------------------------------------------
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
if ! grep -q 'arm64-macos' "$SDK/usr/lib/libSystem.tbd"; then
    SHADOW="$CACHE/MacOSX-shadow.sdk"
    if [ ! -f "$SHADOW/.bromure-patched" ] || [ "$(cat "$SHADOW/.bromure-patched")" != "$SDK" ]; then
        echo "SDK tbds lack arm64-macos (zig #31658) — building patched shadow SDK…"
        rm -rf "$SHADOW"
        cp -Rc "$SDK" "$SHADOW"
        python3 - "$SHADOW" <<'EOF'
import os, sys
root = sys.argv[1]
seen, patched = set(), 0
for dirpath, dirs, files in os.walk(root):
    for fn in files:
        if not fn.endswith(".tbd"):
            continue
        p = os.path.join(dirpath, fn)
        try:
            st = os.stat(p)
        except OSError:
            continue
        if st.st_ino in seen:
            continue
        seen.add(st.st_ino)
        try:
            text = open(p, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        if "arm64e-macos" in text:
            os.chmod(p, 0o644)
            open(p, "w", encoding="utf-8").write(
                text.replace("arm64e-macos", "arm64e-macos, arm64-macos"))
            patched += 1
print(f"patched {patched} tbds")
EOF
        echo "$SDK" > "$SHADOW/.bromure-patched"
    fi
    cat > "$CACHE/bin/xcrun" <<SH
#!/bin/sh
# build-ghostty.sh: answer SDK-path queries with the tbd-patched shadow SDK;
# delegate every other xcrun invocation to the real one.
case "\$*" in
  *--show-sdk-path*) echo "$SHADOW"; exit 0 ;;
esac
exec /usr/bin/xcrun "\$@"
SH
    chmod +x "$CACHE/bin/xcrun"
fi

# --- build --------------------------------------------------------------------
# Pre-fetch dependencies with a retry: ~20 hash-pinned tarballs from
# deps.files.ghostty.org, and one reset connection otherwise kills a
# 10-minute build. Fetching is idempotent (global zig cache).
for attempt in 1 2 3; do
    (cd "$CACHE/src" && PATH="$BUILD_PATH" "$CACHE/zig/zig" build --fetch \
        -Doptimize=ReleaseFast -Demit-macos-app=false \
        -Dxcframework-target=native -Di18n=false) && break
    echo "dependency fetch failed (attempt $attempt) — retrying…"
    sleep 5
done

echo "Building GhosttyKit.xcframework (zig, ReleaseFast, native arm64)…"
(cd "$CACHE/src" && PATH="$BUILD_PATH" "$CACHE/zig/zig" build \
    -Doptimize=ReleaseFast -Demit-macos-app=false \
    -Dxcframework-target=native -Di18n=false)

# --- stage into vendor/ --------------------------------------------------------
rm -rf "$VENDOR/GhosttyKit.xcframework" "$VENDOR/ghostty-resources"
mkdir -p "$VENDOR/ghostty-resources"
cp -Rc "$CACHE/src/macos/GhosttyKit.xcframework" "$VENDOR/GhosttyKit.xcframework"
cp -Rc "$CACHE/src/zig-out/share/terminfo" "$VENDOR/ghostty-resources/terminfo"
cp -Rc "$CACHE/src/zig-out/share/ghostty" "$VENDOR/ghostty-resources/ghostty"

# Rewrite the staged archive through Apple libtool: guarantees a fresh sorted
# TOC regardless of what zig's cache reinstalled (a stale __.SYMDEF member
# from a pre-wrapper merge shadows the symbol table and makes the archive
# look empty to nm/ld; in-place ranlib can no-op on freshly-copied files).
STAGED="$VENDOR/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a"
chmod u+w "$STAGED"
/usr/bin/libtool -static -o "$STAGED.toc" "$STAGED" 2>/dev/null
mv "$STAGED.toc" "$STAGED"

# --- verify -------------------------------------------------------------------
# The embedding API must be present — catches the libtool member-drop class
# of failure before it becomes an inscrutable link error in swift build.
# NB: grep -c, not -q — under pipefail, -q's early exit SIGPIPEs nm and
# turns a *successful* match into a failed pipeline.
if [ "$(nm "$STAGED" 2>/dev/null | grep -c 'T _ghostty_init$')" -eq 0 ]; then
    echo "ERROR: staged libghostty-fat.a does not export ghostty_init" >&2
    exit 1
fi

echo "$COMMIT" > "$STAMP"
echo "Staged vendor/GhosttyKit.xcframework + vendor/ghostty-resources ($COMMIT)"
