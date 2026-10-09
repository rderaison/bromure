# Current GPU comparison and video regression acceptance

These measurements use Bromure 5.0.0 with the renderer changes intended for
5.0.1. There is no 4.0.0 baseline. The host is an Apple M5 Pro with 18 CPU cores
and 64 GiB RAM, running macOS 27.0.1. Guest VMs use nine vCPUs and 4 GiB RAM;
normal audio devices remain configured. All browsers are Chrome 154.0.8037.57.

## Image provenance

The base was freshly downloaded through the normal image manager, including
signed-catalog verification, compressed-artifact hashes and postinstall steps.
It is published image 500, UUID `c3d89033-06a4-4321-b9c3-603f2e1246ee`, built
2026-10-01 at 21:10:46 UTC. Its compressed disk SHA256 is
`8004c2e8d0bda2a9a78fcc57df7fcf302d4825e3d68a567ebc53326613caf48f`.
The catalog was rechecked during the final measurements and still identified
that image. The pristine download was preserved.

Both final guest paths use a private clone with the pinned Mesa 25.2.8 fixes
installed, hash-checked and rebooted. This is a candidate for image 501, not a
claim that a published 501 image was downloaded. The GPU-disabled path uses
the distro Mesa libraries, while Metal uses `/opt/bromure/mesa-virgl`.
`PROVENANCE.json` records the candidate archive, library and app hashes.

## WebGL

The workload is unchanged: offscreen RGBA8 WebGL2, no antialiasing, identical
shaders, dimensions, draw counts and alpha blending. Five trials rotate the
three workloads. Each sample warms up with eight draws; compilation and
allocation are excluded. A synchronous one-pixel readback ends each timed
batch to force completion. These are end-to-end batch times, including
browser, driver and readback costs, rather than GPU counters or display FPS.
Charts show medians with observed minimum/maximum ranges.

Metal, Apple VZ and native macOS are measured sequentially. Apple VZ negotiates
no VirGL 3D feature in this Linux guest and WebGL uses CPU llvmpipe. Native
Chrome uses ANGLE Metal on the same physical Apple GPU. This compares the
graphics paths available to this guest, not two physical GPUs.

## Video

Identical SHA-pinned synthetic local clips cover H.264 1080p60, H.264 4K60 and
AV1 1080p60. Each clip loops, with three seconds of warm-up followed by a
60-second counter interval, five times per path in rotating order. The
viewport is 960 × 540 CSS pixels at DPR 2. DOM and OS fullscreen are not used.
Clips are muted and contain no audio; these tests do not establish audio
quality or synchronization despite retaining the normal VM sound devices.

The Media domain records the actual decoder and platform-decoder flag.
H.264 uses VaapiVideoDecoder backed by the host VideoToolbox implementation
on Metal; AV1 uses software Dav1d. GPU-disabled H.264 uses software decoding.
Presented FPS is the change in total frames minus dropped frames divided by
elapsed wall time. Media-clock accumulation accounts for looping. Browser
counters do not measure host display latency or establish visual absence of
flicker. Failed trials are retained, never filtered into successful charts.

Host CPU is sampled every 0.5 seconds from cumulative `ps` CPU times, with
weighted interval boundaries. Attribution includes the app, its renderer
broker/worker and the uniquely identified new VZ service. One core equals
100%. It excludes WindowServer, kernel GPU work and shared system services,
including possible VideoToolbox work. It is not total system energy or a
battery-life measurement. Final timed runs omit extra Chromium logging and
the memory observer; diagnostic results are saved separately.

## Failures found and fixed

The original Mesa video path mapped an entire multi-megabyte compressed-data
buffer while writing a much smaller bitstream. The guest now maps its actual
compressed range. Host transfers gather/scatter noncontiguous guest pages
into bounded IPC messages, and partial readbacks preserve unrelated bytes.
Actual worker tests cover range validation, page boundaries, payload limits,
readback sentinels and short guest mappings.

The longer video run also exhausted the GPU process's file descriptors:
pixmap duplication failed with EMFILE, shared-image creation failed and
Chromium restarted its GPU process on context loss. Pinned Mesa's public
flush callback overwrote an existing referenced fence. The fix replaces that
reference through the winsys reference operation while preserving internal
flush callers. The extracted upstream callback leaks after two repeated
flushes; the corrected callback balances 10,000 real-FD flushes, shared
ownership, failed submission and a caller requesting no fence.

Independent baseline inventories showed 339 → 3,841 descriptors during one
H.264 minute, then 4,023 → 7,529 during another. The fixed 15-trial diagnostic
run passed with the same GPU process throughout. The raw observer captured
961 samples over about 961.6 seconds: 61–166 total descriptors, 1–45 fence
descriptors, no OOM kill and no process identity change. The observer was
stopped after the benchmark, before its configured 1,200-second deadline;
this is not a full observer-deadline completion claim. Chromium's flattened
process titles required a diagnostic role-parser fix. Old baseline role
selection omitted the GPU, so baseline descriptor types are unavailable.

The compact audit, per-trial inventory and compressed raw trace retain those
limitations and their hashes. Runtime acceptance and throughput are distinct:
a stable hardware decoder does not imply every codec or resolution becomes
faster than the legacy compositor on this host.
