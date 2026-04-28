# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repo ships two sibling macOS apps built on Apple's Virtualization.framework. Apple Silicon only, macOS 14+.

- **Bromure** (`bromure`) — every browser session runs in a throwaway Linux VM (Alpine + Chromium). Close the window, the VM is destroyed.
- **Bromure Agentic Coding** (`bromure-ac`) — sandboxed Ubuntu VM for AI coding agents (Claude Code, Codex), with a host-side MITM proxy that swaps fake credentials for real ones on the wire so secrets never enter the VM.

## Build & Test Commands

```bash
./build.sh                                 # build the browser app → .build/arm64-apple-macosx/release/Bromure.app
./build.sh bromure-ac                      # build the AC app → .build/.../Bromure Agentic Coding.app
swift build                                # debug build, no .app bundle
swift test                                 # Swift Testing (not XCTest)
swift test --filter VMConfigTests          # one suite
swift test --filter "VMConfigTests/Default initializer uses sensible defaults"  # one test
CODESIGN_IDENTITY="Developer ID …" ./build.sh   # signed build (ad-hoc by default)
```

`build.sh` does: release build → assemble .app → embed Sparkle/SPM frameworks (with rpath fixup) → copy SPM resource bundles + .lproj → codesign with the target's entitlements. The Browser app supports `init`, `run`, `setup` subcommands; the AC app supports `init`, `run`, `reset`. E2E tests expect `./build.sh` output to exist. Companion docs in the repo: `BUILD_INSTRUCTIONS.md`, `REMOTE_CONTROL.md`, `SETTINGS.md`, `TEST_PLAN.md`. CI: `Jenkinsfile`, `Jenkinsfile.ac`, `Jenkinsfile.e2e`, `Jenkinsfile.screenshots`.

## Architecture

**SPM targets** (see `Package.swift`):

| Target          | Path                     | Notes                                                                |
| --------------- | ------------------------ | -------------------------------------------------------------------- |
| `bromure`       | `Sources/Browser/`       | Browser app. Entry point `SafariSandbox.swift` (NSApplication setup) |
| `bromure-ac`    | `Sources/AgentCoding/`   | AC app. Entry point `BromureAC.swift`. Owns the MITM proxy (`Mitm/`) |
| `SandboxEngine` | `Sources/SandboxEngine/` | Shared VM lifecycle, image management, virtio bridges, VPN, profiles |
| `BrowserBridges`| `Sources/BrowserBridges/`| Browser-only bridges (CDP, credentials, passkeys, webcam, gestures…) |
| `HostServices`  | `Sources/HostServices/`  | Currently just `ClipboardBridge`                                     |
| `CVmnet`        | `Sources/CVmnet/`        | System library shim for Apple's `vmnet`                              |
| `BromureTests`  | `Tests/SafariSandboxTests/` | Test target                                                       |

**Key data flow** (browser): `AppState` (@Observable) → `VMPool` (pre-warms VMs) → `LinuxSandboxVM` (configures VZ) → `SandboxVM` (lifecycle) → `EphemeralDisk` (APFS CoW clone). Settings in UserDefaults; profiles persisted as JSON in `~/Library/Application Support/Bromure/profiles/`.

**VM pool pattern**: `VMPool` keeps a pre-booted VM warm so new windows open in <1s. When a VM is claimed, the pool starts warming a replacement.

**Guest ↔ host communication**: virtio sockets (vsock) carry clipboard (`ClipboardBridge`), file transfer (`FileTransferBridge` + `Resources/vm-setup/file-agent.py`), keyboard/scroll/shell, network refresh, mTLS reload, and boot detection. SandboxEngine also includes IKEv2/WireGuard VPN bridges, managed-profile sync (`ManagedProfile*`), and network healing.

**AC-specific**: a host-side MITM proxy (`Sources/AgentCoding/Mitm/`) intercepts the agent's outbound HTTPS, signs requests for real cloud APIs (AWS SigV4, etc.), and routes user-facing approvals through `ConsentBroker` / Approvals window. Fake credentials live in the guest; real ones never leave the host.

## Code Conventions

- Swift 5.9, heavy use of Swift concurrency (async/await, @MainActor, Task)
- `@unchecked Sendable` on types wrapping VZ/AppKit APIs that require main thread
- AppKit + SwiftUI hybrid: SwiftUI views embedded via `NSHostingView`
- Tests use Swift Testing (`@Suite`, `@Test`, `#expect`) — not XCTest
- Dependencies: `swift-argument-parser`, `Sparkle` (auto-update), `onnxruntime-swift-package-manager` (face-swap, phishing model), `BigInt`, `swift-certificates`, `swift-crypto`, `Yams`
- Entitlements per app: `Sources/Browser/SafariSandbox.entitlements`, `Sources/AgentCoding/BromureAC.entitlements`. Both require `com.apple.security.virtualization`.
- Localized strings live in `*.lproj/` under each app target (Browser is fully localized; AC partially)

## Important Constraints

- Virtualization.framework APIs must run on the real main thread (DispatchQueue.main), not just @MainActor
- Retired VM sessions are kept alive (not deallocated) to prevent VZ dispatch source use-after-free crashes
- SPM resource bundles (`bromure_bromure.bundle`, `bromure_bromure-ac.bundle`) must be copied into `Contents/Resources/` by `build.sh` — `Bundle.module` traps on a fresh .app launch otherwise. Each app has a guarded resource-bundle accessor that falls back to `Bundle.module` only for `swift run`.
- SPM doesn't relocate frameworks into the app bundle; `build.sh` adds `@executable_path/../Frameworks` to rpath and only copies frameworks the binary actually links (otool -L filter) to avoid stale Sparkle copies from a sibling build.
- Bundle IDs: `io.bromure.app` (browser), `io.bromure.agentic-coding` (AC)
