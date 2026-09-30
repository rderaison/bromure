# macOS custom Virtio feasibility probe

This probe validates the SDK configuration gate before implementing a renderer.
Its default mode validates configuration only. The optional boot mode also
checks stock guest driver binding, queues, guest RAM mapping and VM lifecycle.
Neither mode selects an accelerated app backend.

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

## Guest binding and lifecycle result

Boot the installed image with its disk attached read-only, no networking, and
`init=/bin/sh`. The host stops the VM after 45 seconds; run the guest commands
promptly, before the first pause at 15 seconds:

```sh
/tmp/bromure-gpu-probe --boot-image "$HOME/Library/Application Support/Bromure"
```

At the guest shell:

```sh
mount -t proc proc /proc
modprobe virtio_gpu
ls -l /sys/bus/virtio/devices/virtio3/driver /dev/dri
cat /proc/iomem
```

Observed with image 403 and kernel `6.8.0-142-generic`:

```text
[drm] pci: virtio-vga detected at 0000:00:08.0
[drm] features: -virgl -edid -resource_blob -host_visible
[drm] number of scanouts: 1
[drm] number of cap sets: 0
DRIVER_OK: guest completed feature negotiation
QUEUE READY 0: size 256
QUEUE READY 1: size 256
RAM MAPPING: copied 4096 bytes from probe RAM base
INVALID MAPPING REJECTED: true
QUEUE 0 command 0x100 bytes 24
[drm] Initialized virtio_gpu 0.1.0 0 for 0000:00:08.0 on minor 0
```

The guest bound `virtio3` to `virtio_gpu` and created `card0` and `renderD128`.
Kernel configuration includes `CONFIG_DRM_VIRTIO_GPU=m` and
`CONFIG_DRM_VIRTIO_GPU_KMS=y`. No custom Linux driver is needed for this gate.
The probe copies command bytes once, bounds each snapshot to 64 KiB, returns
disabled scanouts for GET_DISPLAY_INFO, and rejects other control operations.
Both queues initialize, but only control-queue traffic has been exercised.
The probe RAM address `0x70000000` was verified in this VM's `/proc/iomem`;
it is not a production memory-layout assumption. It copies one page and
immediately releases the mapping, without logging contents.

Two pause/resume cycles delivered device callbacks and completed VM operations;
forced stop delivered DEVICE STOP. Startup reset callbacks were observed.
Reset with live rendering, GPU fences and resource teardown are untested.
The empty-display result (`Cannot find any crtc or sizes`) is expected: this
probe supplies transport responses, not a framebuffer.

Next gates are actual VirGL capset negotiation, renderer-backed resources,
isolated VirGL/ANGLE rendering, fences, and host texture presentation. No host
GPU execution or performance claim follows from this probe. Image 403 remains software-only;
do not send `graphicsBackend=virgl` until a real device and rebuilt compatible
image are selected. The application and its macOS 14 minimum are unchanged.

For dependency integration, inspect the [UTM graphics architecture](https://github.com/utmapp/UTM/blob/main/Documentation/Graphics.md)
and [dependency build recipes](https://github.com/utmapp/UTM/blob/main/scripts/build_dependencies.sh).
The current recipes build WebKit's ANGLE with Xcode and virglrenderer with
Meson plus libepoxy. Those libraries and their build tools are not installed on
this test host. Keep the GL-only build separate from UTM's Vulkan/video stack
and isolate renderer dependencies in the helper, rather than linking them into
the macOS 14 app process.
