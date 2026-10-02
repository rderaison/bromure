# Current Bromure 5 GPU comparison

Host build: `f59ab22e` (exact SHA in comparison.json), optimized arm64 release, application version5.0.0. The executable is packaged as an isolated developer preview with the pinned renderer broker/worker. This is a benchmark build, not a newly notarized delivery artifact.

The host is an Apple M5 Pro,18CPUcores,64GiB RAM,macOS27.0.1. Both VM paths use9vCPUs and4GiB RAM and the same freshly downloaded image500: UUID `c3d89033-06a4-4321-b9c3-603f2e1246ee`, published2026-10-01T21:10:46Z. Normal `init --download-only` validated the signed catalog and compressed-file hashes, then ran ordinary postinstall customization. No locally rebuilt image fallback was permitted. Catalog, applied-step state and graphics capability marker are saved beside the results.

WebGL uses the original unchanged workload SHA256 `4a55951b219bccd0f342323bef1265ca4dd34fbd342f626089e8695147379807`, three workloads, five trials, rotated order,8warmup draws, identical GLSL and synchronous1pixel readback. Timings exclude compilation/allocation and include browser/driver/readback work. The two VM measurements were rerun after the fresh image download. Native Chrome154.0.8037.57 was remeasured during the same session on this current build before the image download; it does not consume the Linux image. All three report that same browser version. These are batch completion times, not page-load times or display latency.

Video uses identical locally served synthetic10second `testsrc2` clips, looped for each trial: H.2641080p60, H.2643840x2160 at60fps, and AV11080p60. Clip hashes and encoder commands are recorded. Each trial has3seconds warmup followed by60seconds measurement; five trials rotate clip order. All paths use a persistent CDP connection and a controlled960x540 CSS viewport with DPR2. Video fills that viewport using object-fit:contain. DOM/OS fullscreen is not used: the guest fullscreen setup exited during the initial smoke test. This is viewport-controlled playback, not acceptance of host fullscreen behavior or every onscreen pixel.

Record total/dropped frame-counter deltas, presented frames per wall second, and media-clock progress including loop wraps. A low dropped-frame percentage can conceal slower-than-real-time playback, so it must be considered alongside playback speed. Media-domain properties record the actual selected decoder and platform-decoder flag. Clips are muted and contain no audio: these results do not measure audio synchronization or audio output.

Host CPU samples use0.5second snapshots of cumulative per-process CPU time. The new unique VZ VM service is identified at startup; application and renderer broker/worker processes are separately tracked. Boundary intervals are weighted by trial overlap.100% means one fully occupied CPU core. This does not include WindowServer, kernel GPU work or shared system daemons and is not a measurement of total system energy. Browser video counters likewise do not measure final host display presentation latency.

The user requested the same Bromure5build with acceleration enabled versus disabled; no4.x release is measured. Native video smoke/partial samples are retained as diagnostic evidence but do not form a completed five-trial comparison and are omitted from the public video chart.

Earlier image403 results and partial video runs are retained in a separate directory and are not promoted to image500 results. The user also reports successful actual macOS26 testing; that is a user-reported compatibility pass, not an automated macOS14–26 test matrix.

Video results are pending completion.
