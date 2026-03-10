# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bromure is a macOS app that runs ephemeral Chromium browser sessions inside disposable Linux VMs using Apple's Virtualization.framework. Each session starts from a clean base image (APFS CoW clone), and all data is destroyed when the window closes. Apple Silicon only, macOS 14+.

## Build & Test Commands

```bash
# Build (creates app bundle at .build/arm64-apple-macosx/release/Bromure.app)
./build.sh

# Run tests (Swift Testing framework, not XCTest)
swift test

# Run a single test suite
swift test --filter VMConfigTests

# Run a single test
swift test --filter "VMConfigTests/Default initializer uses sensible defaults"

# Debug build only (no app bundle)
swift build
```

The `build.sh` script does: release build → create .app bundle → copy resources → ad-hoc codesign with virtualization entitlement. E2E tests expect the app bundle from `./build.sh` to exist.

## Architecture

**Three SPM targets** (defined in `Package.swift`):
- **`bromure`** (executable, `Sources/CLI/`) — App entry point, SwiftUI views, AppKit window management. `SafariSandbox.swift` is the main entry point containing the app delegate and NSApplication setup.
- **`SandboxEngine`** (library, `Sources/SandboxEngine/`) — Core VM lifecycle, image management, file transfer, profiles. Contains an SPM resource bundle (`Resources/vm-setup/`) with guest OS setup scripts, configs, and a Python file transfer agent.
- **`HostServices`** (library, `Sources/HostServices/`) — Host-side clipboard bridge.

**Key data flow**: `AppState` (@Observable) → `VMPool` (pre-warms VMs) → `LinuxSandboxVM` (configures VZ) → `SandboxVM` (lifecycle) → `EphemeralDisk` (APFS CoW clone). Settings stored in UserDefaults; profiles persisted as JSON in `~/Library/Application Support/Bromure/profiles/`.

**VM pool pattern**: `VMPool` maintains a pre-booted VM so new browser windows open in <1s. When a VM is claimed, the pool immediately starts warming a replacement.

**Guest communication**: Host ↔ guest uses virtio sockets (vsock) for clipboard sharing (`ClipboardBridge`), file transfer (`FileTransferBridge` + `file-agent.py`), and boot detection.

## Code Conventions

- Swift 5.9, heavy use of Swift concurrency (async/await, @MainActor, Task)
- `@unchecked Sendable` on types wrapping VZ/AppKit APIs that require main thread
- AppKit + SwiftUI hybrid: SwiftUI views embedded via NSHostingView
- Tests use Swift Testing (`@Suite`, `@Test`, `#expect`) — not XCTest
- Only dependency: `swift-argument-parser` for CLI subcommands (`init`, `run`, `setup`)
- Entitlements required: `com.apple.security.virtualization` (in `Sources/CLI/SafariSandbox.entitlements`)

## Important Constraints

- Virtualization.framework APIs must run on the real main thread (DispatchQueue.main), not just @MainActor
- Retired VM sessions are kept alive (not deallocated) to prevent VZ dispatch source use-after-free crashes
- The SPM resource bundle (`Bundle.module`) must be copied into the app bundle by `build.sh` — without this, the app crashes on clean systems
- Bundle ID: `io.bromure.app`
