# Presentation and profile acceptance — 2026-10-01

macOS 27.0.1, Apple M5 Pro; rebuilt image403, private test storage.

## Changes

Publish scanout on RESOURCE_FLUSH, not the preceding SET_SCANOUT binding. Reuse the renderer's Metal capture command queue. Preserve cursor backing alpha even when its allocation format is XRGB (Linux reuses that allocation as ARGB cursor storage).

During a trusted geometry change, retain the previous painted frame for at most 150 ms when the candidate visible region is mostly black or contains cleared RGBA holes. The first candidate anchors the deadline; later resize activity cannot extend it. Keep only the previous frame and latest candidate. Normal steady-state black frames display immediately. Valid dark content or black areas with zero XRGB padding can also match this heuristic and be delayed up to 150 ms during a resize; thresholds are conservative sufficient conditions, not exact pixel coverage. This is a bounded presentation policy, not a protocol paint-completion guarantee.

Profile editor Performance now includes Metal Renderer, enabled by default including profiles without the new key. It is disabled on unsupported hosts (macOS 26 and earlier) and when GPU acceleration is off. Profile opt-out selects a dedicated legacy VM when the prewarmed pool uses Metal. The global Metal setting remains the master switch; changes apply to new windows.

## Evidence

- 42 guest tests pass on Darwin.
- Real-worker cursor fixture preserves alpha 0/128/255 for formats 1 and 2 and checks BGRA conversion.
- Real Metal/IOSurface handoff fixtures check texture contents, bounded deadlines, changed and unchanged geometry, reset, legitimate black, partial repaint, native chrome exclusion, scalar tails, 5K/8K allocations.
- Live uniform-content resize with host input: accepted resized frames retain the painted center; 40 own-window screenshots contain zero black centers. Maximum actual captured scanout was 5120×1988 (host screen constrained window height). This is center evidence, not exhaustive verification of every onscreen pixel.
- Native-crop host-to-DOM clicks pass before and after resize. Final Developer ID signed production bundle repeats this test: 62 accepted painted-fixture frames, zero black centers, zero rejected GPU commands, 26 native cursor images. Notarization is tracked separately from this runtime test.
- Live profile opt-out test prewarms Metal, decodes an older profile (default on), round-trips explicit off, claims the off profile, and verifies a separate legacy VM with no custom graphics session. Guest reports llvmpipe.
- Release product builds successfully. Full Swift test target remains blocked by existing unrelated AgentCoding MLX newCache errors; profile serialization assertions also run in the live developer acceptance command.
- Actual macOS 26 host runtime testing remains unavailable; eligibility guard and legacy path on macOS 27 are verified.

## Scroll pacing

The fixed 500×410 CSS scroll-container rAF workload (DPR 2, 100 cards, 16 seconds sampled) produced an unloaded Metal repeat mean 16.666 ms / p95 16.8 ms and Apple VZ mean 16.682 ms / p95 16.8 ms, with no >25 ms samples in either. An earlier Metal run during concurrent compilation had mean 21.56 ms / p95 33.4 ms. These measure guest animation scheduling, not host presentation rate or trackpad input latency. They do not establish an overall browser speedup or eliminate performance variability under load.

Existing five-trial WebGL comparison results are separate, workload-specific measurements in ../benchmarks/results/comparison.json. Native Chrome is the native baseline; Apple VZ guest uses software llvmpipe for 3D. Do not describe its baseline as native Apple GPU rendering.
