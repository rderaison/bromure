**Shared implementation branch: `feature/macos27-gpu`**

The user authorized implementation after reviewing `GPU_FEASIBILITY_STUDY.md`, assigned this session the Linux work, and assigned `@macos-gpu-work` the macOS work. Both checkouts should track this same remote branch. Start from its tip; preserve unrelated local files; commit and push small changes. Pull/rebase clean local commits when the other checkout advances the branch, resolve conflicts, and never force-push the shared branch. Do not merge to main as part of this handoff.

This session could not deliver a Bromure peer message: the tool rejected it because this session has no Bromure session identity. The branch and these documents are the durable handoff. The study was made against main `2f04f294`; its API and performance assumptions still require macOS validation.

**Ownership**

| Owner | Files and responsibility |
| --- | --- |
| Linux session | `Sources/SandboxEngine/Resources/vm-setup/`, Linux test/diagnostic scripts, this host/guest contract |
| `@macos-gpu-work` | Swift host code, renderer/helper dependencies, Metal presentation, macOS availability and packaging, host tests, guest image version selection in `LinuxImageManager.swift` |

**macOS implementation brief**

Implement the first end-to-end accelerated graphics prototype using macOS 27 custom Virtio, Linux's standard virtio-gpu/Mesa VirGL stack, and host virglrenderer + ANGLE/Metal. Confirm SDK/device validation, GPU device ID 16, two queues, feature negotiation, capability sets, resource mappings and actual guest binding first. Reuse graphics libraries; do not begin with a custom Linux GPU driver or Chromium fork.

Keep one app with the existing macOS 14 minimum. On 14/15/26 use today's graphics device and view. Isolate new APIs behind availability checks and isolate incompatible renderer libraries in a helper loaded only on supported hosts. Select devices before warming the VM. A failure to initialize the accelerated configuration should allow creating a fresh legacy VM. Keep a force-software setting on 27.

Use host texture presentation if the SDK confirms no custom scanout API for `VZVirtualMachineView`. Avoid a whole-frame host GPU → guest CPU → host display round trip. Preserve native chrome cropping, input/focus, precise scroll, cursor, resizing, HiDPI and refresh pacing. An isolated renderer must not have credential, user-file or networking authority. Validate immutable copies of command metadata; bound resources; handle fences, resets, pause/resume, stop and crashes off the UI queue.

Relevant host integration points: `LinuxImageManager.swift:294`, `VMPool.swift:690`, `VMConfig.swift:241`, `SafariSandbox.swift:2338`. Current image is Ubuntu 24.04 ARM64, version 403. The warm pool pauses idle VMs; support that lifecycle immediately. The existing image's renderer is CPU-based despite the profile's GPU setting. Compare against main's optimized software compositor, not only llvmpipe.

**Guest configuration contract, version 1**

The host already supplies a JSON object to guest `config-agent.py` on vsock 5000. Add an optional `graphicsBackend` key with exactly these values:

| Value | Guest behavior |
| --- | --- |
| omitted or `software` | Existing Mesa software rendering configuration, including current developer overrides. Compatible with older hosts. |
| `virgl` | Request Mesa hardware rendering through the host-provided standard Virtio-GPU. Enable the existing ANGLE/OpenGL and GPU rasterization flags; do not force `LIBGL_ALWAYS_SOFTWARE`. |
| unknown/non-string | Fall back to the software configuration. Never interpret values as shell code. |

`disableGPU` always wins and resolves to software configuration. `disableWebGL` remains independent and must be preserved. `graphicsBackend` identifies the actual selected device backend, not the user's GPU preference. Only send `virgl` after selecting a real accelerated device and a compatible guest image. This field is a configuration request, not proof that hardware rendering succeeded.

For `virgl`, the host MUST stop auto-appending `--disable-gpu-compositing` in `VMPool.swift`. Explicit developer flags remain overrides; report contradictory overrides during performance validation rather than silently ignoring them. Keep Vulkan disabled in the initial GL implementation. Video decoding remains software until a separately validated decoder backend exists.

Linux will emit `GRAPHICS_BACKEND=software|virgl` into `chrome-env`, and install a sourced graphics-environment helper used by xinitrc. Legacy hosts with no new field retain current behavior. A small capability file will identify guests with this config contract, and a diagnostic tool will report renderer/device evidence without claiming that launch flags prove acceleration. The macOS owner should arrange image version/capability gating before enabling `virgl`; image 403 ignores this new key and cannot be assumed compatible.

**Linux contribution available on this branch**

Backend selection and profile-policy precedence are implemented in `config-agent.py`. `graphics-env.sh` clears forced software GL for an explicit VirGL selection, and preserves the previous software/default and `NO_LIBGL_SOFTWARE` experiment behavior otherwise. The initial browser launch still disables Vulkan; no hardware-video support is advertised.

The image builder installs the new scripts, `libegl1`, `libgles2`, `mesa-utils`, and `/etc/bromure/graphics-capabilities.json`. This file advertises configuration support only, not a successful accelerated device probe. These changes require a newly built image; downloading/personalising an existing image does not retrofit them. Image-version selection remains with the macOS owner to coordinate the rebuilt artifact and backend gating.

From the chrome user's browser X session, run `DISPLAY=:0 /usr/local/bin/graphics-diagnostics.py --require-virgl` (with the session's actual XAUTHORITY if needed). It returns JSON and a nonzero status if the GLX probe fails, reports software rendering, or does not identify VirGL. `guestReportsVirgl` is guest-side evidence only; `hostGPUVerified` remains null. Verify Chromium's own selection and Metal activity separately. The diagnostic does not execute arbitrary chrome-env contents or report proxy credentials.

Linux checks: `python3 -B -m unittest discover -s Tests/GuestGraphicsTests -v`, plus `sh -n` for each of the modified shell scripts. Tests exercise actual chrome-env generation and POSIX shell environment selection, including malformed backend values, profile GPU/WebGL policy and explicit developer overrides. No guest image has been baked or boot-tested here yet.

**Delivery sequence and validation**

1. Linux: implement backend-aware configuration and environment selection, install Mesa probing tools/capability marker, and run Linux unit/shell integration tests. Supply diagnostics for actual guest testing.
2. macOS: confirm SDK and custom-device feasibility; boot existing guest driver; implement the renderer/resource backend and real host presentation. Report findings and any contract changes needed.
3. Together: rebuild the guest image, verify renderer identity and Metal activity, compare scrolling/canvas/WebGL at 1×/2× and 60/120 Hz, and validate old-host fallback and warm-pool lifecycle.
4. Video follow-on: evaluate guest VA-API/Mesa VirGL video with a new host VideoToolbox backend first. Alternative virtio-media/V4L2 has current DMA-BUF/export gaps. Design the shared resource registry for NV12/P010 surfaces now, but do not advertise hardware decode before it exists. Start unencrypted H.264; retain software codec fallback. See the study for surface sharing, codec translation and isolation details.

Proposed performance gate: verified host GPU execution and no normal scanout readback, with materially fewer missed frames or at least 30% lower total CPU at equal visible cadence, no material p95 input-latency regression, and reliable crash/reset/multi-VM behavior. These are targets, not claimed results.
