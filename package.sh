#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_NAME="bromure"
APP_NAME="Bromure"
ENTITLEMENTS="$SCRIPT_DIR/Sources/CLI/SafariSandbox.entitlements"
INFO_PLIST="$SCRIPT_DIR/Sources/CLI/Info.plist"
ICON_FILE="$SCRIPT_DIR/Resources/AppIcon.icns"
DMG_NAME="Bromure.dmg"

# --- Configuration ---
# Set these via environment variables or edit here:
#   DEVELOPER_ID   - signing identity, e.g. "Developer ID Application: Your Name (TEAM_ID)"
#   APPLE_ID       - your Apple ID email for notarization
#   TEAM_ID        - your Apple Developer team ID
#   APP_PASSWORD   - app-specific password for notarization
#                    (generate at https://appleid.apple.com > Sign-In and Security > App-Specific Passwords)
#
# Example:
#   DEVELOPER_ID="Developer ID Application: Jane Doe (ABC123XYZ)" \
#   APPLE_ID="jane@example.com" \
#   TEAM_ID="ABC123XYZ" \
#   APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
#   ./package.sh

DEVELOPER_ID="${DEVELOPER_ID:-}"
APPLE_ID="${APPLE_ID:-}"
TEAM_ID="${TEAM_ID:-}"
APP_PASSWORD="${APP_PASSWORD:-}"

# --- Validation ---
if [ -z "$DEVELOPER_ID" ]; then
    echo "ERROR: DEVELOPER_ID is not set."
    echo ""
    echo "Usage:"
    echo "  DEVELOPER_ID=\"Developer ID Application: Your Name (TEAM_ID)\" \\"
    echo "  APPLE_ID=\"you@example.com\" \\"
    echo "  TEAM_ID=\"ABC123XYZ\" \\"
    echo "  APP_PASSWORD=\"xxxx-xxxx-xxxx-xxxx\" \\"
    echo "  ./package.sh"
    echo ""
    echo "List available identities with:"
    echo "  security find-identity -v -p codesigning"
    exit 1
fi

if [ -z "$APPLE_ID" ] || [ -z "$TEAM_ID" ] || [ -z "$APP_PASSWORD" ]; then
    echo "WARNING: APPLE_ID, TEAM_ID, or APP_PASSWORD not set — will skip notarization."
    echo "         The app will be signed but may trigger Gatekeeper warnings on other Macs."
    NOTARIZE=false
else
    NOTARIZE=true
fi

# --- Build ---
echo "=== Building $APP_NAME ==="
swift build -c release --arch arm64 2>&1

BUILD_DIR=$(swift build -c release --arch arm64 --show-bin-path 2>/dev/null)
BINARY="$BUILD_DIR/$PRODUCT_NAME"

if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    exit 1
fi

echo "Binary: $BINARY"

# --- Create app bundle ---
APP_BUNDLE="$BUILD_DIR/$PRODUCT_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "=== Creating app bundle ==="
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BINARY" "$MACOS_DIR/$PRODUCT_NAME"
cp "$INFO_PLIST" "$CONTENTS/Info.plist"

# Embed provisioning profile (required for iCloud and other entitlements)
PROVISION_PROFILE="$SCRIPT_DIR/bromure.provisionprofile"
if [ ! -f "$PROVISION_PROFILE" ]; then
    echo "ERROR: Provisioning profile not found at $PROVISION_PROFILE"
    exit 1
fi
cp "$PROVISION_PROFILE" "$CONTENTS/embedded.provisionprofile"

if [ -f "$ICON_FILE" ]; then
    cp "$ICON_FILE" "$RESOURCES_DIR/AppIcon.icns"
fi

# Copy AppleScript scripting definition
SDEF_FILE="$SCRIPT_DIR/Sources/CLI/Bromure.sdef"
if [ -f "$SDEF_FILE" ]; then
    cp "$SDEF_FILE" "$RESOURCES_DIR/Bromure.sdef"
fi

# Copy SPM resource bundles into Contents/Resources/.
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$RESOURCES_DIR/"
done

# Copy localization .lproj directories into the app bundle so Bundle.main can find them.
# SwiftUI looks up localized strings in Bundle.main, not Bundle.module.
for lproj in "$BUILD_DIR"/bromure_bromure.bundle/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$RESOURCES_DIR/"
done

# --- Sign ---
echo "=== Signing with: $DEVELOPER_ID ==="

codesign --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID" \
    "$APP_BUNDLE"

echo "Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
spctl --assess --type exec --verbose=2 "$APP_BUNDLE" 2>&1 || true

# --- Notarize ---
if [ "$NOTARIZE" = true ]; then
    echo "=== Notarizing ==="

    # Create a zip for submission
    NOTARIZE_ZIP="$BUILD_DIR/$PRODUCT_NAME-notarize.zip"
    ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"

    echo "Submitting to Apple (this may take a few minutes)..."
    xcrun notarytool submit "$NOTARIZE_ZIP" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait

    rm -f "$NOTARIZE_ZIP"

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$APP_BUNDLE"

    echo "Verifying notarization..."
    spctl --assess --type exec --verbose=2 "$APP_BUNDLE"
else
    echo "=== Skipping notarization (credentials not provided) ==="
fi

# --- Create DMG ---
echo "=== Creating DMG ==="

DMG_DIR="$BUILD_DIR/dmg-staging"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
DMG_RW="$BUILD_DIR/${APP_NAME}_rw.dmg"

rm -rf "$DMG_DIR" "$DMG_PATH" "$DMG_RW"
mkdir -p "$DMG_DIR/.background"

# Copy app into staging
cp -R "$APP_BUNDLE" "$DMG_DIR/"

# Create Applications symlink for drag-to-install
ln -s /Applications "$DMG_DIR/Applications"

# Generate a background image with a drag arrow using Python/CoreGraphics
python3 -c "
import objc
from Quartz import *
from CoreText import *

W, H = 660, 400
cs = CGColorSpaceCreateDeviceRGB()
ctx = CGBitmapContextCreate(None, W, H, 8, W*4, cs, kCGImageAlphaPremultipliedLast)

# White background
CGContextSetRGBFillColor(ctx, 1, 1, 1, 1)
CGContextFillRect(ctx, CGRectMake(0, 0, W, H))

# Draw arrow from left icon area to right icon area
# Arrow body
CGContextSetRGBStrokeColor(ctx, 0.6, 0.6, 0.6, 1)
CGContextSetLineWidth(ctx, 4)
CGContextSetLineCap(ctx, kCGLineCapRound)

# Horizontal line (y=200 is vertical center, from x=240 to x=420)
CGContextMoveToPoint(ctx, 240, 200)
CGContextAddLineToPoint(ctx, 400, 200)
CGContextStrokePath(ctx)

# Arrowhead
CGContextMoveToPoint(ctx, 380, 220)
CGContextAddLineToPoint(ctx, 400, 200)
CGContextAddLineToPoint(ctx, 380, 180)
CGContextStrokePath(ctx)

# Save as PNG
image = CGBitmapContextCreateImage(ctx)
url = CFURLCreateWithFileSystemPath(None, '$DMG_DIR/.background/bg.png', kCFURLPOSIXPathStyle, False)
dest = CGImageDestinationCreateWithURL(url, 'public.png', 1, None)
CGImageDestinationAddImage(dest, image, None)
CGImageDestinationFinalize(dest)
"

# Create a read-write DMG first
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDRW \
    "$DMG_RW"

# Mount the read-write DMG
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "$DMG_RW" | grep "/Volumes/$APP_NAME" | awk '{print $NF}')
# Wait for Finder to register the volume
sleep 2

# Use AppleScript to set icon size, positions, and background
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 760, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to file ".background:bg.png"
        set position of item "$APP_NAME.app" of container window to {165, 200}
        set position of item "Applications" of container window to {495, 200}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

# Ensure .background and .DS_Store are hidden
SetFile -a V "$MOUNT_DIR/.background" 2>/dev/null || true

sync
hdiutil detach "$MOUNT_DIR"

# Convert to compressed read-only DMG
hdiutil convert "$DMG_RW" -format UDZO -o "$DMG_PATH"
rm -f "$DMG_RW"
rm -rf "$DMG_DIR"

# Sign the DMG itself
codesign --force --sign "$DEVELOPER_ID" "$DMG_PATH"

# Notarize the DMG too
if [ "$NOTARIZE" = true ]; then
    echo "Notarizing DMG..."
    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait

    xcrun stapler staple "$DMG_PATH"
fi

echo ""
echo "=== Done ==="
echo ""
echo "DMG: $DMG_PATH"
echo ""
echo "Distribute this file. Users open the DMG and drag Bromure to Applications."
