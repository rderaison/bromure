#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Per-target config — same dispatch idea as build.sh. Add a new case
# here when a third sibling app gets a release pipeline.
TARGET="${1:-bromure}"
case "$TARGET" in
    bromure)
        PRODUCT_NAME="bromure"
        APP_NAME="Bromure"
        SOURCE_DIR="$SCRIPT_DIR/Sources/Browser"
        ENTITLEMENTS="$SOURCE_DIR/SafariSandbox.entitlements"
        INFO_PLIST="$SOURCE_DIR/Info.plist"
        SDEF_FILE="$SOURCE_DIR/Bromure.sdef"
        ICON_FILE="$SCRIPT_DIR/Resources/AppIcon.icns"
        DMG_NAME="Bromure.dmg"
        RESOURCE_BUNDLE_NAME="bromure_bromure.bundle"
        ;;
    bromure-ac)
        PRODUCT_NAME="bromure-ac"
        APP_NAME="Bromure Agentic Coding"
        SOURCE_DIR="$SCRIPT_DIR/Sources/AgentCoding"
        ENTITLEMENTS="$SOURCE_DIR/BromureAC.entitlements"
        INFO_PLIST="$SOURCE_DIR/Info.plist"
        SDEF_FILE=""
        ICON_FILE="$SCRIPT_DIR/Resources/BromureACIcon.icns"
        DMG_NAME="BromureAgenticCoding.dmg"
        RESOURCE_BUNDLE_NAME="bromure_bromure-ac.bundle"
        ;;
    *)
        echo "Usage: $0 [bromure|bromure-ac]" >&2
        exit 2
        ;;
esac

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
#   ./package.sh [bromure|bromure-ac]

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
    echo "  ./package.sh [bromure|bromure-ac]"
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
echo "=== Building $APP_NAME ($PRODUCT_NAME) ==="
swift build -c release --arch arm64 --product "$PRODUCT_NAME" 2>&1

BUILD_DIR=$(swift build -c release --arch arm64 --show-bin-path 2>/dev/null)
BINARY="$BUILD_DIR/$PRODUCT_NAME"

if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    exit 1
fi

echo "Binary: $BINARY"

# --- Create app bundle ---
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "=== Creating app bundle ==="
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BINARY" "$MACOS_DIR/$PRODUCT_NAME"
cp "$INFO_PLIST" "$CONTENTS/Info.plist"

# SPM omits the standard app rpath; add it so dyld can resolve
# @rpath/Sparkle.framework/... to Contents/Frameworks/.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$PRODUCT_NAME" 2>/dev/null || true

# Embed provisioning profile (required for iCloud and other entitlements).
# Per-product profile if present (e.g. bromure-ac.provisionprofile),
# else fall back to the shared bromure.provisionprofile.
PROVISION_PROFILE="$SCRIPT_DIR/$PRODUCT_NAME.provisionprofile"
[ -f "$PROVISION_PROFILE" ] || PROVISION_PROFILE="$SCRIPT_DIR/bromure.provisionprofile"
if [ ! -f "$PROVISION_PROFILE" ]; then
    echo "ERROR: Provisioning profile not found at $PROVISION_PROFILE"
    exit 1
fi
cp "$PROVISION_PROFILE" "$CONTENTS/embedded.provisionprofile"

if [ -f "$ICON_FILE" ]; then
    cp "$ICON_FILE" "$RESOURCES_DIR/AppIcon.icns"
fi

# Browser-only: AppleScript scripting definition.
if [ -n "$SDEF_FILE" ] && [ -f "$SDEF_FILE" ]; then
    cp "$SDEF_FILE" "$RESOURCES_DIR/$(basename "$SDEF_FILE")"
fi

# Copy SPM resource bundles into Contents/Resources/.
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$RESOURCES_DIR/"
done

# Copy localization .lproj directories into the app bundle so Bundle.main can find them.
# SwiftUI looks up localized strings in Bundle.main, not Bundle.module.
if [ -d "$BUILD_DIR/$RESOURCE_BUNDLE_NAME" ]; then
    for lproj in "$BUILD_DIR/$RESOURCE_BUNDLE_NAME"/*.lproj; do
        [ -d "$lproj" ] && cp -R "$lproj" "$RESOURCES_DIR/"
    done
fi

# Copy SPM-provided frameworks (Sparkle, etc.) into Contents/Frameworks.
# Filter to frameworks the binary actually links — the shared $BUILD_DIR
# may contain leftover frameworks from the sibling target's build.
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

# --- Sign ---
echo "=== Signing with: $DEVELOPER_ID ==="

# Sign nested code inside any embedded frameworks first (inside-out ordering
# is required for notarisation). Sparkle.framework ships helper tools and
# XPC services that each need their own signature with the hardened runtime
# option before we sign the framework bundle itself.
if [ -d "$FRAMEWORKS_DIR" ]; then
    for fw in "$FRAMEWORKS_DIR"/*.framework; do
        [ -d "$fw" ] || continue
        VB="$fw/Versions/B"
        [ -d "$VB" ] || VB="$fw/Versions/A"

        # XPC services
        if [ -d "$VB/XPCServices" ]; then
            for xpc in "$VB/XPCServices"/*.xpc; do
                [ -e "$xpc" ] && codesign --force --options runtime \
                    --timestamp --sign "$DEVELOPER_ID" "$xpc"
            done
        fi
        # Helper tools (Sparkle's Autoupdate, Updater.app, etc.)
        for helper in "$VB/Autoupdate" "$VB/Updater.app"; do
            [ -e "$helper" ] && codesign --force --options runtime \
                --timestamp --sign "$DEVELOPER_ID" "$helper"
        done
        # Framework bundle itself (last within the framework).
        codesign --force --options runtime \
            --timestamp --sign "$DEVELOPER_ID" "$fw"
    done
fi

# Finally sign the outer app with entitlements.
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
DMG_RW="$BUILD_DIR/${PRODUCT_NAME}_rw.dmg"

rm -rf "$DMG_DIR" "$DMG_PATH" "$DMG_RW"
mkdir -p "$DMG_DIR/.background"

# Copy app into staging
cp -R "$APP_BUNDLE" "$DMG_DIR/"

# Create Applications symlink for drag-to-install
ln -s /Applications "$DMG_DIR/Applications"

# Generate a background image with a drag arrow using Swift
swift -e '
import Cocoa
let W = 660, H = 400
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
// White background
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
// Arrow
ctx.setStrokeColor(CGColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1))
ctx.setLineWidth(4)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 240, y: 200))
ctx.addLine(to: CGPoint(x: 400, y: 200))
ctx.strokePath()
ctx.move(to: CGPoint(x: 380, y: 220))
ctx.addLine(to: CGPoint(x: 400, y: 200))
ctx.addLine(to: CGPoint(x: 380, y: 180))
ctx.strokePath()
NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "'"$DMG_DIR"'/.background/bg.png"))
'

# Create a read-write DMG first
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDRW \
    "$DMG_RW"

# Mount the read-write DMG. hdiutil emits tab-separated columns; default
# awk would split on whitespace and lose everything after the first space
# in volume names like "Bromure Agentic Coding". We capture both the
# /dev/diskN identifier (for a clean detach later) and the mount point.
ATTACH_OUTPUT=$(hdiutil attach -readwrite -noverify "$DMG_RW")
DISK_DEV=$(echo "$ATTACH_OUTPUT" | grep -E '^/dev/disk[0-9]+\s' | head -1 | awk '{print $1}')
MOUNT_DIR=$(echo "$ATTACH_OUTPUT" | grep "/Volumes/$APP_NAME" | awk -F'\t' '{print $NF}')
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

# Detach reliably. Two issues we've hit: (1) Finder may still hold the
# window open, so plain `hdiutil detach` fails with "resource busy" and
# the buffer cache is never flushed — the .DS_Store written by the
# AppleScript step ends up missing from the final DMG; (2) detaching
# the volume mount-point can leave the underlying /dev/diskN attached.
# Solution: detach the whole disk device (not just the mount point)
# with `-force` so open file handles don't block the unmount.
sync
for i in 1 2 3 4 5; do
    if hdiutil detach "$DISK_DEV" 2>/dev/null; then
        break
    fi
    sleep 2
    if [ "$i" = "5" ]; then
        echo "Forcing detach of $DISK_DEV..."
        hdiutil detach -force "$DISK_DEV"
    fi
done

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
echo "Distribute this file. Users open the DMG and drag $APP_NAME to Applications."
