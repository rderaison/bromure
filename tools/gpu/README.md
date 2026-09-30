# macOS custom Virtio feasibility probe

## Actual browser rendering result

The signed Bromure preview now boots the real Linux browser VM with the sandboxed
renderer and presents its native Metal frames through XPC and IOSurface. Chromium
reports ANGLE/Mesa/virgl with GPU compositing enabled. The strict guest check
creates WebGL2 with four-sample antialiasing, clears red, and verifies an exact
RGBA readback with no GL error. Eleven worker tests cover the real MSAA
clear/resolve, cross-context resource sharing, opaque top-origin framebuffer
uploads, and malformed/bounded requests.

The pinned VirGL patch implements GLES 3.0 multisample renderbuffers and fixes
opaque Metal storage accounting. Multisample texture sampling is unsupported;
Mesa uses the same protocol capability bit for both resource kinds. This
experimental backend has not established complete desktop GL conformance.

Run the actual browser check with a built, signed preview and a verified image:

```sh
bromure gpu-browser --storage-dir /path/to/image --seconds 35 \
  --guest-probe tools/gpu/guest-browser-check.py --require-gpu-check
```

## Hardware video decode result

The packaged sandboxed helper supports `--video-check`. It creates twelve
trusted H.264 samples with a hardware encoder and requires a hardware
VideoToolbox decoder. All twelve frames decoded; the decoder's
`UsingHardwareAcceleratedVideoDecoder` property was true. Output was two-plane
NV12 backed by IOSurface, with fixture values Y=63, Cb=102, Cr=240, consistent
with the encoded red input. Software fallback fails the check. This establishes
the host decoder/surface path only; Chromium movie hardware decoding still
requires the guest codec protocol and browser integration. Neither VirGL's
current GL-only build nor Chromium flags enable this decoder automatically.

## Guest rendering bridge result

The optional sandboxed worker now handles capsets, contexts, bounded resources,
backing snapshots, explicit upload/readback transfers, and immutable VirGL
command submissions. Linux's version-zero capset request is supported. Resource
count, dimensions, aggregate GPU allocation estimates, backing bytes, command
lengths and pipe frames have finite limits. Private backing/reset/test commands
are not forwarded from guest queues. Guest physical addresses stay in the VM
process; the helper only receives owned bytes. Backing mappings are recreated
per transfer and discarded immediately. Mesa staging-buffer transfers encoded
inside SUBMIT_3D are synchronized only for explicit upload/readback operations.

Run the packaged helper with the transport probe:

```sh
bash tools/gpu/build-transport-probe.sh
/private/tmp/bromure-gpu-probe --boot-image "$HOME/Library/Application Support/Bromure" --renderer-helper /absolute/path/to/packaged/metal-probe
```

At the guest shell, mount `/proc`, load `virtio_gpu`, and run
`guest-egl-smoke.py` with Python 3 (transfer the script through serial on the
read-only probe). On image 403 the actual GBM/EGL guest context reported `virgl`,
created a 64x64 framebuffer, submitted its clear to the host renderer, and read
back `[255, 0, 0, 255]`. Software fallback is rejected by the script. Nine
tests in `test-renderer-worker.py /absolute/path/to/packaged/metal-probe` cover
partial frames, capsets, malformed lengths/versions, context quotas/reset,
resource uploads, range overflow, command execution, actual GPU fence completion,
native texture correctness and backing teardown.

The application now uses an embedded sandboxed XPC service and a separate
background processing queue. UI and custom-device queues do not wait on
rendering. A local image graphics contract and successful renderer capability
probe gate custom-device installation before boot. `VMPool` propagates the
selected backend to the guest, and `BrowserSession` presents IOSurface frames
through Metal with aspect-preserving scaling. `gpu-browser --storage-dir PATH`
exercises the real browser VM and window; `gpu-demo` isolates renderer/display
validation. One experimental GPU VM is supported per app process; additional
VMs use the legacy device. Existing images without the contract use legacy GL.

A rebuilt Ubuntu image booted through the actual app, Xorg/GLX reported VirGL
acceleration, and the host received over 100 real scanout frames. A context
sharing regression is covered by a buffer created before guest contexts, then
uploaded/read from different contexts; the old implementation fails and the
fixed implementation passes. Browser CDP still reports disabled GL with the
current Chromium/ANGLE initialization, so browser GPU acceptance and guest
hardware movie decoding are still required before enabling this by default.

This probe validates the SDK configuration gate before implementing a renderer.
Its default mode validates configuration only. The optional boot mode also
checks stock guest driver binding, queues, guest RAM mapping and VM lifecycle.
Neither mode selects an accelerated app backend.

Run from the repository root on an Apple Silicon macOS 27 host with SDK 27:

```sh
bash tools/gpu/build-transport-probe.sh
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
The recipes build WebKit's ANGLE with Xcode and virglrenderer with Meson plus
libepoxy. The following standalone recipe now builds that GL-only subset,
separate from UTM's Vulkan/video stack and the macOS 14 app process.

## Renderer and sandboxed helper proof

Install Xcode's Metal compiler if needed (`xcodebuild -downloadComponent MetalToolchain`),
then build the standalone dependencies and probe:

```sh
bash tools/gpu/build-renderer-probe.sh
/private/tmp/bromure-gpu/metal-probe
bash tools/gpu/package-renderer-probe.sh /private/tmp/bromure-gpu
```

The build script fetches pinned WebKit/ANGLE, virglrenderer, libepoxy and pkgconf
revisions and installs pinned Python build tools in a temporary virtual
environment. `BROMURE_GPU_BUILD_ROOT` changes the output directory; source and
tool environment overrides allow reusing already fetched checkouts. Changed
source files are rejected except for the two checked, reproducible patches.
The patches make ANGLE and libepoxy load the helper's relocatable dylibs via
`@rpath`. SDK 27 uses `_LIBCPP_HARDENING_MODE_FAST` in place of the old libc++
assertions definition. Vulkan, video and vtest are disabled.

Packaging prints a unique helper executable path. The helper contains its own
renderer libraries, upstream notices, macOS 27 minimum and App Sandbox
entitlement, with no network, user-file or parent keychain-group entitlements.
It is a standalone proof, not the application's production helper. To check
its basic containment, create a non-sensitive sentinel outside its bundle and
run the printed executable with `--sandbox-check /absolute/path/to/sentinel`.
The host must confirm that the sentinel exists before running: an absent file
is not a permission-denial test. The checks require EPERM/EACCES for file read
and a loopback TCP connection attempt; merely failing to reach a server is
insufficient. App Sandbox can allow socket creation while denying connect.

Observed on the test host, including the packaged sandboxed helper:

```text
CONTAINMENT: outside sentinel file and network connection denied
RENDERER: ANGLE (Apple, ANGLE Metal Renderer: Apple M5 Pro, Version 27.0.1 (Build 26A434))
CAPSET 1: version 1, 308 bytes
CAPSET 2: version 2, 1408 bytes
NATIVE TEXTURE: Metal GPU blit to IOSurface; Mach-port import and red pixel verified
PASS: ANGLE Metal, VirGL capsets, native scanout texture and IOSurface GPU blit
```

The probe forces the Metal hardware backend, renders a trusted clear, creates
a VirGL BGRA scanout resource, obtains its native Metal texture, and GPU-blits
it into an IOSurface. A same-process Mach-port import and one-pixel readback
check correctness. The library's native texture isn't initially IOSurface
backed, so the explicit GPU blit provides a usable host sharing path.
Production must use asynchronous completion fences: the probe's `glFinish`
and `waitUntilCompleted` cannot run on device or UI queues. No full guest frame
readback or app presentation occurs here.

This does not prove cross-process IPC, hostile-command containment, live guest
3D rendering, actual display cadence, Chromium acceleration, or performance.
The application backend remains legacy until those gates pass. No new renderer
library is linked into Bromure, and its macOS 14 minimum is unchanged.

## Installed image 403 inventory

The Linux owner's headless prerequisite script ran against the read-only guest.
The complete report is [image403-prerequisites.json](results/image403-prerequisites.json).
Mesa packages and mesa-libgallium are `25.2.8-0ubuntu0.24.04.2`; the
`virtio_gpu_dri.so` symlink resolves to `libdril_dri.so`, loads successfully and
exports the expected DRI entry point. Mesa EGL/GLX and GBM load, but
`libGLESv2.so.2`, mesa-utils, glxinfo and eglinfo are missing. Chromium is
154.0.8037.57; Chrome 154.0.8037.92 is also installed. The graphics capability
marker and new environment/diagnostic scripts are absent. Thus
`readyForGuestProbe` is false despite working kernel binding and DRI packaging.
The Linux owner is preparing the rebuilt-image prerequisites; image version
and explicit capability gating still need coordination before backend selection.
