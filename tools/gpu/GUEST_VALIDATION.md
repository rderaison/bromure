# Guest graphics validation

These checks separate image packaging, guest rendering, browser rendering and
host execution. None substitutes for the next. H.264 hardware decoding is implemented; inspect the actual browser decoder and
output pixels as well as the host hardware-only session.

## Evidence so far

- The macOS owner's probes (`5ea78851`, `fab58a3e`) validate a custom Virtio GPU
  device on macOS 27.0.1/SDK 27. Image 403's stock 6.8.0-142-generic
  `virtio_gpu` module binds, reaches DRIVER_OK, sends GET_DISPLAY_INFO and
  creates DRM nodes. Two pause/resume cycles passed. No custom kernel driver
  is currently justified.
- The Linux development workspace has Ubuntu 24.04 ARM64 Mesa
  `25.2.8-0ubuntu0.24.04.2`. Its `virtio_gpu_dri.so` resolves to
  `libdril_dri.so`, exports `__driDriverGetExtensions_virtio_gpu`, and loads.
  Its separate Gallium library and Mesa EGL/GLX/GBM libraries also load.
  This is workspace packaging evidence, not an inventory of shipped image 403.
- The macOS owner subsequently verified the installed Bromure browser with
  ANGLE Mesa VirGL, GPU compositing, WebGL2 antialiasing and IOSurface scanout.
  Actual H.264 Baseline/Main/High playback passes with at least 250 frames and
  correct RGB output; VP9 software fallback also passes. See
  `results/chromium-hardware-video-metal.json` and
  `results/installed-bromure-metal.json`. GPU workload measurements are in
  `benchmarks/`; they are not measurements of movie power use or input latency.

## 1. Inventory and rebuild

Inside an existing image, copy and run the repository's
`graphics-prerequisites.py` with Python 3. It needs neither X nor a running
browser. Missing capability/agent files on the original downloaded image 403 are expected. Keep its
package versions and loader results for comparison with the rebuilt image.

The updated image builder explicitly installs Mesa DRI, EGL, GLX and GBM;
GLVND EGL/GLES; VA-API runtimes; vainfo; and mesa-utils. It also builds the
pinned patched Mesa and Chromium-scoped libva compatibility library under /opt. It installs the backend-aware agent, environment
helper and diagnostics. Its headless gate runs:

```sh
/usr/local/bin/graphics-prerequisites.py --require-ready
```

`readyForGuestProbe: true` establishes packaging prerequisites only. For a
Google Chrome postinstall, also run with `--browser google-chrome-stable`.
The build's inventory is saved in `/etc/bromure/graphics-prerequisites.json`;
rerun the command after package changes rather than trusting the saved report.

The tested rebuild retains image stamp 403. Tie host selection to the installed
capability contract and validated artifact, not a numeric version comparison.
The original downloaded 403 and the rebuilt 403 have different capabilities.
The check validates both system Mesa and the patched video stack if advertised;
it never reports hardware decoding as verified without a live test.

## 2. Probe a real accelerated device

Boot the rebuilt image with the custom GPU and renderer initialized. Send
`graphicsBackend: "virgl"` via the normal host configuration; leave Vulkan
disabled and remove the host's automatic `--disable-gpu-compositing` for this
backend. Use `--use-angle=gles` for the Metal-backed GLES renderer. Respect profile `disableGPU` and `disableWebGL` policies.

As the chrome user in its actual X session:

```sh
DISPLAY=:0 /usr/local/bin/graphics-diagnostics.py --require-virgl
```

Use the session's XAUTHORITY if required. Save the JSON, DRM node permissions,
kernel log and Xorg log. Require successful GLX creation and a VirGL renderer
with no software-renderer identity. If X fails, investigate DRM node access,
scanout and Xorg modesetting/glamor/DRI setup before adding browser flags.
Do not override `MESA_LOADER_DRIVER_OVERRIDE` to conceal a failed device probe.

## 3. Verify Chromium and host Metal

Collect `chrome://gpu` or CDP `SystemInfo.getInfo` from the actual browser
session. Record GL vendor/renderer, compositor/rasterization status, GPU process
failures and WebGL behavior. Check the effective command line for contradictory
developer flags. A successful external GLX probe does not establish Chromium's
backend choice.

Correlate guest/browser workload with the host Metal renderer, command
submission and visible scanout. Verify that ordinary frame presentation does
not read the full texture back to CPU memory. Clear/readback host probes test
correctness, but are not the presentation design or a performance measurement.

Compare scroll, canvas and WebGL against main's optimized software compositor,
including total host plus guest CPU, frame cadence and input latency. Exercise
resize/HiDPI, multiple VMs, pause/resume, stop/reset and helper crashes.

## 4. Compatibility and video

The default/missing backend remains software. Test the rebuilt image with the
legacy device on macOS 26 and supported older versions, as well as forced
software on macOS 27. New SDK APIs and renderer libraries must remain isolated
from the older host path. Test image 403 with the old path separately.

Neither renderer identity nor Mesa's optional VA-API package proves hardware
video decoding. Run actual H.264 playback and require Chromium's Media data to
identify `VaapiVideoDecoder`, platform decoding, progressing frames and correct
pixels. Confirm the host VideoToolbox session uses hardware. The implemented
backend covers progressive 8-bit 4:2:0 H.264; exercise unsupported codecs through
software fallback. `videoDecodeBackends` advertises installed support, not a
successful decode test. No zero-copy Chromium video claim is made.
