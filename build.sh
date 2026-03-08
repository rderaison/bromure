#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_NAME="bromure"
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

# Sign the standalone binary too (for direct invocation without the app bundle)
echo "Code signing standalone binary..."
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BINARY"

# Create a minimal .app bundle so macOS treats this as a GUI application.
# This is needed for:
# 1. The Dock icon to appear
# 2. NSApplication to work properly
# 3. Window focus to work correctly
APP_BUNDLE="$BUILD_DIR/$PRODUCT_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"

echo "Creating app bundle at: $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"

cp "$BINARY" "$MACOS_DIR/$PRODUCT_NAME"
cp "$INFO_PLIST" "$CONTENTS/Info.plist"

# Copy app icon into Resources
RESOURCES_DIR="$CONTENTS/Resources"
mkdir -p "$RESOURCES_DIR"
ICON_FILE="$SCRIPT_DIR/Resources/AppIcon.icns"
if [ -f "$ICON_FILE" ]; then
    cp "$ICON_FILE" "$RESOURCES_DIR/AppIcon.icns"
fi

# Code sign with entitlements.
# Virtualization.framework requires the com.apple.security.virtualization entitlement.
# Use ad-hoc signing (-) for local development, or replace with your identity.
echo "Code signing with entitlements..."
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

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
echo "  $MACOS_DIR/$PRODUCT_NAME run --no-network        # disable network"
echo "  $MACOS_DIR/$PRODUCT_NAME run --persist ~/s.img   # keep session disk"
echo ""
echo "Or run the app bundle directly:"
echo "  open $APP_BUNDLE --args run"
