# Bromure network plumbing — how the AC bake gets through hostile networks

This document captures the network-layer changes shipped between
`agentic-coding-v2.0.0` and current `main`. They turned the base-image
bake from "works on a clean network, hangs/crashes on a corporate VPN"
into "works behind whatever the user is on." The intent is that the
browser-side image bake (when it gets re-touched) can borrow the same
pattern.

All code referenced is in `Sources/AgentCoding/` unless stated otherwise.

## TL;DR

1. **The guest never talks HTTPS to the internet directly.** It talks
   plain HTTP to an in-process proxy on the host; the host re-emits as
   HTTPS via `URLSession` (Apple's TLS, which the VPN handles).
2. **MTU gets clamped before any fetch happens** — via a small cpio
   shim appended to Alpine's initramfs that runs as `rdinit`.
3. **A `udhcpc` post-bound hook re-applies the MTU** after Alpine's
   own DHCP cycles, so the clamp survives userspace networking
   bring-up.
4. **SIGPIPE is masked process-wide AND per-socket** so a closed-
   client write doesn't kill the host.
5. **The proxy streams** — no full-body `URLSession.dataTask`
   buffering; the modloop + npm tarballs don't risk jetsam.

The bake-only pieces are the cpio shim, the udhcpc hook, and the apk
HTTP fallbacks. The proxy itself and the SIGPIPE hardening apply to
any VM that does HTTPS to the public internet.

---

## The host-side HTTP → HTTPS proxy

**File:** `AlpinePackageProxy.swift` (rename later — it's no longer
Alpine-specific). Lifecycle: started in `UbuntuImageManager.runInstaller`
before the bootloader is built; `defer { proxy.stop() }` tears it down.

### What it does

- BSD-socket TCP listener on `0.0.0.0:<ephemeral>` (kernel-assigned
  via `port = 0` + `getsockname`, so it never clashes with whatever
  the user has on 8080/3128/etc).
- Three request shapes it accepts:
  1. **Reverse-proxy `GET /path`** — used by the bake's `alpine_repo=`
     and `modloop=` kernel cmdline URLs (which can't carry an absolute
     URL). Hardcoded upstream `https://dl-cdn.alpinelinux.org<path>`.
  2. **Forward-proxy `GET http://upstream/path`** — used when the
     guest has `HTTP_PROXY` set. The upstream scheme is promoted to
     HTTPS for the URLSession hop.
  3. **`CONNECT host:443`** — used when the guest has `HTTPS_PROXY`
     set. We open a raw TCP socket via `getaddrinfo` (IPv4/IPv6
     agnostic) and splice bytes both ways. Client and upstream do TLS
     end-to-end through our tunnel.
- Each request is served on a concurrent worker queue
  (`io.bromure.ac.alpineproxy.work`, `attributes: .concurrent`); the
  accept handler dispatches and returns immediately.

### Why URLSession upstream (and not raw HTTPS via OpenSSL)

The user's VPN broke `apk-tools`' OpenSSL-3.x handshake with the
`unexpected eof while reading` close-notify-strict error. The same
VPN passes Apple's URLSession HTTPS perfectly because URLSession uses
the macOS Network framework's TLS implementation. Moving the TLS hop
to the host side made everything Just Work.

### Streaming, not buffering

Initial implementation used `URLSession.dataTask(_:completionHandler:)`
which buffers the whole body before the callback fires. With ~100 MB
modloops and parallel npm tarballs the host RSS spiked into the GB
range and **macOS jetsam silently killed the process** (no crash log,
just gone — see SIGPIPE notes below for similar pathology).

Replaced with `URLSessionDataDelegate` (`StreamingProxyDelegate`):
- `didReceive(response:)` writes the HTTP status line + filtered
  headers to the client socket.
- `didReceive(data:)` writes each chunk directly to the client socket.
- `didCompleteWithError:` signals the per-request semaphore.
- Per-request `URLSession` (not shared) so delegate lifetime is
  bounded by one HTTP hop.

Headers we strip on the response side:
- `Connection`, `Transfer-Encoding` — hop-by-hop.
- `Content-Encoding` — URLSession transparently decompresses; passing
  the original encoding hint would tell the guest to decompress
  already-decompressed bytes.
- `Content-Length` — we replace with the streamed length (known if
  upstream provided one via `expectedContentLength`, otherwise omit
  and rely on `Connection: close`).

### No allowlist (deliberate)

Initially the proxy enforced a small allowlist (`dl-cdn.alpinelinux.org`,
`registry.npmjs.org`, `deb.nodesource.com`). A real bake legitimately
touches 16+ hosts (azcliprod, cli.github.com, dc.services.visualstudio.com,
release-assets.githubusercontent.com, …). Maintaining the allowlist
as Alpine / Ubuntu / setup.sh evolve is constant churn for no real
protection:

- The proxy listens on the **vmnet gateway IP** (`192.168.64.1`),
  reachable only by the bake VM, never the LAN or WAN.
- It runs for the ~10 minutes the bake takes; tears down on
  `runInstaller` exit.
- Every artifact downloaded is signature- or checksum-verified at the
  apk / apt / npm / Sparkle layer regardless of transport.

What we kept instead: per-request host accounting + a sorted summary
dumped on `stop()`. So we always know what was contacted, even if we
don't restrict.

### Security model (what HTTP-instead-of-HTTPS costs)

For an Alpine-/Ubuntu-/npm-style supply chain, the integrity story is:

- **Each package is RSA-signed.** apk verifies every `.apk` against
  keys in `alpine-keys`; apt verifies every `.deb` against keys in
  the keyrings; npm has package shasum + sigstore. These all happen
  AT the package manager, independent of transport.
- **The signing keys came in via a trusted path.** alpine-keys is in
  the Alpine netboot tarball; that tarball is downloaded over HTTPS by
  `UbuntuImageManager` AND its SHA-256 is verified against a
  hardcoded constant in the app code (`UbuntuImageError.checksumInvalid`).
  Root of trust = our code-signed app, not the network.

So HTTP-direct (or HTTP-via-our-proxy) loses **confidentiality**
(MITM sees which packages you fetch — already inferable from version
strings) and **freshness** (MITM can serve an older but still
validly-signed index, possibly with known-CVE versions). It does not
lose **integrity**: nothing tampered can be installed.

For a one-time dev-machine bake the trade-off is fine. For an
internet-facing builder it's not, and you'd want the proxy approach
described here (HTTPS preserved end-to-end via URLSession).

---

## SIGPIPE — the bug that ate hours

**Symptom.** Bake terminating silently mid-`setup.sh`. No crash log,
no diagnostic report, no stderr trace. Launching from a terminal: the
process just exits. Reproducible at the exact same point (a guest
tool closing its stdin/pipe mid-stream).

**Cause.** `Darwin.write` on a closed socket returns `EPIPE`, AND the
kernel sends `SIGPIPE`. Default disposition for `SIGPIPE` is
**terminate the process**. No crash, no log, just gone.

This is a footgun any networked process on Unix has to handle.
Foundation masks it for high-level types, URLSession masks it for its
own internals, but **raw BSD-socket code** (our `Darwin.write` calls
in `splice`, `writeStatus`, `writeResponse`) is on its own.

**Fix.** Belt and braces:

```swift
// Process-wide
signal(SIGPIPE, SIG_IGN)
// Per-socket — on EVERY fd: listener, accepted clients, upstream
// sockets from getaddrinfo, splice endpoints.
var yes: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
           &yes, socklen_t(MemoryLayout<Int32>.size))
```

On Linux the equivalent is `MSG_NOSIGNAL` on every `send()` (no
per-socket SO_NOSIGPIPE), so the Linux story is uglier — relevant if
this code ever moves.

**Lesson for the browser.** Anywhere we use `Darwin.write` on a socket
fd (LoopbackCallbackForwarder, NetworkFilter, vsock channels, etc.):
audit for SIGPIPE. If `signal(SIGPIPE, SIG_IGN)` hasn't been called
process-wide somewhere reliable (e.g. main()), set `SO_NOSIGPIPE` on
the fd.

---

## Guest configuration

### Kernel cmdline (initramfs phase)

```
console=hvc0
rdinit=/init.bromure                                          # our shim, see below
alpine_repo=http://192.168.64.1:<port>/alpine/v3.22/main      # proxy URL
modloop=http://192.168.64.1:<port>/alpine/v3.22/releases/aarch64/netboot-3.22.3/modloop-virt
modules=loop,squashfs,virtio-net,virtio-blk,virtiofs
arm64.nosme
```

Notably absent: `ip=dhcp`. The kernel autoconfig was racing vmnet's
`bootpd` startup and failing; we do DHCP ourselves in the shim.

### The rdinit shim (`/init.bromure`)

A small sh script that runs as PID 1 in initramfs *before* Alpine's
`/init`. Generated at runtime and **appended to Alpine's gzipped
initrd as an uncompressed cpio segment** (Linux supports concatenated
initramfs natively — files in later segments override earlier ones).
After appending, we tell the kernel to use it via `rdinit=` on the
cmdline.

What the shim does:

```sh
#!/bin/sh
BB=/bin/busybox

# /sys, /proc, /dev — Alpine's /init mounts these later but we need
# them now, before any sysfs writes or `ip` commands.
$BB mount -t sysfs ...   /sys
$BB mount -t proc ...    /proc
$BB mount -t devtmpfs ...   /dev
$BB modprobe virtio_net 2>/dev/null || true

# Plant busybox applet symlinks so udhcpc's default script can call
# `ip`, `cat`, `ifconfig`, etc.  Without this, udhcpc gets a lease
# but the script fails to apply it.
$BB --install -s
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Bring up + DHCP + clamp MTU.  Kernel autoconfig had tried + failed
# earlier (vmnet bootpd not ready); userspace udhcpc is more patient.
$BB ip link set dev lo up
$BB ip link set dev eth0 up
$BB udhcpc -i eth0 -q -n
# Clamp MTU via sysfs (no `ip link set` dependency).
for f in /sys/class/net/e*/mtu; do
    [ -w "$f" ] && echo <MTU> > "$f"
done

exec /init "$@"
```

Two non-obvious details:

- **Padding before the appended cpio.** The kernel's
  `unpack_to_rootfs` requires `this_header & 3 == 0` before treating
  the next bytes as a cpio newc archive. After decompressing Alpine's
  gzipped initrd, `this_header` lands at the gzip byte count — often
  `% 4 == 3`. Pad with NUL bytes (kernel's NUL-skip loop increments
  `this_header`) before our segment starts. Without this the kernel
  fails to find `/init.bromure` and falls through to `prepare_namespace()`
  → "Unable to mount root fs" panic.

- **MTU clamp via sysfs, not `ip link`.** At rdinit time the busybox
  symlinks aren't installed yet; `ip` isn't in PATH. `echo $MTU > /sys/class/net/eth0/mtu`
  works against the kernel directly and has no dependency.

### udhcpc post-bound hook

Alpine's `/usr/share/udhcpc/default.script` is the script busybox-udhcpc
calls when a lease lands. It iterates `/etc/udhcpc/pre-bound/` and
`/etc/udhcpc/post-bound/` so distros can hook in. We plant a
`zz-bromure-mtu` post-bound hook via the same cpio segment:

```sh
#!/bin/sh
[ -n "$interface" ] || exit 0
ip link set dev "$interface" mtu <MTU>
echo "bromure-post-bound: $interface MTU=$(cat /sys/class/net/$interface/mtu)" > /dev/kmsg
```

Why this matters: even though the rdinit shim sets MTU in initramfs,
Alpine's `/init` does *another* DHCP cycle in userspace after switch_root.
The post-bound hook makes the clamp survive that second cycle. The
kmsg line is also our breadcrumb for confirming via `dmesg` that the
clamp actually applied.

### Outer-shell phase (Alpine installer environment, before chroot)

setup.sh runs in Alpine before debootstrap-ing Ubuntu into `/mnt`.
The apk step uses `/etc/apk/repositories` which already points at the
proxy (via `ALPINE_REPO_BASE` from the host). But debootstrap shells
out to wget for the Ubuntu base — wget respects `HTTP_PROXY`, so we
export the proxy vars before debootstrap so its ~150 MB of Ubuntu
package downloads also go through the proxy:

```sh
if [ -n "$ALPINE_REPO_BASE" ] && \
   [ "$ALPINE_REPO_BASE" != "http://dl-cdn.alpinelinux.org" ]; then
    export http_proxy="$ALPINE_REPO_BASE"
    export https_proxy="$ALPINE_REPO_BASE"
    export HTTP_PROXY="$ALPINE_REPO_BASE"
    export HTTPS_PROXY="$ALPINE_REPO_BASE"
    _host_port="${ALPINE_REPO_BASE##*://}"
    _proxy_host="${_host_port%%:*}"
    export no_proxy="localhost,127.0.0.1,::1,$_proxy_host"
    export NO_PROXY="$no_proxy"
fi
```

Two non-obvious bits:

- **The not-the-fallback guard.** If the host proxy didn't start,
  `ALPINE_REPO_BASE` falls back to `http://dl-cdn.alpinelinux.org`
  which is a CDN, not a proxy server. Exporting that as HTTP_PROXY
  would route every HTTP request to it as if it were a proxy and
  break everything.

- **The proxy host MUST be in `no_proxy`.** apk's repo URL (and the
  reverse-proxy URLs we put on the kernel cmdline) *also* point at
  the proxy, e.g. `http://192.168.64.1:PORT/alpine/...`. With
  HTTP_PROXY set to the same URL but no bypass entry, apk dutifully
  routes "its own repo URL" *through* HTTP_PROXY — sending an
  absolute-URL request to the proxy, the forward-proxy code parses
  it, promotes the scheme to HTTPS, and dials the proxy over HTTPS
  (which we don't speak). The proxy hangs trying to handshake TLS
  with itself. Adding the proxy host to `no_proxy` makes apk
  connect directly to the proxy on plain HTTP — our reverse-proxy
  mode handles the path-only request and routes to the real CDN.

### Chroot phase

`setup.sh` enters the new Ubuntu chroot and does most of the heavy
lifting (apt, npm, curl, etc.). The chroot inherits the parent shell's
env, so we just need to export the proxy vars before entering:

```sh
export http_proxy="$BROMURE_PROXY"
export https_proxy="$BROMURE_PROXY"
export HTTP_PROXY="$BROMURE_PROXY"
export HTTPS_PROXY="$BROMURE_PROXY"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="$no_proxy"
```

**Everything goes through the proxy** — including Ubuntu's apt
mirrors. The forward-proxy mode promotes upstream HTTP to HTTPS via
URLSession, Canonical's mirrors support HTTPS, and this gives us one
source of truth for every host the bake contacts (visible in the
proxy's `recordHost` summary on `stop()`) and one network-handling
path to debug. The only bypass is loopback (`localhost`, `127.0.0.1`,
`::1`) for tools like apt-listchanges that fire local helpers.

apt also gets an explicit config because env vars alone aren't always
honoured by libapt:

```
# /etc/apt/apt.conf.d/99-bromure-proxy
Acquire::http::Proxy "<proxy URL>";
Acquire::https::Proxy "<proxy URL>";
```

`BROMURE_PROXY` itself is plumbed from the host through
`/mnt/tmp/bromure-build.env` (which the chroot sources). That keeps
the quoted heredoc clean — no host-side variable interpolation.

---

## MAC pool reuse for the installer VM

The installer was asking VZ for a fresh random MAC on every bake.
Each MAC = a fresh DHCP lease in vmnet's bootpd table = a different
NAT state on the host. Over many bakes the table grew and behaviour
got less reproducible.

The session-VM path already used `MACAddressPool.shared.claim()` /
`release()`. We just wired the installer to the same pool:

```swift
let claimedInstallerMAC = MACAddressPool.shared.claim()
defer {
    if let mac = claimedInstallerMAC {
        MACAddressPool.shared.release(mac)
    }
}
let net = VZVirtioNetworkDeviceConfiguration()
net.attachment = VZNATNetworkDeviceAttachment()
if let mac = claimedInstallerMAC, let vzMAC = VZMACAddress(string: mac) {
    net.macAddress = vzMAC
}
```

For the browser bake the same pattern should drop in.

---

## What's portable to the browser

Per-file map of what should go where if/when the browser bake is
revisited:

| AC component | Browser equivalent / port | Notes |
|---|---|---|
| `AlpinePackageProxy.swift` | New host-side proxy class, probably alongside `LoopbackCallbackForwarder` | Rename to something generic like `BakePackageProxy`. Allowlist-free + host-recording is the design we landed on; same threat model applies. |
| `runInstaller.AlpinePackageProxy()` | Browser's analogous installer setup | `defer { proxy.stop() }` after the VZ task group. |
| Cpio rdinit shim + padding logic | Browser doesn't use Alpine netboot today | Skip unless the browser bake adopts Alpine. If it does, the `appendCpioEntry` + 4-byte alignment code is copy-paste. |
| `/etc/udhcpc/post-bound/zz-bromure-mtu` hook | Same, only if Alpine | Otherwise irrelevant (systemd-networkd handles MTU differently). |
| `setup.sh` chroot HTTP_PROXY/NO_PROXY/apt.conf.d | Same in browser's setup script | Templates are straight copy. |
| `MACAddressPool.claim/release` in installer | Already used for sessions; just add to the installer | One-liner. |
| SIGPIPE: `signal(SIGPIPE, SIG_IGN)` + `SO_NOSIGPIPE` | **Everywhere we open sockets in the browser** | Especially in `NetworkFilter`, `LoopbackCallbackForwarder` (already used by both), and any new code that does `Darwin.write` on a socket fd. |
| Streaming via `URLSessionDataDelegate` | Same if the browser proxy does any HTTPS-fetch path | Memory bound matters once aggregate body size > a few hundred MB. |
| `.terminateLater` quit drain | Already added to AC (`BromureAC.swift::applicationShouldTerminate`) | Port to the browser's app delegate. Cleans up "NSActivity was ended multiple times" warning Foundation emits when VZ teardown races in-flight vm.stop() callbacks. |

## Diagnostics shipped along the way

Useful for future debugging:

- The proxy's `recordHost()` + sorted dump on `stop()`. Always know
  exactly what was contacted.
- `bromure-shim:` and `bromure-post-bound:` lines on the guest serial
  (and `/dev/kmsg` for the post-bound hook, recoverable via `dmesg`).
  These were essential for narrowing down whether MTU was being clamped,
  whether the udhcpc lease was being applied, etc.
- The userspace clamp probe in `runInstaller`'s post-login step:
  `echo "bromure: $NIC MTU=$(cat /sys/class/net/$NIC/mtu)"` — confirms
  the MTU survived Alpine's userspace bring-up.

If we hit anything subtle in the browser bake, mirror these.
