<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="Bromure icon">
</p>

<h1 align="center">Bromure</h1>

<p align="center">
  An ephemeral browser that runs in a disposable virtual machine on macOS.
</p>

---

## What is Bromure?

Bromure launches a full Chromium browser inside a lightweight, disposable Linux VM using Apple's [Virtualization.framework](https://developer.apple.com/documentation/virtualization). Every browsing session starts from a clean slate -- when you close the window, the VM and all its data are destroyed. Nothing persists: no cookies, no history, no cached files, no traces.

It runs as a native macOS app with a pre-warmed VM pool, so new browser windows open almost instantly.

## Security

Each browser session runs in a fully isolated virtual machine with its own ephemeral disk. This gives you strong security guarantees that browser sandboxing alone cannot provide:

- **Complete isolation** -- malware, exploits, or malicious scripts are confined to the VM and destroyed when the window closes.
- **No persistent state** -- there is nothing to steal. Cookies, session tokens, and browsing data exist only for the lifetime of the window.
- **Clean environment** -- every session starts from an identical, known-good base image. There is no accumulated attack surface from previous browsing.
- **Network segmentation** -- each VM has its own network stack. Optionally disable networking entirely for air-gapped document viewing.

## Performance

Bromure uses Apple's Virtualization.framework for near-native performance on Apple Silicon:

- **Instant windows** -- a pre-warmed VM pool keeps a fully booted VM ready in the background. Opening a new browser window takes under a second.
- **Lightweight VMs** -- each session runs Alpine Linux with Chromium, using as little as 2 GB of RAM.
- **Native acceleration** -- Virtio GPU, audio, and input drivers provide a smooth browsing experience with no noticeable overhead.

## Features

### Ad Blocking

Bromure includes built-in ad and tracker blocking powered by Pi-hole DNS filtering with a local Squid proxy running inside each VM. No external services, no browser extensions -- ads are blocked at the network level before they reach the browser.

Enable it with a single toggle in Preferences.

### Built-in VPN

Bromure integrates [Cloudflare WARP](https://one.one.one.one/) directly into each VM. When enabled, all browser traffic is routed through Cloudflare's encrypted network via a SOCKS5 proxy -- no system-wide VPN configuration required.

WARP runs entirely inside the disposable VM, so Cloudflare never sees your host machine's identity. When the session ends, the WARP registration is destroyed along with everything else.

### Other Features

- **Dark mode** -- follows the system appearance or can be forced to light/dark.
- **Custom home page** -- set any URL as the default page for new sessions.
- **Keyboard layouts** -- supports a wide range of international keyboard layouts.
- **Configurable resources** -- adjust CPU cores, memory, and display scaling per your needs.
- **Registered as a web browser** -- can be set as the default browser in macOS. Links from other apps open in a fresh, isolated session.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon

## Getting Started

```bash
# Build the app
./build.sh

# Initialize the base image (downloads Alpine Linux + installs Chromium)
.build/arm64-apple-macosx/release/bromure.app/Contents/MacOS/bromure init

# Launch
open .build/arm64-apple-macosx/release/bromure.app
```

## Author

- [Renaud Deraison](https://github.com/rderaison) (prompting)
- [Claude + Opus 4.6] (https://www.anthropic.com) (implementation)
