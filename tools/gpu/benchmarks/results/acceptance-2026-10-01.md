# Final per-VM renderer acceptance

Host: Apple M5 Pro, macOS 27.0.1 (26A434), Apple Silicon.
Guest: rebuilt image403, Ubuntu 24.04 ARM64, Mesa 25.2.8, Chromium 154.

- XPC test: two separate workers reused the same context/resource identifiers,
  preserved independent red/blue surfaces, and the second continued after the
  first connection was closed.
- Two simultaneous browser VMs selected VirGL and delivered frames. Final
  menu/prerequisite test recorded six native host cursor images, 30 cursor
  moves, and 17 frames from the second VM. The menu reported Metal.
- Hardware H264 browser playback selected VaapiVideoDecoder, decoded 252
  frames at 720p, and returned the expected red pixel with no media errors.
  That run also recorded 11 native cursor images and 35 moves.
- Headless `graphics-prerequisites.py --require-ready` passed in the real
  image. `image403-prerequisites.json` retains its packaging evidence;
  `hardwareDecodeVerified: null` deliberately does not claim runtime decode.
  Runtime decode was checked separately by the browser test above.
- The actual provisioner/postinstall path exported a validated marker from
  the guest and imported it into host storage after an initially absent marker.
- The rebuilt image booted using Apple's built-in VZ graphics device on
  macOS 27. Chromium selected the stock llvmpipe Mesa stack, WebGL2 returned
  [255, 0, 0, 255] with GL error zero, missing backend configuration resolved
  to software, and the menu reported Software.
- No older macOS host was available. The legacy-device test on 27 is not
  runtime validation on macOS 14–26. The main executable retains its macOS 14
  deployment target and the custom GPU/device/helper path is guarded by 27.
- 21 Linux guest prerequisite/configuration regression tests and 13 real
  standalone worker protocol tests passed.

`per-vm-workers.json` records the final custom renderer timings with a second
idle accelerated VM. `comparison.json` retains the original Apple VZ and native
Metal comparison; those baselines were not rerun for the worker-only change.
