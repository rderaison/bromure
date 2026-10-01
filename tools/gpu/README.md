# Bromure VirGL / Metal integration

On Apple Silicon with macOS 27, a supported image and embedded renderer service,
Bromure selects the custom Virtio GPU automatically. Older systems, images
without the graphics contract, disabled GPU profiles and unavailable helpers
retain software graphics. `vm.experimentalGPU=false` also selects software.
Each accelerated VM owns an independent sandboxed renderer worker, including
the prewarmed replacement VM. The XPC broker forwards GPU surfaces through
private inherited Mach channels; a worker failure stops only its own VM renderer.
The main app still supports macOS 14.

The actual browser passes accelerated WebGL2 with four-sample antialiasing,
correct red pixels and no GL error. Hardware H.264 playback passes through
Chromium's `VaapiVideoDecoder`, Mesa/VirGL and the isolated VideoToolbox decoder.
Tests cover baseline, Main with B-frames, and High with JVT scaling matrices;
each 720p movie plays at least 250 frames with correct colours and no software
decoder fallback. Native toolbar cropping and live display resize are tested.

## Build and package

```sh
bash tools/gpu/build-renderer-probe.sh
bash tools/gpu/package-renderer-xpc.sh /private/tmp/bromure-gpu
```

The recipe verifies pinned ANGLE, libepoxy, VirGL and pkgconf revisions and the
exact local patches. `BROMURE_GPU_BUILD_ROOT`, `BROMURE_GPU_TOOL_ENV` and the
`BROMURE_*_SOURCE` overrides permit existing checkouts and caches. ANGLE forces
Metal. Renderer libraries stay inside the sandboxed XPC service, not the main
app. The service has no network, user-file or parent keychain entitlements.

Both `build.sh` and `package.sh` embed and sign the service on SDK 27. They can
build it automatically, or accept an already built `BROMURE_RENDERER_XPC` bundle.
Set `BROMURE_BUILD_GPU_RENDERER=0` for a build without this optional backend.
The production broker identifier is `io.bromure.gpu.renderer.broker`. When
running the XPC probe against that identity, set `CODESIGN_IDENTITY` to the
production Developer ID to preserve the existing sandbox container identity.

## Guest image

The normal image installer invokes
[`build-guest-graphics.sh`](../../Sources/SandboxEngine/Resources/vm-setup/gpu/build-guest-graphics.sh).
It verifies Mesa 25.2.8's archive SHA-256, builds a VirGL-only Mesa with H.264 VAAPI
support under `/opt/bromure/mesa-virgl`, builds the Chromium RGB compatibility
library and checks actual library loadability before writing its ready marker.
System Mesa remains installed for the software backend.

The guest patches provide full GEM backing and submission dependencies for
exported video planes, invalidate decoded CPU shadows, select proper progressive
2D compositor shaders and supply their legacy TGSI colour matrix constants.
Metal R8/RG8 sampler views use shader swizzles so aliased UV component views do
not overwrite each other's channel selection.

Chromium 154 expects its VA ARGB metadata to describe DRM ARGB8888/BGRA bytes;
Mesa names that layout VA BGRA. A Chromium-only libva facade translates those
RGB metadata calls and delegates other symbols to the real libva library.
Actual DRM plane layout and driver capabilities remain intact. It uses neither
`LD_PRELOAD` nor a `dlsym` interceptor. Software startup does not load this facade.
The render node is selected from the negotiated Virtio VirGL feature, rather
than assuming a fixed render-node number. Feature switches are merged so later
configuration cannot discard the video prerequisites.

The local rebuilt image retains version 403. The capability sidecar gates GPU
selection; existing downloaded 403 images without that sidecar retain software.
This is a local integration result, not a published browser image update.

## Verification

```sh
bash tools/gpu/package-renderer-probe.sh /private/tmp/bromure-gpu
python3 tools/gpu/test-renderer-worker.py /path/to/packaged/metal-probe
bromure gpu-browser --storage-dir /path/to/verified/image --seconds 45 \
  --guest-probe tools/gpu/guest-browser-check.py --require-gpu-check
```

`guest-video-check.py` verifies actual Media decoder properties, frame count,
playback errors and canvas pixels for a trusted red H.264 MP4 placed at
`/tmp/bromure-movie.mp4`. `test-video-worker.py` verifies descriptor-only H.264,
NV12/I420 planes, shared backing, encoded/staging readback and malformed lengths.
The renderer requires VideoToolbox hardware decoding and verifies its
`UsingHardwareAcceleratedVideoDecoder` property; its frame counter supplies host
evidence independently of Chromium's GPU status page.

Twelve worker checks cover bounded frames, resources and contexts, fences,
cross-context sharing, MSAA resolve, native scanout, uploads and live resize.
Fifteen Linux-runnable guest checks cover policy, feature merging and the graphics
contract. Native fences and decoded-plane synchronisation run on renderer threads,
away from the app's UI and Virtio device queues.

## Limits

Hardware video currently covers progressive 8-bit 4:2:0 H.264, up to the advertised
level-5.1 bounds. Other codecs, interlaced content and protected video retain
software paths. This is not full desktop GL conformance: MSAA renderbuffers work,
but multisample texture sampling does not. Mesa shares their capability bit.
Chromium's tested video display route performs an RGB copy in the guest; hardware
decode does not establish zero-copy video or a measured performance gain.
The ordinary desktop scanout uses native Metal textures, IOSurfaces and GPU blits.

Earlier image-403 inventories and feasibility reports under `results/` describe
the original image, not the rebuilt installation.

## Performance comparison

[Five-trial comparison against Apple VZ Virtio and native macOS](benchmarks/README.md)
includes identical WebGL2 workloads, actual renderer/device inventory and raw samples.
3D submissions accept up to 1 MiB; other messages and all replies remain at 64 KiB.

## Native cursor

The guest modesetting driver uses virtio queue 1 for UPDATE_CURSOR and
MOVE_CURSOR. The host validates the fixed-size commands, snapshots at most
64x64 pixels from a known guest cursor resource and creates an AppKit cursor
with the guest hotspot. Mouse movement uses the native macOS cursor path,
independent of framebuffer repaint and renderer fences. Built-in VZ input
continues routing mouse and keyboard events. Updated images disable Xorg's
forced software cursor; old images retain their framebuffer cursor until rebuilt.

For simultaneous browser acceptance, run `gpu-browser --simultaneous-vms 2`
with the test image. The command reports each VM's backend and delivered frames,
plus cursor image/move counters for the primary guest.

`package.sh` accepts `NOTARY_PROFILE` for a saved notarytool Keychain profile.
`BROMURE_DMG_FINDER_LAYOUT=0` skips Finder's cosmetic window arrangement for
headless packaging; signing, notarization and stapling still run normally.

The GPU menu reports the effective renderer for the active window and lists
individual renderers when multiple windows are open. **Use Metal Renderer** also
appears in Hardware settings; it applies to newly created VMs and is disabled
before macOS 27. A rebuilt image keeps version 403 and the stock software Mesa
stack. Download postinstall exports its graphics marker only after the guest's
headless prerequisite check succeeds; old images without that contract remain
software. Older applications ignore the optional marker.

Native cursors consume Virtio GPU cursor images (up to 64×64) and hotspots and
use AppKit cursor rectangles; pointer motion remains native to macOS. The
`gpu-browser --simultaneous-vms 2 --cursor-check --menu-check` acceptance path
checks independent rendering and cursor presentation. On an isolated test image,
`--postinstall-check` verifies marker import through the real provisioner path.
Final worker benchmark measurements are in
`benchmarks/results/per-vm-workers.json`; historical native/Apple VZ comparisons
remain in `benchmarks/results/comparison.json`.
