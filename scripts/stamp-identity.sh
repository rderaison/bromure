#!/bin/bash
# stamp-identity.sh — write a build's signing identity into copies of its
# entitlements and Info.plist, so a contributor can sign under their own
# Apple Developer team without editing the tracked files.
#
#   BROMURE_TEAM_ID    the 10-character team ID; default: the one in the
#                      tracked entitlements (upstream's).
#   BROMURE_BUNDLE_ID  the bundle identifier; default: CFBundleIdentifier in
#                      the tracked Info.plist.
#
# With neither set, both files are copied verbatim. With either set, the
# copies get:
#   entitlements  com.apple.application-identifier   = TEAM.BUNDLE
#                 com.apple.developer.team-identifier = TEAM
#                 keychain-access-groups[0]           = TEAM.BUNDLE
#                 (each only when the tracked file has the key; the Sidecar
#                 entitlements have none)
#   Info.plist    CFBundleIdentifier                  = BUNDLE
#
# iCloud container identifiers (the browser's iCloud.io.bromure.app) are left
# alone: a team that registered its own containers edits the tracked file.
# The embedded provisioning profile (*.provisionprofile, gitignored) must
# match the resulting application identifier.
#
# Usage: stamp-identity.sh <entitlements-in> <Info.plist-in> \
#                          <entitlements-out> <Info.plist-out>
set -euo pipefail

ENT_IN="$1"; PLIST_IN="$2"; ENT_OUT="$3"; PLIST_OUT="$4"
PB=/usr/libexec/PlistBuddy

cp "$ENT_IN" "$ENT_OUT"
cp "$PLIST_IN" "$PLIST_OUT"

if [ -z "${BROMURE_TEAM_ID:-}" ] && [ -z "${BROMURE_BUNDLE_ID:-}" ]; then
    exit 0
fi

default_team=$($PB -c "Print :com.apple.developer.team-identifier" "$ENT_IN" 2>/dev/null || true)
default_bundle=$($PB -c "Print :CFBundleIdentifier" "$PLIST_IN")
TEAM="${BROMURE_TEAM_ID:-$default_team}"
BUNDLE="${BROMURE_BUNDLE_ID:-$default_bundle}"

if [ "$TEAM" != "${TEAM//[^A-Z0-9]/}" ] || [ ${#TEAM} -ne 10 ]; then
    echo "error: BROMURE_TEAM_ID must be a 10-character Apple team ID, got '$TEAM'" >&2
    exit 2
fi

set_if_present() {  # <file> <key> <value>: rewrite a key the tracked file has
    if $PB -c "Print :$2" "$1" >/dev/null 2>&1; then
        $PB -c "Set :$2 $3" "$1"
    fi
}

set_if_present "$ENT_OUT" "com.apple.application-identifier" "$TEAM.$BUNDLE"
set_if_present "$ENT_OUT" "com.apple.developer.team-identifier" "$TEAM"
set_if_present "$ENT_OUT" "keychain-access-groups:0" "$TEAM.$BUNDLE"
$PB -c "Set :CFBundleIdentifier $BUNDLE" "$PLIST_OUT"

echo "Signing identity: $TEAM.$BUNDLE"
