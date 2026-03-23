# Build Instructions

## Prerequisites

- macOS 14.0+, Apple Silicon Mac
- Xcode Command Line Tools (`xcode-select --install`)
- An [Apple Developer Program](https://developer.apple.com/programs/) membership ($99/year) — required for the entitlements and provisioning profile

## Apple Developer Entitlements

Bromure requires several entitlements that must be registered in your Apple Developer account. Go to [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/) and configure the following.

### 1. Register an App ID

Under **Identifiers**, create an App ID with:

- **Bundle ID:** Create a new bundle ID (I'm using `io.bromure.app`)
- **App ID Prefix / Team ID:** your 10-character team ID (e.g. `W3RD8G85BC`)

Enable these **Capabilities** on the App ID:

| Capability | Why |
|---|---|
| **iCloud** (CloudKit + iCloud Documents) | Syncing profile definitions across Macs |
| **Network Extensions** / vmnet | Host-side network filtering for LAN isolation |

### 2. Create a Provisioning Profile

Under **Profiles**, create a **Developer ID** provisioning profile:

- **Type:** Developer ID Application
- **App ID:** The Bundle ID you picked (`io.bromure.app` in my case)
- **Certificate:** your "Developer ID Application" certificate (see below)

Download the `.provisionprofile` file and save it as:

```
bromure.provisionprofile      # in the repository root
```

The build scripts embed this into the app bundle as `Contents/embedded.provisionprofile`. Without it, iCloud and vmnet entitlements will not work at runtime.

### 3. Create a Developer ID Certificate

Under **Certificates**, if you don't already have one, create a **Developer ID Application** certificate. This is the identity used for code signing. You can list your available identities with:

```bash
security find-identity -v -p codesigning
```

Look for a line like:

```
"Developer ID Application: Your Name (TEAM_ID)"
```

## Entitlements File

The entitlements are defined in `Sources/CLI/SafariSandbox.entitlements`. For reference, it requests:

| Entitlement | Purpose |
|---|---|
| `com.apple.security.virtualization` | Virtualization.framework access |
| `com.apple.application-identifier` | App identity (must match provisioning profile) |
| `com.apple.developer.team-identifier` | Team identity |
| `com.apple.developer.ubiquity-container-identifiers` | iCloud Documents container |
| `com.apple.developer.icloud-container-identifiers` | iCloud container |
| `com.apple.developer.icloud-services` | iCloud services |
| `com.apple.developer.icloud-container-environment` | iCloud production environment |
| `com.apple.developer.networking.vmnet` | vmnet framework for network filtering |
| `com.apple.security.device.camera` | Webcam passthrough to VM |
| `com.apple.security.device.audio-input` | Microphone passthrough to VM |

You should not need to edit this file unless you are changing the bundle ID or team ID.

## File Layout

```
bromure/
  bromure.provisionprofile          # downloaded from Apple Developer portal
  Sources/CLI/
    SafariSandbox.entitlements       # entitlements plist (checked in)
    Info.plist                       # app bundle metadata (checked in)
  build.sh                           # local development build
  package.sh                         # release build + notarization + DMG
```

## Building

### Development Build (`build.sh`)

Builds the binary and creates a `.app` bundle with code signing:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAM_ID)" ./build.sh
```

If `CODESIGN_IDENTITY` is not set, it falls back to ad-hoc signing (`-`), which is sufficient for local testing but will not satisfy Gatekeeper or enable iCloud/vmnet.

**Environment variables:**

| Variable | Required | Description |
|---|---|---|
| `CODESIGN_IDENTITY` | No (defaults to `-`) | Code signing identity |

The app bundle is created at `.build/arm64-apple-macosx/release/Bromure.app`.

### Release Build (`package.sh`)

Builds, signs, notarizes, and packages into a DMG for distribution:

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAM_ID)" \
APPLE_ID="you@example.com" \
TEAM_ID="ABC123XYZ" \
APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
./package.sh
```

**Environment variables:**

| Variable | Required | Description |
|---|---|---|
| `DEVELOPER_ID` | Yes | Code signing identity (same format as `CODESIGN_IDENTITY`) |
| `APPLE_ID` | For notarization | Your Apple ID email |
| `TEAM_ID` | For notarization | Your 10-character Apple Developer team ID |
| `APP_PASSWORD` | For notarization | App-specific password ([generate here](https://appleid.apple.com) > Sign-In and Security > App-Specific Passwords) |

If `APPLE_ID`, `TEAM_ID`, or `APP_PASSWORD` are missing, the script will still sign and package but skip notarization. The resulting DMG will trigger Gatekeeper warnings on other Macs.

The DMG is created at `.build/arm64-apple-macosx/release/Bromure.dmg`.
