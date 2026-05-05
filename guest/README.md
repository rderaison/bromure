# Guest Rust agents

`fb-agent` and `clip-agent` are tiny Rust binaries that run **inside the
Linux guest** for the Windows port of Bromure AC. They replace pieces
that come for free on macOS via VZ:

| Macros agent (macOS)             | Guest binary (Windows)            | What it does                              |
|----------------------------------|-----------------------------------|-------------------------------------------|
| `VZVirtualMachineView` host-side | `fb-agent` guest-side             | XDamage capture → vsock frame push        |
| `VZSpiceAgentPortAttachment`     | `clip-agent` guest-side           | Vsock-bridged clipboard (UTF-8 text v1)   |

Both run as systemd services in the guest (see
`Sources/AgentCoding/Resources/vm-setup/setup.sh` on the macOS side for
the parallel install path).

## Build

```bash
# Inside WSL Ubuntu (or any Linux box)
cd guest
./build.sh
```

The output binaries land at
`guest/target/x86_64-unknown-linux-musl/release/{fb-agent,clip-agent}`.
Both are statically linked against musl so there's no glibc-version
coupling to the base image.

## Wire protocols

### fb-agent (vsock port 8448)

```
[8 B header] magic="FBA1" + payload_len u32 LE
[payload]   JSON envelope (Frame), see src/main.rs
```

Frames: `Hello` once at startup, `Damage` per dirty rect, `Heartbeat`
to keep the channel warm. Pixels follow the JSON envelope as a
zstd-compressed BGRA8 run.

### clip-agent (vsock port 8449)

Newline-delimited JSON, both directions. Same framing as
`SubscriptionTokenBridge` and `CodexTokenBridge` so the host plumbing
carries over.

```json
{ "op": "set",      "text": "..." }
{ "op": "get-req"   }
{ "op": "get-resp", "text": "..." }
```

## Why not on Windows?

The Windows host doesn't run these — they're for the guest. They cross-
compile to musl-Linux. Building them on the Windows host would either
require a Linux cross-toolchain in PATH (annoying for new contributors)
or pull in unrelated MSVC link bits.

## TODO before v1

`src/main.rs` for both agents currently ships the framing + connection
shape but stubs the real work:

- `fb-agent`: actually open `:0`, register XDamage, capture via
  `xcb-shm`, zstd-encode pixel runs.
- `clip-agent`: actually round-trip to ICCCM PRIMARY + CLIPBOARD via
  `xcb-xfixes`.
- Both: switch from the TCP fallback to genuine `AF_VSOCK` once the
  Windows QEMU build ships vsock (today it doesn't — see
  `WIN32_AC_PLAN.md` §7 risk 1).
