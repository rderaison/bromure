# Shared-window capture and video cadence

`RESOURCE_FLUSH` damage and `SET_SCANOUT` crops use resource coordinates.
The worker exports output zero only when its accepted crop intersects the
validated damage. The processor requests other outputs only when their
accepted binding uses that resource and intersects the damage. Rectangles
are half-open; touching edges do not intersect. The processor uses UInt64
sums to avoid overflow. Failed commands do not change bindings, and
unbind/unref/reset remove them. Existing explicit guest fence completion
remains in the worker's common reply path.

Every intersecting flush still exports a fresh complete crop. There is no
content cache or assumption about future asynchronous texture writers.

## Reproduce

Generate the private guest probe with an existing local H.264 1080p60 clip:

```sh
python3 tools/gpu/benchmarks/make-shared-window-video-probe.py \
  --clip /path/to/clip.mp4 --animated-siblings --output /tmp/video-probe.py
```

Run a packaged preview, using a private compatible image:

```sh
BROMURE_GPU_CAPTURE_TRACE=1 /path/to/Bromure.app/Contents/MacOS/bromure \
  gpu-browser --storage-dir /path/to/private-image --seconds 130 \
  --shared-scanouts 3 --shared-native-windows --shared-native-window-count 3 \
  --native-chrome --without-audio --guest-probe /tmp/video-probe.py \
  --require-gpu-check --check-timeout 125 --url about:blank
```

Use initial window count 1 for the same-capacity one-window control. Omit
`--animated-siblings` for idle siblings. `BROMURE_GPU_CAPTURE_ALL_BENCHMARK=1`
reconstructs the former secondary-output capture policy; output-zero damage
filtering stays active, so this is not an unchanged historical binary.

The probe creates local test content, observes three ten-second trials after
warmup, and records Media decoder properties. The ten-second clip loops;
`currentTime` endpoint differences therefore do not measure elapsed playback.
Video quality drop counters measure browser-reported drops. rAF/rVFC callbacks
and completed host GPU submissions do not establish physical display FPS.
Audio is omitted because physical-machine audio validation was deferred.

## Focused tests

- `test-scanout-damage.swift`: actual processor, fake accepted/rejected XPC
  replies; edges, crops, resources, overflow, rebinding and lifetime.
- `test-scanout-damage-xpc.m`: real worker/XPC; primary/secondary crops,
  intersecting/repeated/full damage, fenced skip, red-to-green repaint,
  error recovery, rebind, independent renderer teardown.
- `test-scanout-crop.m`: every pixel of three distinct actual Metal crops.

Recorded results and limitations are in
`acceptance/shared-window-video-20261002.json`.
