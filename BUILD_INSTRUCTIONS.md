# Build Instructions

## Prerequisites

- macOS 14.0+, Apple Silicon Mac
- Xcode Command Line Tools (`xcode-select --install`)
- An [Apple Developer Program](https://developer.apple.com/programs/) membership ($99/year) — required for the entitlements and provisioning profile

## GhosttyKit (bromure-ac native terminals)

`bromure-ac` links **GhosttyKit** (libghostty) as an SPM binary target at
`vendor/GhosttyKit.xcframework`. It is **not** committed; `./build.sh` builds
it automatically on first run via `tools/build-ghostty.sh`, which:

- downloads a pinned zig toolchain into `~/.cache/bromure-ghostty`,
- fetches ghostty at the commit pinned in `tools/ghostty.commit`,
- builds `GhosttyKit.xcframework` and stages it (plus terminal runtime
  resources) into `vendor/`.

First build takes a few minutes; afterwards it's a no-op keyed on the pinned
commit. `swift build` / `swift test` also need `vendor/` present — run
`./tools/build-ghostty.sh` once if you skip `build.sh`. CI should cache
`~/.cache/bromure-ghostty` (the zig toolchain and source); if it caches
`vendor/` too, key it on `tools/ghostty.commit` **and** the `BUILD_FLAGS` in
`tools/build-ghostty.sh` — not on the commit alone — and still run the script
(or `build.sh`, which always does): it compares the framework's stamp
(`vendor/GhosttyKit.xcframework/.bromure-ghostty-commit`, commit + flags) and
rebuilds a stale one, e.g. one built before `-Dsentry=false`.
The script self-heals two Xcode 26 toolchain issues: SDKs whose tbds dropped
the `arm64-macos` slice (zig #31658) and libtool dropping zig's misaligned
archive members; see the comments in `tools/build-ghostty.sh`.

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

You should not need to edit this file. To sign under a different team or bundle ID, see [Building under your own team](#building-under-your-own-team) below.

## Building under your own team

The tracked entitlements and Info.plist carry the upstream team ID and bundle IDs. Don't edit them: the build scripts write your identity into build-dir copies instead, driven by two variables.

| Variable | Description |
|---|---|
| `BROMURE_TEAM_ID` | Your 10-character Apple Developer team ID |
| `BROMURE_BUNDLE_ID` | The bundle ID you registered (one per target you build) |

They set `com.apple.application-identifier`, `com.apple.developer.team-identifier` and the keychain access group in the entitlements, and `CFBundleIdentifier` in the Info.plist (`scripts/stamp-identity.sh`). Your provisioning profile must be for that same team and bundle ID. iCloud container identifiers are not rewritten; if your team registered its own, edit the tracked entitlements locally.

Put them, with your signing identity, in `.env.local` at the repository root. It is gitignored and sourced by both `build.sh` and `package.sh`; a variable already set in the environment wins over the file.

```bash
# .env.local
CODESIGN_IDENTITY="Developer ID Application: Your Name (ABC123XYZ)"
BROMURE_TEAM_ID=ABC123XYZ
BROMURE_BUNDLE_ID=com.example.bromure-ac
BROMURE_DEV=1
```

Then `./build.sh bromure-ac` signs under your team with no other flags. Since the bundle ID is per target, keep one `.env.local` per target you build, or pass `BROMURE_BUNDLE_ID=… ./build.sh bromure` on the command line to override it.

### Dev flavor (`BROMURE_DEV=1`)

With `BROMURE_DEV=1` in `.env.local` (or the environment), `./build.sh bromure-ac` builds a copy that can run next to an installed release without touching it:

- named "Bromure AC Dev" in the menu bar and Dock ("Bromure Dev" for the browser, "Bromure Sidecar Dev" for Sidecar); the icon is unchanged;
- its data in `~/Library/Application Support/BromureACDev` and `~/Library/Logs/BromureACDev` (`BromureSupportDirName`), so it never reads or locks the release's data. A build signed by another team gets a different keychain master key and couldn't decrypt the release's files anyway;
- Sparkle's scheduled checks and automatic installs off, so a release update can never replace it. "Check for Updates…" still works by hand.

The bundle's file name is unchanged (`Bromure Agentic Coding.app`). The flavor is independent of the identity: a dev build under the upstream team is fine for local testing, and a release-flavored build under your own team is what `package.sh` produces.

### States: the data a build runs on

A build no longer owns its data folder. The **state** — profiles, VM disks, settings, secrets, traces — is chosen when the process starts:

| | |
|---|---|
| nothing set | the bundle's folder (`BromureAC`, or `BromureSupportDirName`): the **default state**, called `work`. A Dock launch opens it, as always. |
| `BROMURE_STATE=<name>` | `~/Library/Application Support/<folder>-states/<name>/` |
| `BROMURE_STATE_DIR=<dir>` | that directory |
| `--state <name\|dir>` | the same, on any `bromure-ac` command (it reaches that state's control socket, and the agent it autostarts inherits it) |

Each state has its own settings (a `UserDefaults` suite, `<bundle id>.state.<name>`; the default state keeps the bundle's own domain), its own logs (`<state>/logs/`; the default state's stay in `~/Library/Logs/<folder>`), its own control socket and, through the settings, its own VM subnet — so two instances on two states run at once. One instance per state: `run` takes `<state>/instance.lock` and a second launch exits with "state X is in use by pid N (build Y)"; `<state>/instance.json` names the holder, with the automation port it bound (`BROMURE_AC_AUTOMATION_PORT=0` binds an ephemeral one and a non-default state does so by default, on loopback). `POST /app/quit {"vms": "suspend"|"shutdown"}` on the control socket quits like the menu does, without the dialog, for scripts.

```bash
bromure-ac state ls                                   # every state, size, running instance
bromure-ac state create repro-42                      # new state with work's images/caches/models (clones, instant), nothing else
bromure-ac state create repro-43 --empty              # a fresh install; --assets-from <state> clones another state's assets
bromure-ac state create work-try --from work          # full clone, settings included (refused while work runs: --live)
bromure-ac --state repro-42 vm ls                     # drive the instance on that state
bromure-ac state snapshot work --label pre-upgrade    # APFS clone under <folder>-states/.snapshots/work/
bromure-ac state restore work latest                  # the replaced data is kept as a pre-restore snapshot
bromure-ac state schedule install work                # hourly snapshots (keep all <24h, hourly <7d, daily <30d)
bromure-ac state rm repro-42
```

Clones share keychain items (the secrets master key, workspace LUKS keys) with their source under the same signing team; nothing in the app deletes those on workspace removal, and `state rm` never touches the keychain.

### Builds and instances

`scripts/devbuild.sh <name> [<git-ref>]` (default `HEAD`, resolved to a commit when the script starts) builds an immutable bundle into `~/Library/Application Support/<folder>-builds/<name>/` from a git worktree (`.worktrees/<name>`, its own `.build`), with `build.json` beside it; `--prod agentic-coding-v5.4.0` names it `prod-5.4.0` and is cached. A ref that predates the states work gets those commits cherry-picked in the worktree first, so a release tag is buildable under your `.env.local` and drivable with `--state`. The `stable` symlink there is the build the default state runs on.

The CLI manages what it produced. `bromure-ac build ls` lists the builds with their roles; `build promote <name>` makes one stable (work is snapshotted with the new build's CLI under `pre-<name>`, its instance quits with every workspace suspended, `stable` and `stable.prev` are repointed, `~/.local/bin/bromure-ac` and the Finder alias in `~/Applications` are remade, work reopens on the new build); `build rollback` swaps `stable` and `stable.prev` the same way; `build prune` removes every other build and its devbuild worktree, keeping those with a running instance and the newest `prod-*`; `build link` remakes the two links by hand. The first build `devbuild.sh` makes becomes stable and gets the links.

`bromure-ac instance start [<state>] [--build <name>] [--gui|--hidden|--headless]` runs a build (default `stable`) on a state (default `work`) and waits for its `/health`. It launches through `open -n`, so the app is a LaunchServices child like a Dock launch, a new instance despite the shared bundle ID, and outlives the terminal; `--direct` spawns the binary instead. `work` starts with a window, any other state `--hidden` (no Dock presence, never takes focus, yet renders its windows for `/debug/ui-shot`). `instance stop [<state>] [--suspend|--shutdown]` quits it over its socket (each workspace's own close action unless overridden), `restart` does both, `ls` shows every state and its instance (`stale` marks a record left by an instance that died; the next `start` replaces it), `health` prints `/health`, `cli [<state>] -- vm ls` runs the serving build's CLI against the state, `bin-path` prints that CLI's path.

## File Layout

```
bromure/
  bromure-ac.provisionprofile        # downloaded from Apple Developer portal (gitignored; build.sh embeds it)
  .env.local                         # your signing identity and flavor (gitignored)
  Sources/Browser/                   # Bromure: entitlements, Info.plist
  Sources/AgentCoding/               # Bromure Agentic Coding: entitlements, Info.plist
  build.sh                           # local build: bromure | bromure-ac | sidecar
  package.sh                         # release build + notarization + DMG
  scripts/stamp-identity.sh          # writes your team/bundle ID into build-dir copies
  scripts/devbuild.sh                # named immutable builds from any git ref
  scripts/states-e2e.sh              # two instances on two states, side by side
```

## Building

### Development Build (`build.sh`)

Builds the binary and creates a `.app` bundle with code signing:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAM_ID)" ./build.sh            # Bromure
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAM_ID)" ./build.sh bromure-ac # Bromure Agentic Coding
```

The target is `bromure` (default), `bromure-ac` or `sidecar`. With `BROMURE_DEV=1` set, the build is the [dev flavor](#dev-flavor-bromure_dev1).

If `CODESIGN_IDENTITY` is not set, it falls back to ad-hoc signing (`-`), which is sufficient for local testing but will not satisfy Gatekeeper or enable iCloud/vmnet.

**Environment variables:**

| Variable | Required | Description |
|---|---|---|
| `CODESIGN_IDENTITY` | No (defaults to `-`) | Code signing identity |
| `BROMURE_TEAM_ID`, `BROMURE_BUNDLE_ID` | No | Sign under your own team ([above](#building-under-your-own-team)) |
| `BROMURE_DEV` | No | `1` for the dev flavor ([above](#dev-flavor-bromure_dev1)) |

All of them can live in `.env.local`. The bundle is created at `.build/arm64-apple-macosx/release/<App name>.app` (`Bromure.app`, `Bromure Agentic Coding.app`, `Bromure Sidecar.app`). `swift build` alone does not refresh it; run `build.sh`.

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
| `BROMURE_TEAM_ID`, `BROMURE_BUNDLE_ID` | No | Sign under your own team ([above](#building-under-your-own-team)) |

`package.sh` reads `.env.local` too.

If `APPLE_ID`, `TEAM_ID`, or `APP_PASSWORD` are missing, the script will still sign and package but skip notarization. The resulting DMG will trigger Gatekeeper warnings on other Macs.

The DMG is created at `.build/arm64-apple-macosx/release/Bromure.dmg`.

## Development workflow (Bromure Agentic Coding)

Every build you run is a named, immutable one, so the app you are working in is never rebuilt underneath you:

1. **Build**: `scripts/devbuild.sh <name> [<git-ref>]` builds the ref (`HEAD` by default) in its own worktree and copies the bundle into `<folder>-builds/<name>/` (see [Builds and instances](#builds-and-instances)). `.build/` in your checkout is only what `build.sh` leaves behind; nothing in this workflow runs it.
2. **Live in one**: `bromure-ac build promote <name>` makes it the stable build and reopens `work` on it, after snapshotting `work` (`pre-<name>`) and quitting the old instance with its VMs suspended; `bromure-ac build rollback` goes back to the previous one. Data is untouched by either, since it lives in the state. `bromure-ac build prune` clears the builds you no longer need.

`~/.local/bin/bromure-ac` is a symlink to the stable build's CLI (made by the first `devbuild.sh` and refreshed by every promote), so `bromure-ac` on your `PATH` always means the build you live in. A symlink to the binary has no bundle around it, so the CLI re-executes the real binary when started through one (the same arguments and environment; `Bundle.main` would otherwise find no Info.plist and read the default folder, bundle identifier and build name) — this is what also makes the app's `/usr/local/bin/bromure-cli` link work on a renamed build. The Finder alias in `~/Applications` is the same build for Spotlight and the Dock.

For a reproduction or scratch work, never use `work`; make a state and run a build on it:

```bash
bromure-ac state create repro-42                      # new state with work's images and caches cloned (--empty for none)
bromure-ac instance start repro-42 --build devbuild-02
bromure-ac instance cli repro-42 -- vm ls
bromure-ac instance stop repro-42; bromure-ac state rm repro-42
```

Stop instances with `bromure-ac instance stop` (or the app's own quit); never signal the process, and never `pkill bromure-ac`, which hits every instance. Quitting the `work` app stops or suspends its workspace VMs.

### Tests

```bash
swift test                           # unit tests (Swift Testing)
swift test --filter StateStoreTests  # one suite
scripts/states-e2e.sh [<build>]      # two instances on two states: health, ports, subnets, instance lock, instance cli, quit, state rm
```

`Tests/e2e.mjs` and `Tests/ac-e2e.mjs` expect a bundle from `build.sh`. The guest-side OpenShell suites (including the attestor binary-identity test) run with `scripts/openshell-guest/tests/run_all.sh`; some need root, so run them inside a VM.
