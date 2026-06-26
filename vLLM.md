# Local Model Inference for Bromure Agentic Coding — Integration Plan

Status: draft / design agreed, implementation not started.
Goal: let Bromure run coding models **locally on the Mac host** and expose them to the
agents running **inside the disposable Linux VMs**, with an MLX-based engine, easy
no-conversion model downloads, and a cloud↔local routing layer.

---

## 0. TL;DR

- Inference runs as a **host (macOS) subprocess** — the Linux guests have no
  GPU/Metal/MLX access, so this is the only option. This matches the
  "sub-process + proxy" instinct.
- Engine: **`vllm-mlx`** (MLX backend, OpenAI **and Anthropic** compatible,
  agent-grade tool-calling, prefix caching, continuous batching). This is the
  engine that actually satisfies "only MLX" *and* fits agentic coding.
- One shared engine, reachable through **two front doors**:
  1. **Env-var pin** inside the VM (`ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL`) —
     explicit, always-local, no interception.
  2. **MITM interception** — transparent; the agent targets `api.anthropic.com`
     and we re-route.
- **Routing is a top-level, per-VM axis** (`Cloud | Local | Hybrid`), independent
  of the existing **Fusion** (host-credential) axis.
- **Curated MLX model catalog** (bundled + remote-refreshable JSON) with RAM-fit
  gating and tool-calling verification, plus a "paste any HF MLX repo" escape hatch.
- Users **never convert or self-distribute models** — pre-converted MLX weights are
  pulled straight from Hugging Face (`mlx-community/...` and friends).

---

## 1. Why these choices (context)

### 1.1 llama.cpp ≠ MLX
llama.cpp has **no MLX backend** — on Apple Silicon it uses its own **Metal**
backend and the **GGUF** format. "Integrate llama.cpp for MLX" is not achievable;
llama.cpp would give Metal, not MLX. The MLX runtimes are `mlx-lm`, Ollama's new
MLX engine (preview, narrow architecture support), and vLLM's MLX path.

### 1.2 vLLM on Apple Silicon is now an MLX engine
Two flavors exist:
- **`vllm-metal`** — official community plugin (Docker + vLLM project) running
  vLLM with **MLX as the primary compute backend**. v0.2.0 (Apr 2026) added a
  unified paged Metal attention kernel (~83× TTFT, 3.6× throughput vs v0.1.0).
  arm64 Python 3.12 only.
- **`vllm-mlx`** (waybarrios) — community vLLM-style server, MLX backend,
  ~400+ tok/s, continuous batching, paged KV cache, **prefix caching**, SSD-tiered
  cache, MCP tool calling, exposing **both OpenAI `/v1/*` and Anthropic
  `/v1/messages`** from one process. Explicitly "works with Claude Code" and
  handles structured tool calls that break on other quantized frameworks.

**We standardize on `vllm-mlx`** because, for agentic coding:
1. It's MLX (honors the requirement; llama.cpp can't).
2. **Anthropic-native API** → drop-in for Claude-shaped agents, no OpenAI↔Anthropic
   shim. This is the decisive property for the MITM/hybrid path (no protocol
   translation = tool-calling stays intact).
3. **Reliable quantized tool-calling + prefix caching** — the two things coding
   agents need (tools that don't break; cheap re-sends of huge system prompts).
4. Continuous batching → multiple VMs can share one engine.

Tradeoffs to accept: younger community project (two near-identical forks:
`waybarrios`, `raullenchai`), Python-based (vendor a venv or require install),
batching edge only matters under concurrency.

**Fallback engine:** keep the engine *pluggable* and offer **Ollama** as the
"I just want to pull any model, easiest UX" path (GGUF/Metal, broadest coverage).
`mlx-lm` (Apple-official, OpenAI-only) and a bundled `llama-server` (Metal, not MLX)
are lower-priority alternatives.

### 1.3 Inference must run on the host
Virtualization.framework gives the Linux guest **no GPU / Metal / MLX**. The engine
runs on macOS; guests reach it over the network. The agents live *inside* the guest
(via the `vm exec` path), so the entire integration is about wiring guest → host
engine.

---

## 2. Architecture

```
                          macOS host
   ┌─────────────────────────────────────────────────────────┐
   │  InferenceService (Swift)                                 │
   │    └─ supervises vllm-mlx subprocess                      │
   │         bound to 127.0.0.1:<engine-port>  (loopback only) │
   │         serves /v1/*  and  /v1/messages                   │
   │                                                           │
   │  MITM engine (per-profile)        Catalog + downloads     │
   │    └─ Routing: Cloud|Local|Hybrid    (HF hub)             │
   │    └─ Fusion: host-cred swap                              │
   └───────▲───────────────────────────▲──────────────────────┘
           │ vsock 8446 (new)           │ on-host 127.0.0.1 call
           │ (bridge → guest TCP)       │
   ┌───────┼───────────────────────────┼──────────────────────┐
   │  Linux guest                      │                       │
   │   bromure-vm-bridge.py            │                       │
   │     127.0.0.1:11434 ──────────────┘ (Path 1 door)         │
   │                                                           │
   │   coding agent                                            │
   │     Path 1: ANTHROPIC_BASE_URL=http://127.0.0.1:11434     │
   │     Path 2: targets api.anthropic.com → MITM re-routes    │
   └───────────────────────────────────────────────────────────┘
```

**One engine, two doors, shared model load.** Path 1 reaches the engine via the
vsock bridge; Path 2 (MITM) reaches it on-host at `127.0.0.1:<engine-port>`.

### 2.1 Why the vsock bridge (not the NAT gateway IP)
The guest *could* reach a host server at the NAT gateway `192.168.64.1`
(`VMNetSwitch.swift`), but that exposes the engine to every VM on the subnet and
shifts if the subnet walks. The AC variant already pumps vsock → guest-TCP for the
mitm/ssh/aws services (ports 8443/8444/8445 in `MitmEngine.register()`, forwarded
by `bromure-vm-bridge.py`). **Adding one more vsock port (8446) is a copy-paste of
that pattern** and gives a per-VM, loopback-only endpoint. Recommended.

---

## 3. Component plan (host)

### 3.1 `InferenceService` (new Swift module)
Lives alongside `HostServices`, or in the AC target where the agent lives.

- **Process supervisor** — spawn/supervise the `vllm-mlx` server subprocess.
  - Lazy-start on first request; readiness via `/v1/models` (or `/health`).
  - Auto-restart on crash; graceful teardown with the app.
  - **Bind `127.0.0.1:<engine-port>` only** — never `0.0.0.0`.
  - **Decided: a single shared instance serves all VMs** — model weights load once
    (decisive for a ~100 GB GLM-5.2), continuous batching + prefix caching are shared.
    Tradeoff accepted: VMs share one model/KV namespace, no per-VM isolation.
- **Binary/runtime acquisition** — `vllm-mlx` is Python (arm64 3.12).
  **Decided: vendor a pinned arm64 Python 3.12 venv inside the app bundle.**
  Reproducible, zero user setup, works offline. Implications to handle:
  - **Codesign the embedded interpreter + all `.so`/`.dylib`** for the
    virtualization-entitlement build (`build.sh` must walk the venv and sign each
    Mach-O); hardened-runtime exceptions as needed for the Python runtime.
  - Pin exact versions (`vllm-mlx`, `mlx`, `mlx-lm`, transitive wheels) in a lockfile;
    bundle wheels so the build is hermetic (no network at build time).
  - Bundle size grows materially — keep the venv out of the SPM resource bundle hot
    path; copy it in `build.sh` like the other `Bundle.module` resources.
- **Active-model handle** — knows which catalog model is loaded; exposes switch.

### 3.2 vsock proxy (Path 1 plumbing)
- Register a new vsock listener on **port 8446** in `MitmEngine.register()`
  (alongside 8443/8444/8445) that pumps to `127.0.0.1:<engine-port>`.
- Add the matching forward in `bromure-vm-bridge.py` so the guest sees the engine at
  `http://127.0.0.1:11434` (raw TCP pump, same shape as the existing bridges).

### 3.3 Guest env injection (Path 1)
- Push into the agent's environment via the existing `proxy.env` / `config-agent`
  mechanism:
  - `ANTHROPIC_BASE_URL=http://127.0.0.1:11434`
  - `OPENAI_BASE_URL=http://127.0.0.1:11434/v1`
  - dummy `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` (engine ignores them)
- Then any explicitly-configured agent "just works" against local inference with no
  code change.

### 3.4 Model catalog + downloads
See §5.

### 3.5 Routing layer (Path 2 / MITM)
See §4.

---

## 4. Access paths & routing (the two-axis model)

### 4.1 Two paths, different jobs

|                   | **Path 1 — env var in VM**        | **Path 2 — MITM / interception**       |
|-------------------|-----------------------------------|----------------------------------------|
| Mechanism         | `ANTHROPIC_BASE_URL` → local      | agent targets `api.anthropic.com`; mitm re-routes |
| Agent awareness   | Explicit (knows it's local)       | Transparent                            |
| Routing           | **Static pin — always local**     | **Dynamic — cloud / local / hybrid**   |
| Works for         | Agents whose config you control   | *Any* tool in the VM hitting Anthropic |
| Hybrid possible?  | ❌ never sees the cloud           | ✅ **only place hybrid can live**      |

Both hit the **same** host engine. Two ways to get local: explicit (Path 1, no
interception) and transparent (Path 2 routing=Local). Pick by whether you control
the agent's config.

### 4.2 Two **independent** axes (Routing is top-level, NOT a Fusion mode)

Fusion and Routing are orthogonal: Fusion is an **identity** concern (whose creds
serve the cloud leg); Routing is a **backend-selection** concern. Nesting Hybrid
inside Fusion makes valid combinations inexpressible — e.g. *"agent uses its own
Anthropic key (Fusion off) but still falls back to local when Anthropic is slow."*

```
Substrate:  MITM interception  (engaged when Routing ≠ Cloud, or Fusion on)
Axis 1 — Routing (TOP-LEVEL):   Cloud | Local | Hybrid
Axis 2 — Fusion / identity:     host-cred swap on/off   (cloud leg only)
Separate mechanism — Path 1:    ANTHROPIC_BASE_URL pin  (explicit local, no mitm)
```

- Selecting **Local** or **Hybrid** routing **auto-engages** interception — the user
  does not flip a separate "mitm on" switch.
- Falling back to local is **identity-agnostic** → Hybrid composes with either Fusion
  state with no special-casing.
- Surface as a sibling of `vm fusion`: **`vm routing cloud|local|hybrid`**, reading
  the same per-profile config the mitm already consumes.

Example grid:
- `Hybrid + Fusion-on` → "use my host Claude sub, fall back to local on slowdown."
- `Hybrid + Fusion-off` → "agent's own key, fall back to local."
- `Local` → "always local, transparently."
- `Cloud` (today's behavior) → pass-through, optionally host-cred swapped.

### 4.3 Hybrid fallback — the three traps

**Trap 1 — you can't un-send a request. Fallback must fire *before the first token*.**
Once the mitm forwards one SSE event downstream, it's committed. Triggers:
- **Hard:** connection refused / timeout / `429` / `529` / `5xx` → route local
  immediately (covers real Anthropic outages).
- **Soft:** no first token within **5 s** (decided — cloud-tolerant default) →
  cancel upstream, replay same request local. Configurable.
- **Health-gating (conservative — decided):** maintain an EWMA of recent TTFT +
  error-rate per upstream. Flip to "unhealthy" only on a clear signal — **≥3 failures
  or TTFT EWMA > 8 s over the last ~10 requests** — and **recover after a few clean
  probes**. While unhealthy, send new requests straight to local *without* paying the
  per-request timeout penalty. Conservative thresholds match the cloud-tolerant 5 s
  soft default and avoid churning to local on transient jitter.
- **No speculative hedging** (decided) — fallback only fires *after* a hard or soft
  trigger; we never race both backends. Simpler, no double spend; worst case is the
  5 s soft-timeout latency before failover.

**Trap 2 — swapping models mid-conversation can wreck a coding trajectory.**
Different tool-call style / prompt adherence between turns derails multi-step agents.
Mitigation: **sticky at session granularity** — once a conversation switches to
local, keep it local for the rest of that session (detect session via
message-history hash / continuity header). Stickiness is the *coherence guard* that
sits under the policy knobs below: whenever a knob decides to switch, the switch is
applied at a session boundary, not mid-trajectory.

### 4.3.1 Hybrid is a small policy engine (not one switch)
Hybrid routing is controlled by a few independent, per-profile toggles rather than a
single stickiness mode:

- **Cloud token budget** — a cap on tokens served by the cloud leg over a **rolling
  wall-clock window** (decided — e.g. "max N cloud tokens per 24 h", resets
  continuously). Once exceeded, route to local until the window slides back under cap.
  Requires persisted usage counters; pairs with the trace marker (§4.4) for accounting.
- **Performance thresholds** — the trigger set above: hard errors
  (`429/529/5xx`/timeout) + the 5 s soft TTFT + health-gating EWMA. Tunable per
  profile.
- **Local↔cloud split** — an explicit ratio that proactively sends a configurable
  share of *new sessions* to local even when cloud is healthy (e.g. 30% local).
  Lets the user blend cost/latency/privacy instead of only falling back on failure.
  **Applied at session granularity** so it never swaps models within a trajectory.

Precedence (first match wins): hard error → over-budget → unhealthy (EWMA) →
soft-timeout → split-ratio assignment → otherwise cloud. All switches respect the
sticky-session guard.

**Trap 3 — protocol translation is the silent killer; `vllm-mlx` avoids it.**
The intercepted request is Anthropic `/v1/messages` with Anthropic tool blocks + SSE.
Because `vllm-mlx` speaks `/v1/messages` natively, hybrid is **near pass-through**
(rewrite host, drop real key) and tool-calling stays intact. An OpenAI-only engine
would force on-the-fly Anthropic↔OpenAI translation of messages/tools/streaming —
exactly where quantized tool-calling breaks. **Reason #1 to keep the engine
Anthropic-native for the MITM path.**

### 4.4 Observability
Inject a response marker (e.g. `x-bromure-served-by: local-glm-5.2` vs `cloud`) and
log it into the existing trace CLI, so the user can see *which model answered each
turn* under transparent routing.

---

## 5. Curated MLX model catalog

The catalog's real job for agentic coding is a **quality gate**, not just a menu:
the dominant failure mode is quantized models that silently break tool-calling.

### 5.1 Shipped-but-updatable manifest
- **Bundle a baseline `catalog.json`** (works offline day one) — same JSON-in-
  Application-Support pattern as profiles.
- **Fetch an updated `catalog.json` from a Bromure-hosted URL** at launch / on
  refresh; merge over baseline. Lets new MLX quants be added the *same day* they hit
  HF without an app release.
- **Baseline seed (decided): 3–4 tool-calling-verified models across RAM tiers** so
  every machine sees something usable offline on day one:
  - small — fits ~32 GB (e.g. a Qwen3.5-Coder-class small model)
  - mid — ~64 GB
  - large — GLM-5.2 (~128 GB)
  Remote refresh layers newer/larger options on top.

### 5.2 Entry schema (draft)
```json
{
  "id": "glm-5.2-mlx-3bit",
  "repo": "mlx-community/GLM-5.2-mxfp4",
  "engine": "vllm-mlx",
  "name": "GLM-5.2 (3-bit MLX)",
  "publisher": "Z.ai", "license": "MIT",
  "params_total_b": 744, "params_active_b": 40,
  "quant": "mxfp4",
  "download_gb": 95,
  "min_unified_mem_gb": 128,
  "context": 1000000,
  "tags": ["coding", "tools", "reasoning"],
  "tool_calling": "verified",
  "min_chip": "M3 Max",
  "recommended": true
}
```

### 5.3 RAM-fit gating
Detect host unified memory once; label each entry **Fits / Tight / Won't fit**
against `min_unified_mem_gb`. Picker defaults to "Fits," with a toggle to reveal the
rest. Prevents a 32 GB MacBook user from pulling 95 GB of GLM-5.2 and OOMing.

### 5.4 Curation criteria (what earns a slot)
1. **MLX format** (not GGUF) — validated.
2. **Tool-calling verified** — actually smoke-tested against that quant
   (`verified` / `untested` / `broken`). Headline filter for agentic use.
3. **Trusted quant publisher** (`mlx-community`, model author's own MLX repo).
4. **Coding-relevant** tags so the picker can default to coding models.

### 5.5 Escape hatch (power users)
Keep "paste any HF repo," but **validate before download**: query the HF API,
confirm MLX safetensors + config (reject GGUF with a clear "that's an ollama model"
message), then pull with progress. Custom pulls get `tool_calling: "untested"` and
no RAM-fit guarantee.

### 5.6 No conversion, ever
`vllm-mlx` loads **any HF repo already in MLX format** — `mlx-community` is just the
canonical/biggest source, not a lock-in. Give `org/repo`, it downloads to
`~/.cache/huggingface/...` on first run and serves it. Users never touch
`mlx_lm.convert` or distribute anything. (Must be an **MLX** repo, not GGUF —
`unsloth/GLM-5.2-GGUF` will *not* load here; that's the Ollama path.)

---

## 6. CLI / UI surface (docker-style, matches existing CLI)

```
bromure-ac model catalog                 # curated list + Fits/Won't-fit badges
bromure-ac model pull glm-5.2-mlx-3bit   # by catalog id …
bromure-ac model pull mlx-community/…    # … or any MLX repo (validated)
bromure-ac model ls                      # installed + disk used
bromure-ac model use <id>                # set active engine model
bromure-ac model rm <id>

bromure-ac vm routing cloud|local|hybrid # top-level routing, sibling of `vm fusion`
bromure-ac vm fusion on|off              # existing identity axis

# hybrid policy knobs (per profile; only meaningful when routing=hybrid)
bromure-ac vm hybrid budget <tokens>     # cloud token cap per window (0 = unlimited)
bromure-ac vm hybrid ttft <seconds>      # soft fallback threshold (default 5)
bromure-ac vm hybrid split <0..100>      # % of new sessions pinned local
```
Settings UI mirrors `model catalog` as cards with RAM badges + tool-calling check.

---

## 7. GLM-5.2 specifics

- ~744B-param MoE (~40B active), 1M context, MIT license, coding-focused.
- **MLX:** `mlx-community/GLM-5.2-mxfp4`, `pipenetwork/GLM-5.2-MLX-mixed-3_6bit`.
- **Hardware reality (good news):** a **3-bit MLX build ran ~26 tok/s at ~100 GB
  peak on an M3 Max 128 GB**. So full GLM-5.2 is reachable on a **128 GB Mac** via
  aggressive quant — not the 512 GB the raw param count implies. Still out of reach
  on 16–32 GB; for those, seed the catalog with smaller coding models
  (Qwen3.5-Coder-class) across RAM tiers.

---

## 8. Decisions

Resolved:
1. **Engine packaging — vendor a pinned arm64 Python 3.12 venv in the app bundle.**
   Reproducible/offline; requires codesigning the embedded interpreter + dylibs in
   `build.sh` and a hermetic pinned wheel set (§3.1).
2. **Hybrid control = toggle-based policy engine**, not a single stickiness mode:
   **cloud token budget**, **performance thresholds**, **local↔cloud split** (§4.3.1).
   Sticky-per-session is the coherence guard under all three; switches happen at
   session boundaries only.
3. **No speculative hedging** — fallback only after a hard/soft trigger; never race
   both backends (no double spend).
4. **Soft-timeout = 5 s** (cloud-tolerant) + hard triggers (`429/529/5xx`/timeout) +
   health-gating EWMA. All per-profile tunable.

5. **Single shared engine instance** for all VMs — model loaded once; no per-VM
   isolation (§3.1).
6. **Catalog: 3–4 tool-calling-verified models across RAM tiers** bundled as baseline
   (small ~32 GB / mid ~64 GB / GLM-5.2 ~128 GB) **+ remote `catalog.json` refresh**
   from a Bromure-hosted URL (§5.1).
7. **Cloud token budget = rolling wall-clock window** (e.g. per-24 h), persisted
   counters (§4.3.1).
8. **Health-gate = conservative** — flip unhealthy on ≥3 failures or TTFT EWMA > 8 s
   over last ~10 requests; recover after a few clean probes (§4.3).

Still open (content/tuning, not blocking):
9. **Catalog refresh URL host** + the exact baseline model picks (editorial).
10. **Exact budget default** (N tokens / window length) and EWMA decay factor —
    ship sensible defaults, tune empirically once running.

---

## 9. Suggested build order

1. `InferenceService` supervisor + `vllm-mlx` launch, bound to loopback.
2. vsock listener (8446) in `MitmEngine` + `bromure-vm-bridge.py` forward.
3. Guest env injection (Path 1) → prove a configured agent reaches local engine.
4. `catalog.json` schema + loader (bundled baseline) + RAM-fit detector.
5. `model` CLI verbs (`catalog`, `pull`, `use`, `ls`, `rm`) + HF download w/ progress.
6. Routing layer in MITM: `Cloud | Local | Hybrid`, top-level, + `vm routing` CLI.
7. Hybrid policy engine: precedence chain (hard error → over-budget → unhealthy →
   5 s soft TTFT → split-ratio → cloud), sticky-per-session guard, + `vm hybrid` knobs.
8. Observability marker into the trace CLI.
9. Remote catalog refresh + tool-calling verification harness.

---

## 10. Key existing files to touch

| Purpose | Path |
|---|---|
| NAT/network setup (gateway IP fallback option) | `Sources/SandboxEngine/VMNetSwitch.swift` |
| vsock listener registration (add 8446) | `Sources/AgentCoding/Mitm/MitmEngine.swift` |
| Guest TCP↔vsock bridge (add LLM forward) | `Sources/AgentCoding/Resources/vm-setup/bromure-vm-bridge.py` |
| MITM request routing (Cloud/Local/Hybrid) | `Sources/AgentCoding/Mitm/HTTPProxy.swift` |
| CLI subcommands (`model`, `vm routing`) | `Sources/AgentCoding/CLICommands.swift` |
| HTTP automation server | `Sources/AgentCoding/AutomationServer.swift` |
| Guest env / proxy.env injection | `Sources/SandboxEngine/Resources/vm-setup/scripts/config-agent.py` |
| New: `InferenceService`, catalog loader | `Sources/AgentCoding/...` (new) |

---

## Sources

- MLX vs llama.cpp benchmarks — https://yage.ai/share/mlx-apple-silicon-en-20260331.html
- Ollama MLX engine (preview) — https://ollama.com/blog/mlx
- mlx-lm server — https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/SERVER.md
- mlx-community (pre-converted MLX weights) — https://huggingface.co/mlx-community
- vllm-metal (official MLX plugin) — https://github.com/vllm-project/vllm-metal
- vllm-mlx (OpenAI+Anthropic server) — https://github.com/waybarrios/vllm-mlx
- GLM-5.2 model card — https://huggingface.co/zai-org/GLM-5.2
- GLM-5.2 GGUF (Ollama path) — https://huggingface.co/unsloth/GLM-5.2-GGUF
- GLM-5.2 MLX — https://huggingface.co/mlx-community/GLM-5.2-mxfp4
- GLM-5.2 local hardware/quants — https://codersera.com/blog/how-to-run-glm-5-2-locally-2026/
