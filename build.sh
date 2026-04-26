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
        ;;
    *)
        echo "Usage: $0 [bromure|bromure-ac]" >&2
        exit 2
        ;;
esac

echo "=== Building $APP_NAME ($PRODUCT_NAME) ==="

# Build the requested product in release mode.
swift build -c release --arch arm64 --product "$PRODUCT_NAME" 2>&1

BUILD_DIR=$(swift build -c release --arch arm64 --show-bin-path 2>/dev/null)
BINARY="$BUILD_DIR/$PRODUCT_NAME"

if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    exit 1
fi

echo "Binary built at: $BINARY"

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

# Copy the per-target icon as AppIcon.icns (matching CFBundleIconFile in
# both Info.plists). Fall back to the shared icon if the target-specific
# one is missing.
if [ -f "$ICON_FILE" ]; then
    cp "$ICON_FILE" "$RESOURCES_DIR/AppIcon.icns"
elif [ -f "$SCRIPT_DIR/Resources/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
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
