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
- **Lightweight VMs** -- each session runs Alpine Linux with Chromium, using 2 GB of RAM (okay, that's not super lightweight, that's the price to pay for security).
- **Native acceleration** -- Virtio GPU, audio, and input drivers provide a smooth browsing experience with no noticeable overhead.

## Screenshot

<p align="center">
  <img src="Resources/screenshot.png" width="720" alt="Bromure screenshot">
</p>


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

## FAQ

**The first browser window takes a long time to open. Will it always be this slow?**

No. The very first time you launch Bromure, it needs to boot a VM from scratch, which takes several seconds. Once that VM is ready, it goes into a warm pool -- subsequent windows open almost instantly because a pre-booted VM is already waiting. If you add Bromure to your Login Items (System Settings > General > Login Items), it will start in the background when you log in, so a warm VM is always ready when you need it.

**How much memory should I allocate to the VM?**

The default of 2 GB is sufficient for most browsing. Video playback works great thanks to GPU hardware acceleration, but if you notice choppy playback on high-definition videos or use memory-heavy web apps, consider increasing it to 4 GB in Preferences. Going above 4 GB is rarely necessary.

**How do I enable the VPN? Is it free?**

Open Preferences and toggle "Cloudflare WARP". The first time you enable it, you will be asked to accept Cloudflare's terms of service. WARP is a free service provided by [Cloudflare](https://one.one.one.one/) -- it encrypts your DNS queries and routes your traffic through Cloudflare's network. It runs entirely inside the disposable VM, so no configuration is needed on your host machine, and the WARP registration is destroyed when the session ends.

**Can I make my browsing data persistent or save a baseline image?**

Not currently. Every session is ephemeral by design -- all data is destroyed when the window closes. If persistent profiles or custom base images would be useful to you, please [open a feature request](https://github.com/rderaison/bromure/issues).

**Can I download files from the VM to my Mac?**

No, and this is by design. The VM is fully isolated from your host filesystem to prevent malicious downloads or drive-by attacks from escaping the sandbox. If you need this capability, please [open a feature request](https://github.com/rderaison/bromure/issues).

**Can I use Bromure as my default browser?**

Yes. Go to System Settings > Desktop & Dock > Default web browser and select Bromure. Links clicked in other apps will open in a fresh, isolated VM session.

**Does each VM session require 4 GB of disk space?**

No. Bromure uses `clonefile()` to create each session's disk image, which leverages APFS copy-on-write (COW) semantics. The cloned image initially takes up almost no additional space -- only the blocks that the VM actually modifies during the session consume real disk storage. A typical browsing session writes very little to disk, so the actual cost per session is usually just a few megabytes rather than the full 4 GB.

**Networking in the VM is broken when my VPN is active.**

This is a known limitation of Apple's Virtualization.framework. When a VPN (especially IKEv2 or other full-tunnel configurations) reroutes all host traffic, the VM's NAT networking may fail to follow the routing change. Try starting the VPN before launching Bromure, or restarting Bromure after connecting. In some cases, a host reboot may be required to restore VM networking.

**Does Bromure work on Intel Macs?**

No. Bromure requires Apple Silicon (M1 or later). It relies on Apple's Virtualization.framework, which only supports ARM64 guest VMs on Apple Silicon hosts.

**Why is it called "Bromure"?**

It is a pun on [Bromium](https://en.wikipedia.org/wiki/Bromium), a company that pioneered micro-virtualization for endpoint security -- running each task in a disposable VM. Bromium was acquired by HP in 2019. "Bromure" is also the French word for "bromide", which felt fitting for something designed to neutralize threats.

## Author

- [Renaud Deraison](https://github.com/rderaison) (prompting)
- [Claude + Opus 4.6](https://www.anthropic.com) (implementation)
