# Parallel browser stress investigation — 2026-10-01

Status: **acceptance incomplete**. This record supersedes the earlier center-only
presentation acceptance as evidence for the user's broader parallel workload.

Host: macOS 27.0.1, M5 Pro, 64 GiB. Four Linux guests, 9 vCPUs and 4 GiB each,
private rebuilt image403. Version500 is configured for the next image build;
these runs explicitly allow the older private test image. Hardware video decoding
remains enabled. Diagnostic previews are ad hoc signed, not release packages.

## Workload and results

Each browser opens six tabs (24 total), visits ten sites, scrolls, activates five
background tabs, closes those tabs, and resizes repeatedly. Sites include Apple,
YouTube, Slashdot, Google, Wikipedia, MDN, GitHub, BBC and a Three.js demo.
Native host clicks target a controlled page before, during and after resize.
Event handlers record coordinates and geometry at event time. Moving-layout
checks allow six CSS pixels; settled checks allow three. Those bounds are test
tolerances, not the pointer protocol's quantization precision.

The transaction-presentation run completed all forty visits and twenty background
tab activations, with all four browsers reporting zero GPU process crashes and
closing back to one tab. No rejected GPU commands or guest RCU stalls appeared.
All three click checks passed in every browser. The logged clicks did not occur
while a frame was retained, so this does not establish live retained-frame input
correctness.

Four 130-second native window recordings contain 7,429–7,435 frames each. The
near-black sampler flagged 66, 115, 61 and 23 frames respectively (longest runs
16, 80, 19 and 8). Dark content can legitimately satisfy that metric; it requires
inspection. VM2 at 13.85/13.90/13.95 seconds visibly shows orange fixture, black
guest body, orange fixture. This is a real unresolved resize flash. The matching
host log accepted a center-black frame before the fallback deadline, followed
by painted content approximately 18 ms later. AppKit transaction presentation
alone therefore does not resolve the problem.

Window movies use the recording's initial canvas and can clip content when the
window grows. They do not prove coverage of every pixel at every later size.

## Resolved allocation failure

The first workload exhausted fixed 1 GiB resource-accounting pools. Commit
bc7246dc allows bounded growth on demand without changing individual resource
or backing limits. Real-worker tests exercise both pools above 1 GiB, releases
back to zero, and rejection at the staging ceiling. These are per-worker
accounting bounds, not a global resident-memory cap. Four workers on this 64 GiB
host can account up to 24 GiB in GPU plus staging resources before guest memory
and other overhead. The subsequent workload no longer reports allocation
rejections.

## Audio blocker

Audio-enabled four-VM runs stall guest CPU0 and produce PCM start/stop timeouts.
An output-only virtual sound-device run reproduces the failure, so microphone
capture is not necessary to trigger it. Independently, native macOS `afplay`
hangs on a one-second local WAV after all test VMs have stopped. Both native
and VZ audio samples wait in AudioQueueStart → StartIO_Sync → AwaitIOCycle.
This implicates the host playback startup path but does not identify its root
cause. No global audio service restart or guest kernel patch has been applied.

The completed graphics workload omitted the virtual sound device as an explicit
diagnostic. That is not a production fix or movie/audio acceptance. Video
progress alone is not evidence of audible playback. Audio-enabled acceptance
requires a working native baseline, actual running guest playback with advancing
hardware pointers, and the matching parallel workload.

## Local artifacts

Logs: `/private/tmp/bromure-stress-tabs-transaction-live.log` and
`/private/tmp/bromure-stress-tabs-source-live.log`. Movies and per-frame analyses:
`/private/tmp/bromure-transaction-vm{1,2,3,4}.mov` and corresponding
`-analysis.txt` files. Artifacts are local; this document does not imply they
were uploaded or included in a distributed package.

## Latest ready-page workload (1200 ms policy)

The hardware-decoding-enabled `ready` run completed all forty visits, twenty
background-tab activations and closed back to one tab per VM, with zero GPU
process crashes. The probe waits at most thirty seconds for an interactive or
complete document and obtains a screenshot before dispatching scroll input.
VM4's first YouTube document required 27.91 seconds; subsequent screenshot and
wheel operations succeeded. Earlier fixed-three-second runs timed out on the
first YouTube wheel, including with hardware decoding disabled. Those failures
remain recorded; this experiment does not establish real host input health
while a document is still loading.

Four 200-second recordings contained 11,430 / 11,431 / 11,422 / 11,431 frames.
The near-black counts were 0 / 0 / 0 / 54. VM4's consecutive black interval
at movie timestamps 98.783–99.700 seconds was visually confirmed between a
painted Three.js page and its repainted frame. Therefore presentation acceptance
still fails despite successful browser liveness and navigation. The configured
1200 ms candidate deadline is not an end-to-end latency guarantee, and is not
being increased further. A trace-enabled matching workload is collecting
eligibility, mode-request and candidate state to isolate this remaining flash.

The tested preview executable SHA256 is
`d2c18f41ad61c118664f2c648ff3954e65fdef92aedaa1b09751a7a115af934b`.
Artifacts: `/private/tmp/bromure-stress-tabs-ready-live.log`,
`/private/tmp/bromure-ready-vm{1,2,3,4}.mov` and corresponding analyses.
These diagnostics omitted virtual audio; production audio acceptance remains
outstanding. No new notarized release or version500 image is implied.

### Matching trace runs

`readytrace` completed all forty visits and recorded zero near-black frames in
all four movies. Its independent moving-click checker failed one event because
DOM screen dimensions disagreed with the host active scanout; stale DOM metrics
are a hypothesis, not a verified explanation. No tolerance was widened.

`drawtrace` also completed forty visits. Three movies had zero near-black frames;
VM4 had one, at timestamp27.0667. Matching host logs show a valid imported
2872x1912 source, no hold expiry and no nil-texture draw. Source black coverage
changed from roughly53% to71% to87% before repainting, so source-region
classification remains under investigation. The coordinate checker passed all
twelve clicks in this run. A passive X11 diagnostic and exact accepted-source
snapshots are being prepared; intermittent failure prevents declaring acceptance.

## Crop, independent input evidence and scheduler follow-up

The source crop now anchors hidden Chromium rows to the visible content rather
than a fixed host inset during aspect fitting. Metal scissors fitted content
and clamps sampling to visible texel centers, including letterboxing and
upscaled boundaries. Actual window captures with red hidden rows and green
content pass wide and upscaled cases; no hidden red pixels or edge bleed appear.
Active-screen pointer inversion uses the corresponding crop and visible-pixel
centers, including points outside content without dropping button releases.

Passive X11 RECORD traces corroborate all24 transitions in the `cropx11` run
within one physical pixel, with geometry references independently checked against
ordered root Configure events. This is transport evidence, not proof of visual
hit targets in a retained old frame. That run still failed a Three.js screenshot
and subsequent same-target Runtime/FrameTree calls; browser GPU queries and
kernel counters remained responsive. Earlier diagnostics omitted process leaders;
failure capture now includes every Chromium task, twice one second apart.

The `cropfinal` run completed forty visits, but VM1's200-second recording had
18 consecutive black frames. An exact accepted-source snapshot is fully black;
its anchored hold expired after1.2s and healthy guest paint arrived1.82s after
first hold. No additional timeout increase is applied. Movie durations come from
AVAsset metadata, not frame counts; reduced frame counts do not imply shortened
recordings.

The scheduler now defers subsequent modesets while a bounded clear handoff is
held, rechecks immediately before emitting, and resumes latest pending geometry
on resolution even without an exact mode acknowledgment. Request generations
protect canceled progress callbacks. Forced import failure retains prior paint
and releases expired progress without treating the failed surface as an
acknowledgment. Focused fixtures pass, alongside42 guest tests and6 evidence
checker regressions. This is a load-reduction experiment pending live acceptance,
not a proven explanation for the1.82s repaint.

Notarization keychain profile `Bromure` was rechecked successfully; credentials
are available for the full `package.sh` release workflow after acceptance.

### Paced live result

The traced paced run completed all40 visits with zero GPU process crashes.
Its four200-second recordings have0 near-black frames each; no clear-hold
expiry appears. Preview executable SHA256:
`b9f76bb6f8724b8eed1760b27dc899803988548844bc8d7990c7f4318fb44175`.
This is a finite tested workload, not a guarantee for every future page.

One moving release check remains under review: VM2 root changed from2440x1624
to2552x1692 between down/up, with identical normalized axis values and unchanged
actual root pointer coordinates610,680. The checker expected re-scaling on
release and failed by28px. Kernel filtering of unchanged ABS values is a
hypothesis awaiting source verification; the failure has not been relabeled.

Native `afplay` subsequently returned0 for the same one-second WAV, without an
audio-service restart by this agent. The native baseline has recovered; a
matching virtual-audio-enabled workload is now required. Packaging credentials
are working, but no newly notarized artifact has been delivered yet.
