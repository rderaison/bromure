# GPU path comparison — 1 October 2026

## Current 5.0.0 rerun with the 5.0.1 fixes

The current comparison uses a freshly verified published image 500 with the
candidate image 501 Mesa fixes installed in a private clone. Both guest paths
use the same clone and current optimized app build; there is no 4.0.0 baseline.
The app version was still 5.0.0 during measurement, before the requested 5.0.1
version bump. All three WebGL paths were rerun with the unchanged workload.

| Workload | Metal enabled | Metal disabled / Apple VZ | Native macOS / Metal | Speedup over VZ |
|---|---:|---:|---:|---:|
| 2,048 draws, 64×64 | 20.8 ms | 169.5 ms | 12.9 ms | 8.1× |
| 64 draws, 720p, 32 shader iterations | 32.2 ms | 965.2 ms | 22.8 ms | 30.0× |
| 24 draws, 1080p, 128 shader iterations | 68.2 ms | 3,555.1 ms | 63.9 ms | 52.1× |

The final video comparison passed all 30 trials, following a separate successful
15-trial diagnostic run. Values below are five-trial medians, using muted local
clips and browser playback counters. CPU attribution excludes shared system
services and does not measure total energy.

| Clip | Metal FPS | VZ FPS | Metal host CPU | VZ host CPU |
|---|---:|---:|---:|---:|
| H.264 1080p60 | 58.4 | 59.9 | 68.0% | 49.5% |
| H.264 4K60 | 55.5 | 59.8 | 68.6% | 85.1% |
| AV1 1080p60 | 59.8 | 59.8 | 106.0% | 69.6% |

One CPU core equals 100%. H.264 used hardware decoding on Metal; AV1 remained
software decoded. At 4K60, attributed host CPU fell 19.4%, but the median dropped
frame rate was 7.26% versus 0.084% on the legacy path. Hardware decoding is not a
uniform speed or efficiency improvement across these workloads. The final Metal
GPU-process crash count was zero.

The work fixed excessive compressed-bitstream transfers, IPC per guest page,
partial readbacks overwriting unrelated bytes, and a Mesa fence reference leak.
The fixed GPU process stayed alive for 961 observer samples with bounded fence
and descriptor counts. See the saved audit for its capture limitations.

[Current raw results and charts](results/image501-candidate-2026-10-01/),
[methodology and image provenance](results/image501-candidate-2026-10-01/METHODOLOGY.md),
[WebGL chart](results/image501-candidate-2026-10-01/comparison.png),
[video chart](results/image501-candidate-2026-10-01/video-comparison.png).

## Historical image 403 comparison

Rebuilt after merging `origin/main` (`bf277e4f`). Dependency resolution required
aligning MLX Swift to 0.32.3, matching MLX Swift LM 3.32.3. The benchmark found
and verified a renderer fix: valid Mesa 3D submissions above 64 KiB were rejected.
3D requests now allow a bounded 1 MiB throughout the VZ, host, XPC and worker path;
other requests and responses retain their 64 KiB limit and the aggregate queue
budget remains 16 MiB. The original large workload passes after this change.

The machine is an Apple M5 Pro with 18 CPU cores and 64 GiB RAM, running
macOS 27.0.1. Both guest configurations use the same Ubuntu 24.04 ARM64 image403,
Mesa 25.2.8, nine vCPUs and 4 GiB RAM. All three browsers are
Chrome 154.0.8037.57. The native browser is the official mac-arm64 Chrome for
Testing build and uses an isolated temporary profile.

| Workload | Bromure custom Virtio / Metal | Apple VZ Virtio | Native macOS / Metal | Bromure speedup over VZ |
|---|---:|---:|---:|---:|
| 2,048 draws, 64×64 | 21.1 ms | 167.4 ms | 13.1 ms | 7.9× |
| 64 draws, 720p, 32 shader iterations | 32.0 ms | 963.3 ms | 22.6 ms | 30.1× |
| 24 draws, 1080p, 128 shader iterations | 67.9 ms | 3,557.2 ms | 63.4 ms | 52.4× |

Each value is the median of five samples. Chart error bars show the observed
minimum and maximum, rather than a confidence interval. Workloads rotate order between trials.
Offscreen RGBA8 WebGL2 rendering uses the same shaders, vertex data, dimensions,
draw counts and alpha blending on every path. Eight draws warm each sample;
shader compilation, framebuffer allocation and warm-up are excluded. The timed
batch ends with a synchronous one-pixel readback, because `gl.finish()` alone
in Chrome did not reliably force completed GPU work. Timings include browser,
driver and readback overhead. They are end-to-end batch times, not GPU counters
or display frame rates. Compare platforms within each row.

Known-red framebuffer checks, shader compile/link checks, GL errors and output
alpha checks pass on all paths. Shader RGB values can differ between drivers
because repeated floating-point `sin`/`fract` operations amplify small numerical
differences; the benchmark does not require bit-identical shader RGB values.

In this Linux guest, Apple's built-in `VZVirtioGraphicsDeviceConfiguration`
negotiates no VirGL feature and Chromium renders WebGL through CPU `llvmpipe`.
The custom device negotiates VirGL and reports hardware ANGLE/VirGL; native
macOS reports ANGLE Metal / Apple M5 Pro. Both hardware paths ultimately use
the same Apple GPU. This measures the graphics paths available to this guest,
not a comparison between two physical GPUs or a general claim about macOS guests.
Apple VZ retains Bromure's normal software compositor setting; this test renders
into offscreen WebGL framebuffers.

The custom path is 61% slower than native macOS for the draw-call batch, 42%
slower at 720p, and 7% slower for the heavier 1080p shader. Command/driver
overhead matters more on small work; the hardware-heavy workload is close to
native performance. Results cover these workloads on this machine.

[Raw samples and device inventory](results/comparison.json),
[chart](results/comparison.png), [vector chart](results/comparison.svg).

## Reproduce

Build the app with `build.sh bromure` and the SDK 27 renderer. `run-webgl2.py`
works on macOS and in the guest, using the repository's tab-agent CDP transport:

```sh
python3 tools/gpu/benchmarks/run-webgl2.py \
  --agent Sources/SandboxEngine/Resources/vm-setup/scripts/tab-agent.py \
  --cdp-base http://127.0.0.1:9223 --expected-renderer 'Apple M5 Pro' \
  --output native.json
```

Launch native Chrome with an isolated profile and `--remote-debugging-port=9223`.
For each guest, copy the same runner and workload into the VM and use
`--agent /usr/local/bin/tab-agent.py`. The custom path requires
`--expected-renderer virgl`; the Apple baseline requires
`--expected-renderer llvmpipe --allow-software`.

The developer command `bromure gpu-browser --apple-virtio-gpu` selects Apple's
built-in VZ device without attaching the custom renderer. Omit that flag for the
custom device. Use the same `--storage-dir`, an `about:blank` startup page and a
`--guest-probe` that invokes the runner. Run the timed workloads sequentially, so they do not compete for
GPU compute. An unused test VM may remain idle until its developer-command
timeout closes it. `plot.py` regenerates charts from the saved JSON using
matplotlib; it does not rerun measurements.
