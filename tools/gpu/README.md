# macOS custom Virtio feasibility probe

This probe validates the SDK configuration gate before implementing a renderer.
It does not boot a guest, process queues, or select an accelerated app backend.

Run from the repository root on an Apple Silicon macOS 27 host with SDK 27:

```sh
xcrun swiftc -target arm64-apple-macosx14.0 -module-cache-path /tmp/bromure-gpu-modules tools/gpu/validate-custom-virtio.swift -o /tmp/bromure-gpu-probe
codesign --force --sign - --entitlements tools/gpu/probe.entitlements /tmp/bromure-gpu-probe
/tmp/bromure-gpu-probe
```

Use the minimal probe entitlement file. The app's entitlement file includes
provisioned capabilities that an ad-hoc standalone executable cannot claim;
using it caused termination before validation on the test host.

## Result, September 30, 2026

Host: Apple M5 Pro, 64 GB, macOS 27.0.1 (26A434), Xcode SDK 27.0.
Compilation succeeded with a macOS 14 deployment target. Runtime
`VZVirtualMachineConfiguration.validate()` accepted device ID 16, PCI class
03/subclass 00, two queues, and a 16-byte GPU-specific configuration with one
scanout and zero capsets. No VirGL feature is advertised. The executable prints
the limited result explicitly and removes its temporary EFI variable store.

The installed SDK exposes a delegate provider with a separate serial device
queue, feature negotiation, shared memory regions, and pause/resume/reset/stop
callbacks. The provider runs in the VM process: it does not supply renderer
process isolation. Renderer IPC and containment still need implementation.

This result establishes configuration acceptance only. Next gates are actual
Linux driver binding, immutable bounded queue snapshots, protocol replies and
capset negotiation, guest backing-memory access, lifecycle handling, isolated
VirGL/ANGLE rendering, and host texture presentation. No guest GPU execution or
performance claim follows from this probe. Image 403 remains software-only;
do not send `graphicsBackend=virgl` until a real device and rebuilt compatible
image are selected. The application and its macOS 14 minimum are unchanged.
