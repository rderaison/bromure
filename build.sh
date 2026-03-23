#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_NAME="bromure"
APP_NAME="Bromure"
ENTITLEMENTS="$SCRIPT_DIR/Sources/CLI/SafariSandbox.entitlements"
INFO_PLIST="$SCRIPT_DIR/Sources/CLI/Info.plist"

echo "=== Building Bromure ==="

# Build in release mode
swift build -c release --arch arm64 2>&1

BUILD_DIR=$(swift build -c release --arch arm64 --show-bin-path 2>/dev/null)
BINARY="$BUILD_DIR/$PRODUCT_NAME"

if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    exit 1
fi

echo "Binary built at: $BINARY"

# Signing identity: use CODESIGN_IDENTITY env var, or fall back to ad-hoc (-)
SIGN_ID="${CODESIGN_IDENTITY:--}"

# Sign the standalone binary too (for direct invocation without the app bundle)
SIGN_ID="${CODESIGN_IDENTITY:--}"
echo "Code signing standalone binary..."
codesign --force --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" "$BINARY"

# Create a minimal .app bundle so macOS treats this as a GUI application.
# This is needed for:
# 1. The Dock icon to appear
# 2. NSApplication to work properly
# 3. Window focus to work correctly
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"

echo "Creating app bundle at: $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"

cp "$BINARY" "$MACOS_DIR/$PRODUCT_NAME"
cp "$INFO_PLIST" "$CONTENTS/Info.plist"

# Embed provisioning profile (required for iCloud and other entitlements)
PROVISION_PROFILE="$SCRIPT_DIR/bromure.provisionprofile"
if [ -f "$PROVISION_PROFILE" ]; then
    cp "$PROVISION_PROFILE" "$CONTENTS/embedded.provisionprofile"
fi

# Copy app icon into Resources
RESOURCES_DIR="$CONTENTS/Resources"
mkdir -p "$RESOURCES_DIR"
ICON_FILE="$SCRIPT_DIR/Resources/AppIcon.icns"
if [ -f "$ICON_FILE" ]; then
    cp "$ICON_FILE" "$RESOURCES_DIR/AppIcon.icns"
fi

# Copy AppleScript scripting definition
SDEF_FILE="$SCRIPT_DIR/Sources/CLI/Bromure.sdef"
if [ -f "$SDEF_FILE" ]; then
    cp "$SDEF_FILE" "$RESOURCES_DIR/Bromure.sdef"
fi

# Copy SPM resource bundles (needed for vm-setup resources at runtime).
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$RESOURCES_DIR/"
done

# Copy localization .lproj directories into the app bundle so Bundle.main can find them.
# SwiftUI looks up localized strings in Bundle.main, not Bundle.module.
for lproj in "$BUILD_DIR"/bromure_bromure.bundle/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$RESOURCES_DIR/"
done

# Code sign with entitlements.
# Virtualization.framework requires the com.apple.security.virtualization entitlement.
# Set CODESIGN_IDENTITY for Developer ID signing (required for iCloud, ASAuthorization/passkeys).
echo "Code signing with entitlements (identity: $SIGN_ID)..."
codesign --force --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" --options runtime "$APP_BUNDLE"

echo ""
echo "=== Build Complete ==="
echo ""
echo "App bundle: $APP_BUNDLE"
echo ""
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
echo "  open $APP_BUNDLE --args run"
