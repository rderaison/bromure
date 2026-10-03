# Local screen versus remote access

This suite runs the actual Bromure app in two sequential conditions: Metal,
then the Apple VZ graphics device with guest software rendering. It performs
five rotated trials of the existing three WebGL throughput cases, then renders
a moving 1920×1080 WebGL canvas for 33 seconds (3-second warm-up, 30-second sample).
The visible test retains every requestAnimationFrame interval and reports p50,
p95 and p99. Image metadata, browser/GPU identity, crash counts, binary/workload
hashes, display configuration and thermal warnings accompany the raw logs.
No internet assets or additional guest packages are required.

Package a build made with the repository's main `./package.sh`:

```sh
tools/gpu/benchmarks/screen-access/package.sh /path/to/Bromure.app
```

The package preserves the signed app unchanged. It requires macOS 27, Python 3
(`/usr/bin/python3`, provided by Apple's command-line developer tools), and an
installed image 501. It neither downloads an image nor changes saved profiles.
The actual catalog version in image-state.json is checked; an app cache stamp
alone is insufficient. A verified private patched image can be selected
explicitly with `--storage-dir PATH --allow-candidate-image`.

Double-click **Run local.command** with a physical screen, and **Run remote.command**
while connected through macOS Screen Sharing. For another remote client set
`BROMURE_REMOTE_CLIENT`, or use the CLI:

```sh
python3 suite/run.py --app ./Bromure.app --access remote --remote-client 'Your client'
```

Keep the benchmark window visible and unobscured throughout. Use the same host,
power mode, remote resolution, display scale and window geometry. Do at least
three runs in alternating access order. Record whether a physical display or
dummy plug is connected during the remote run. Remote connectivity is an
operator label, not automatically inferred from monitor presence. The runner
does not attach/disconnect remote sessions. Results go to `~/Desktop/Bromure benchmarks`.

Throughput measures synchronous guest WebGL completion; rAF measures guest frame
scheduling. Neither measures end-to-end remote-client video latency. Host delivered
frame counts are scanouts, not proof that every frame reached a physical or remote
screen. Use an external camera/client capture for that comparison. This suite
does not test video decoding or audio. A hidden or crashed browser fails acceptance.
The command reports failures rather than silently dropping failed trials.

Compare completed runs:

```sh
python3 suite/compare.py '/path/to/local/results.json' '/path/to/remote/results.json'
```

The comparison rejects different app binaries, workloads, image metadata and
visible viewport geometry, and rejects failed runs. Lower milliseconds are better.

For a self-contained private benchmark package, pass a verified image directory
as the third packaging argument. The scripts select the bundled **Test image**
and explicitly retain its original catalog version and candidate override in
results. This is a benchmark candidate, not a public image-501 release. The disk
is APFS-cloned where supported; transferring the folder still transfers the image.

For an SSH-only/no-remote-desktop condition, use **Run headless.command**.
It still runs the same macOS window and guest workload; it does not switch to
a headless Chromium renderer. The access label is recorded as `headless`.
