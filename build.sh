#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Per-target config. Add a new case here to support a new app bundle.
TARGET="${1:-bromure}"
case "$TARGET" in
    bromure)
        PRODUCT_NAME="bromure"
        APP_NAME="Bromure"
        SOURCE_DIR="$SCRIPT_DIR/Sources/Browser"
        ENTITLEMENTS="$SOURCE_DIR/SafariSandbox.entitlements"
        INFO_PLIST="$SOURCE_DIR/Info.plist"
        SDEF_FILE="$SOURCE_DIR/Bromure.sdef"
        RESOURCE_BUNDLE_NAME="bromure_bromure.bundle"
        ICON_FILE="$SCRIPT_DIR/Resources/AppIcon.icns"
        ICON_COMPOSER=""
        ;;
    bromure-ac)
        PRODUCT_NAME="bromure-ac"
        APP_NAME="Bromure Agentic Coding"
        SOURCE_DIR="$SCRIPT_DIR/Sources/AgentCoding"
        ENTITLEMENTS="$SOURCE_DIR/BromureAC.entitlements"
        INFO_PLIST="$SOURCE_DIR/Info.plist"
        SDEF_FILE="$SOURCE_DIR/BromureAC.sdef"
        RESOURCE_BUNDLE_NAME="bromure_bromure-ac.bundle"
        ICON_FILE="$SCRIPT_DIR/Resources/BromureACIcon.icns"
        ICON_COMPOSER="$SCRIPT_DIR/Resources/BromureAC.icon"
        ;;
    *)
        echo "Usage: $0 [bromure|bromure-ac]" >&2
        exit 2
        ;;
esac

echo "=== Building $APP_NAME ($PRODUCT_NAME) ==="

# GhosttyKit is an SPM binaryTarget at vendor/GhosttyKit.xcframework (never
# committed); build it from the pinned commit when missing. Needed by every
# target because SPM resolves the whole manifest.
if [ ! -d "$SCRIPT_DIR/vendor/GhosttyKit.xcframework" ]; then
    echo "vendor/GhosttyKit.xcframework missing — running tools/build-ghostty.sh…"
    "$SCRIPT_DIR/tools/build-ghostty.sh"
fi

# Force SwiftPM to regenerate resource bundles from current source.
# `swift build` recompiles the binary but does NOT reliably re-copy changed
# resource FILES into a target's .bundle when only resources changed (or a
# git checkout reset their mtimes) — it leaves whatever the bundle already
# held. Editing vm-setup guest scripts (config-agent.py, dnsmasq configs,
# bromure-hostkey, …) then building would ship a stale bundle: binary fresh,
# guest scripts days old. A `bromure init` bake reads those scripts, so the
# image silently lacks the fixes. Deleting the bundles first makes the copy
# step re-run (SPM recreates a missing resource bundle from source). Matters
# most on a warm build-server cache, where this trap is otherwise invisible.
# Xcode 26 / Swift 6.4 made the `swiftbuild` backend the default; it dies in
# macro packages with "unable to open dependencies file (…-primary.d)"
# (seen in Jinja and MLXHuggingFaceMacros) and tries to compile MLX's Metal
# kernels. The native backend does neither and keeps the
# .build/arm64-apple-macosx cache this script (and package.sh) rely on.
SWIFT_BUILD_SYSTEM="${SWIFT_BUILD_SYSTEM:-native}"
swift_build() {
    swift build --build-system "$SWIFT_BUILD_SYSTEM" "$@"
}

BUILD_DIR=$(swift_build -c release --arch arm64 --show-bin-path 2>/dev/null || true)
if [ -n "$BUILD_DIR" ]; then
    rm -rf "$BUILD_DIR"/*.bundle 2>/dev/null || true
fi

# Build the requested product in release mode.
# Dev-loop build: disable whole-module optimization so files compile in
# parallel across all cores instead of one long single-core job per module
# (the AgentCoding/Browser modules dominate). Costs cross-file optimization,
# which is fine here — package.sh does its own WMO build for shipped
# binaries. Note the flag difference means alternating build.sh/package.sh
# invalidates the shared .build cache and triggers a full rebuild.
swift_build -c release --arch arm64 --product "$PRODUCT_NAME" \
    -Xswiftc -no-whole-module-optimization 2>&1

BUILD_DIR=$(swift_build -c release --arch arm64 --show-bin-path 2>/dev/null)
BINARY="$BUILD_DIR/$PRODUCT_NAME"

if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    exit 1
fi

# The Mach-O must carry the SDK it was built against (LC_BUILD_VERSION
# "sdk"). A binary stamped with the deployment target instead (14.0) makes
# AppKit on macOS 26 render the legacy look — grey window fill, taller
# title bar, no glass. That happens when the toolchain's swift is run
# outside its Xcode context (no DEVELOPER_DIR / xcrun); going through
# /usr/bin/swift, as this script does, records the real SDK (27.0 today).
SDK_STAMP=$(otool -l "$BINARY" | awk '/LC_BUILD_VERSION/{f=1} f && /^ *sdk /{print $2; exit}')
MINOS_STAMP=$(otool -l "$BINARY" | awk '/LC_BUILD_VERSION/{f=1} f && /^ *minos /{print $2; exit}')
if [ -z "$SDK_STAMP" ] || [ "$SDK_STAMP" = "$MINOS_STAMP" ]; then
    echo "ERROR: $BINARY is stamped sdk=${SDK_STAMP:-?} (deployment target ${MINOS_STAMP:-?}):" >&2
    echo "       it would get the legacy AppKit look. Build through /usr/bin/swift (xcrun context)." >&2
    exit 1
fi

echo "Binary built at: $BINARY (SDK $SDK_STAMP, min macOS $MINOS_STAMP)"

# Signing identity: use CODESIGN_IDENTITY env var, or fall back to ad-hoc (-)
SIGN_ID="${CODESIGN_IDENTITY:--}"

# Sign the standalone binary too (for direct invocation without the app bundle).
echo "Code signing standalone binary..."
codesign --force --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" "$BINARY"

# Create a minimal .app bundle so macOS treats this as a GUI application.
# Required for Dock icon, NSApplication, and window focus to work properly.
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"

echo "Creating app bundle at: $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"

cp "$BINARY" "$MACOS_DIR/$PRODUCT_NAME"
cp "$INFO_PLIST" "$CONTENTS/Info.plist"

# SPM only sets @loader_path / /usr/lib/swift / Xcode rpaths on the binary;
# none resolve to Contents/Frameworks. Add the standard macOS app rpath so
# dyld finds Sparkle.framework and any other SPM framework we embed.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$PRODUCT_NAME" 2>/dev/null || true

# Embed provisioning profile (required for iCloud and other entitlements)
PROVISION_PROFILE="$SCRIPT_DIR/$PRODUCT_NAME.provisionprofile"
[ -f "$PROVISION_PROFILE" ] || PROVISION_PROFILE="$SCRIPT_DIR/bromure.provisionprofile"
if [ -f "$PROVISION_PROFILE" ]; then
    cp "$PROVISION_PROFILE" "$CONTENTS/embedded.provisionprofile"
fi

RESOURCES_DIR="$CONTENTS/Resources"
mkdir -p "$RESOURCES_DIR"

# Fat-client privileged tunnel daemon (SMAppService, macOS 13+). The plist lives
# in Contents/Library/LaunchDaemons/ and runs `bromure-ac __tunnel-helper` as
# root once the user approves it in System Settings › Login Items. Only meaningful
# for the bromure-ac target; harmless elsewhere.
LAUNCHD_DIR="$CONTENTS/Library/LaunchDaemons"
mkdir -p "$LAUNCHD_DIR"
BUNDLE_BIN_NAME="$(basename "$BINARY")"
cat > "$LAUNCHD_DIR/io.bromure.fatclient-tunnel.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.bromure.fatclient-tunnel</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/$BUNDLE_BIN_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BUNDLE_BIN_NAME</string>
        <string>__tunnel-helper</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST

# Copy the per-target icon as AppIcon.icns (matching CFBundleIconFile in
# both Info.plists). Fall back to the shared icon if the target-specific
# one is missing.
if [ -f "$ICON_FILE" ]; then
    cp "$ICON_FILE" "$RESOURCES_DIR/AppIcon.icns"
elif [ -f "$SCRIPT_DIR/Resources/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Tahoe (macOS 26) icon: compile the Icon Composer bundle into Assets.car and
# point CFBundleIconName at it; without it macOS 26 sets the .icns on a system
# plate. The .icns above stays as CFBundleIconFile for anything that can't
# read the catalog. Needs Xcode 26+'s actool; older toolchains keep the .icns.
if [ -n "$ICON_COMPOSER" ] && [ -d "$ICON_COMPOSER" ]; then
    ICON_NAME="$(basename "$ICON_COMPOSER" .icon)"
    ICON_TMP="$(mktemp -d)"
    if xcrun actool "$ICON_COMPOSER" --compile "$ICON_TMP" \
            --platform macosx --target-device mac --minimum-deployment-target 14.0 \
            --app-icon "$ICON_NAME" --output-partial-info-plist "$ICON_TMP/partial.plist" \
            >/dev/null 2>&1 && [ -f "$ICON_TMP/Assets.car" ]; then
        cp "$ICON_TMP/Assets.car" "$RESOURCES_DIR/Assets.car"
        /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$CONTENTS/Info.plist" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string $ICON_NAME" "$CONTENTS/Info.plist"
    else
        echo "warning: actool couldn't compile $ICON_COMPOSER; shipping the .icns only" >&2
    fi
    rm -rf "$ICON_TMP"
fi

# Browser-only: AppleScript scripting definition.
if [ -n "$SDEF_FILE" ] && [ -f "$SDEF_FILE" ]; then
    cp "$SDEF_FILE" "$RESOURCES_DIR/$(basename "$SDEF_FILE")"
fi

# Copy SPM resource bundles (vm-setup, etc.) needed at runtime.
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$RESOURCES_DIR/"
done

# Copy SPM-provided frameworks (Sparkle, etc.) so dyld can resolve them
# via @rpath at runtime. SPM leaves them alongside the binary but doesn't
# relocate them into the bundle. Filter to frameworks the binary actually
# links — otherwise targets that don't depend on Sparkle still pick up a
# stale copy from a prior sibling build in the shared $BUILD_DIR.
FRAMEWORKS_DIR="$CONTENTS/Frameworks"
LINKED_RPATHS=$(otool -L "$BINARY" | awk '/@rpath\// {print $1}')
for fw in "$BUILD_DIR"/*.framework; do
    [ -d "$fw" ] || continue
    fw_base=$(basename "$fw")
    if echo "$LINKED_RPATHS" | grep -q "@rpath/$fw_base/"; then
        mkdir -p "$FRAMEWORKS_DIR"
        cp -R "$fw" "$FRAMEWORKS_DIR/"
    fi
done

# Sign nested frameworks before the outer bundle — codesign validates
# contained bundles even when not explicitly deep-signing, so missing or
# mismatched sub-signatures fail the outer sign.
if [ -d "$FRAMEWORKS_DIR" ]; then
    for fw in "$FRAMEWORKS_DIR"/*.framework; do
        [ -d "$fw" ] || continue
        VB="$fw/Versions/B"
        [ -d "$VB" ] || VB="$fw/Versions/A"
        if [ -d "$VB/XPCServices" ]; then
            for xpc in "$VB/XPCServices"/*.xpc; do
                [ -e "$xpc" ] && codesign --force --sign "$SIGN_ID" "$xpc"
            done
        fi
        for helper in "$VB/Autoupdate" "$VB/Updater.app"; do
            [ -e "$helper" ] && codesign --force --sign "$SIGN_ID" "$helper"
        done
        codesign --force --sign "$SIGN_ID" "$fw"
    done
fi

# Copy localization .lproj directories into the app bundle so Bundle.main
# can find them — SwiftUI Text() looks up strings in Bundle.main, not
# Bundle.module. Targets with no localizations (e.g. bromure-ac today)
# simply have no resource bundle and the loop is a no-op.
if [ -d "$BUILD_DIR/$RESOURCE_BUNDLE_NAME" ]; then
    for lproj in "$BUILD_DIR/$RESOURCE_BUNDLE_NAME"/*.lproj; do
        [ -d "$lproj" ] && cp -R "$lproj" "$RESOURCES_DIR/"
    done
fi

# bromure-ac: bundle the prebuilt MLX Metal shader library colocated with the
# binary. `swift build` can't compile MLX's Metal kernels — only xcodebuild can
# — so we ship a pinned, version-matched mlx.metallib that MLX's loader finds
# next to the executable. This replaces the old uv/vllm-mlx venv provisioning:
# the inference engine is now in-process MLX-Swift, so there's no Python, no uv,
# and no engine-requirements to bundle.
if [ "$TARGET" = "bromure-ac" ]; then
    # Place it where MLX's SwiftPM-bundle loader looks — a nested
    # `mlx-swift_Cmlx.bundle` in Contents/Resources — NOT loose in Contents/MacOS
    # (a non-Mach-O file there breaks the code signature).
    MLX_BUNDLE="$RESOURCES_DIR/mlx-swift_Cmlx.bundle"
    mkdir -p "$MLX_BUNDLE/Contents/Resources"
    "$SCRIPT_DIR/scripts/fetch-mlx-metallib.sh" "$MLX_BUNDLE/Contents/Resources/default.metallib" >/dev/null
    cat > "$MLX_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.bromure.mlx-swift-Cmlx</string>
  <key>CFBundleName</key><string>mlx-swift_Cmlx</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
    echo "Bundled mlx.metallib (in-process MLX engine; no Python/uv)."

    # Rampart PII detector model (~15 MB, CC BY 4.0), pinned + SHA-256 checked.
    # PIIDetector loads Resources/pii-rampart first, so PII protection works
    # offline from the first launch with no download.
    "$SCRIPT_DIR/scripts/fetch-pii-model.sh" "$RESOURCES_DIR/pii-rampart" >/dev/null
    echo "Bundled the Rampart PII model."

    # The Rooms stage's SwiftUI shaders (shaders/RoomEffects.metal), compiled
    # here rather than by SwiftPM. The Metal toolchain is a build-time
    # requirement only (the .metallib ships in the bundle): fail loudly
    # without it. Install: xcodebuild -downloadComponent MetalToolchain
    SHADER_TMP="$(mktemp -d)"
    if xcrun -sdk macosx metal -c "$SCRIPT_DIR/shaders/RoomEffects.metal" -o "$SHADER_TMP/RoomEffects.air" 2>"$SHADER_TMP/err" \
       && xcrun -sdk macosx metallib "$SHADER_TMP/RoomEffects.air" -o "$RESOURCES_DIR/RoomEffects.metallib" 2>>"$SHADER_TMP/err"; then
        echo "Compiled RoomEffects.metallib."
    else
        echo "error: couldn't compile shaders/RoomEffects.metal — is the Metal toolchain installed?" >&2
        echo "  (xcodebuild -downloadComponent MetalToolchain)" >&2
        sed 's/^/  /' "$SHADER_TMP/err" >&2
        rm -rf "$SHADER_TMP"
        exit 1
    fi
    rm -rf "$SHADER_TMP"

    # Ghostty runtime resources (shell-integration, themes + terminfo).
    # GhosttyRuntime points GHOSTTY_RESOURCES_DIR at Resources/ghostty; the
    # terminfo sibling matches Ghostty.app's own bundle layout.
    if [ -d "$SCRIPT_DIR/vendor/ghostty-resources" ]; then
        cp -R "$SCRIPT_DIR/vendor/ghostty-resources/ghostty" "$RESOURCES_DIR/ghostty"
        cp -R "$SCRIPT_DIR/vendor/ghostty-resources/terminfo" "$RESOURCES_DIR/terminfo"
        echo "Bundled ghostty resources (native terminal surfaces)."
    fi
fi

# Code sign with entitlements.
# Virtualization.framework requires com.apple.security.virtualization.
# Set CODESIGN_IDENTITY for Developer ID signing (required for iCloud,
# ASAuthorization/passkeys).
echo "Code signing with entitlements (identity: $SIGN_ID)..."
codesign --force --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" --options runtime "$APP_BUNDLE"

echo ""
echo "=== Build Complete ==="
echo ""
echo "App bundle: $APP_BUNDLE"
echo ""

if [ "$TARGET" = "bromure" ]; then
    echo "Usage:"
    echo "  # Linux/Chromium (recommended — fast boot):"
    echo "  $MACOS_DIR/$PRODUCT_NAME init                    # download Alpine + install Chromium"
    echo "  $MACOS_DIR/$PRODUCT_NAME run                     # launch ephemeral Chromium session"
    echo ""
    echo "  # macOS/Safari (slower, requires setup):"
    echo "  $MACOS_DIR/$PRODUCT_NAME init --os macOS         # download and install macOS"
    echo "  $MACOS_DIR/$PRODUCT_NAME setup                   # complete macOS Setup Assistant"
    echo "  $MACOS_DIR/$PRODUCT_NAME run --os macOS           # launch ephemeral Safari session"
    echo ""
    echo "  # Options:"
    echo "  $MACOS_DIR/$PRODUCT_NAME run --persist ~/s.img   # keep session disk"
    echo ""
    echo "Or run the app bundle directly:"
    echo "  open \"$APP_BUNDLE\" --args run"
else
    echo "Usage:"
    echo "  open \"$APP_BUNDLE\""
fi
