# Bromure Agentic Coding on Linux: release notes

## Host requirements

Besides KVM, Firecracker and the Swift runtime the install scripts copy, the
daemon links these system libraries (Ubuntu/Debian packages):

- zlib (`zlib1g`) and libbrotlidec (`libbrotli1`): the proxy decodes
  gzip, deflate and br request bodies for its content scans (zstd is
  decoded in Swift). To build: `zlib1g-dev` and `libbrotli-dev`; the build
  stops with the package to install if a header is missing.

The install scripts check the libraries and stop with the package to
install if one is missing.

The install scripts also fetch the PII detector's model (Rampart, ~14 MB,
CC BY 4.0) with `scripts/fetch-pii-model.sh`: a pinned revision, every file
checked against its SHA-256. It needs `curl` and `shasum` and network access
to huggingface.co (or the files already in `$BROMURE_PII_CACHE`). A fetch
that fails stops the install. The user service puts it in
`~/.local/share/BromureAC/Models/pii-rampart`; the multi-user server beside
its binary, in `/usr/local/lib/bromure-ac/bin/pii-rampart`. Without the
model, PII protection still runs its pattern rules (emails, cards, phone
numbers…) and says so in the daemon's log, as macOS does.

## Upgrading

### PII protection

A workspace with PII protection on now has personal data in its model
requests swapped for stand-ins before they leave the machine, and the real
values put back in the replies, as on macOS (a model's WebSocket turns
too).
Rerun the install script to fetch the detector's model (see Host
requirements).

### New host libraries: zlib and libbrotlidec (prompt injection's decoding)

The daemon now links zlib and libbrotlidec (see Host requirements): install
`zlib1g` and `libbrotli1` before upgrading. With the prompt-injection policy
on, a content-coded request body to an AI host is decoded, scanned and
forwarded decoded, as on macOS; one that can't be decoded is refused (415).

### VMs without a workspace profile aren't taken back (egress firewall, linux-port cd55e0e4)

A daemon that restarts (a crash, an upgrade, `systemctl` restarting the
unit after its main process is killed) takes back the VMs still running.
Since the egress firewall, it takes back only VMs whose workspace profile
it can read, because a VM's network is governed from that profile. A VM it
can't govern is stopped (its Firecracker killed) and logged:

    'NAME': not re-adopted (invalid VM config: its workspace profile can't be read, so its network can't be governed); killed its Firecracker (pid N)

VMs started before Linux workspaces had profiles have none, so they stop
on the first daemon restart after the upgrade. Their disks are kept: a
fresh start (`bromure-ac vm start NAME`) makes their profile from the
preferences template and boots them governed.

Before upgrading a server, list each account's running VMs (`GET /vms` on
its socket). An upgrade that restarts the daemons with SIGKILL keeps every
VM that has a profile running across the restart.
