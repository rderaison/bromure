# Bromure Linux spikes

The phase-0 QEMU spike is gone with QEMU (VMs are Firecracker, `linux/firecracker`).
What remains:
- `mitm/`: the TLS-intercepting proxy MitmGuestTests uses (built by `linux/ci.sh`).
- `smoke/`: the Swift 6.4 dependency smoke package (Package.swift, main.swift, resolved versions).
