# OpenShell guest sandbox + kernel sentry

This covers how Bromure Agentic Coding enforces OpenShell's `filesystem_policy`, `landlock`
and `process` sections inside the workspace VM, and how the kernel sentry streams security
events to the host.

## Split

| Side | What it does | Where |
|---|---|---|
| Host (macOS) | Stages the spec, pins and watches the sentry, records timeline and OCSF events, feeds the watchdog, runs the UI, applies managed minimums | `SandboxEngine/OpenShellSandboxSpec.swift`, `AgentCoding/KernelSentryService.swift`, `GuestSandboxStatusStore` (in `BinaryIdentityService.swift`), `OpenShellPolicyEditor.swift` |
| Guest (Linux) | Landlock, privilege drop, seccomp (OpenShell parity, pure Python/ctypes, differentially tested against the real `landlock`/`seccompiler` crates), a kprobe-based kernel module that streams to vsock from kernel space, lockdown | `Resources/vm-setup/` (delivered by the Linux side) |
| bromure.io | `min_kernel_sentry` in the org-managed OpenShell policy | bromure-infra `ac-policy.js`, migration `1745003600000` |

## Semantics

- **Each section is honored only if present.** A policy without `filesystem_policy` leaves
  Landlock off, and one without `process` switches no user. This deliberately differs from
  OpenShell, whose built-in default (`include_workdir: true`, empty lists) only works because
  its drivers always ship an explicit document. A workspace without these sections behaves
  exactly as before.
- **A present `filesystem_policy` is applied verbatim with OpenShell semantics.** There is no
  system-path baseline. The guest adds only Bromure's plumbing paths (tmux socket, meta share,
  ptys, `/run/utmp`, …) and reports them in `sandbox_status.additions`, which the editor
  displays. The editor's template carries OpenShell's example paths.
- **A `process` section forces the strict sandbox** (`Profile.effectiveStrictSandbox`). Its
  seccomp filters and `no_new_privs` would disable the sudo a non-strict workspace grants, so
  without strict they'd have to be skipped, which fails open. The editor locks the toggle on.
- **Landlock ABI:** the Ubuntu noble 6.8 guest has ABI 4. OpenShell requires ABI 3, so there
  is no degradation path on current images.

### The three configurations

| Configuration | Applied in the guest | What it guarantees |
|---|---|---|
| Sentry only (no sections, no strict) | nothing: panes and `vm exec` have no `no_new_privs`, no seccomp, and sudo works | observation only |
| `filesystem_policy`, no strict | Landlock, applied while still root (no `no_new_privs`); sudo works | filesystem confinement **even against root**, ptrace isolation, no mount; **no** userland tamper resistance (a sudo-capable agent can kill Bromure's helpers or load a signed module) |
| Strict (or any `process` section) | Landlock + OpenShell seccomp + `no_new_privs` + privilege drop; sudo, docker group and the console revoked | all of the above, plus no path to root, and no signals to agentd or the supervisor (`kill`, `tgkill`, `tkill`) |

**`run_as_user`** (e.g. OpenShell's `sandbox`): the workload is not uid 1000 and holds none of
ubuntu's groups, sudo or docker. It sees `/home/ubuntu` as its own through an idmapped mount
(files it creates are ubuntu's on disk) and keeps `HOME=/home/ubuntu`, so Bromure's seeded
agent config applies. Shared folders (virtiofs) can't be idmapped on 6.8, but virtiofs doesn't
enforce the guest's permission bits, so they stay readable and writable, and files land on the
Mac owned by the Mac user. It is **not** a secrecy boundary for ubuntu's files: the VM has a
single tenant, and Landlock plus the network policy are the boundary, as in OpenShell.

Every `sandbox_status` carries `build` (short hashes of the guest scripts actually running),
which the host logs. When a guest command can't be run inside the sandbox, the caller gets exit
126 and a `bromure sandbox: <reason>` line on stderr, never a bare 127.

Everything agentd runs against workspace content (shells for `vm exec`/attach, git, npm, the
plan driver) goes through the supervisor's `exec` op and is confined exactly like the session
(`confine_self`). Anything that can't be routed raises instead of running unconfined. The
exemptions are named: `_run_unconfined(reason=…)` (docker operations) and `_sys_capture(args,
reason)` for housekeeping whose behaviour workspace content can't influence (`df`, `ss`,
`ps`, `findmnt`, `lsblk`, `ip route`, `hostname`, the docker status polls). `git` and `tmux`
stay confined: a repository can redirect git through `core.fsmonitor`, `core.hooksPath` and
`diff.external`. Housekeeping must stay out of the sandbox, or its refusals flood the
timeline (round 19 measured ~30 false denials a minute) and trip the probing alarm.

## Wire contracts

- **Spec:** `/mnt/bromure-meta/openshell-sandbox.json`, staged before boot when any section is
  present or the sentry is on. Keys: `version`, the three sections verbatim (`null` when
  absent), `workdirs` (`/home/ubuntu/<share>`), `strict_sandbox`,
  `sentry {enabled, vsock_port: 5841, requirement}`.
- **Status:** an unsolicited JSON line on the attestor channel (vsock 5840):
  `{"event":"sandbox_status","filesystem":"enforced|degraded|failed|off","degraded_reason",
  "landlock_abi","seccomp","run_as":{uid,gid,user},"additions":{read_write,read_only},
  "sentry":"running|unavailable|off","sentry_digest":"<sha256(secret) hex>"}`.
- **Sentry:** vsock 5841. Each frame is a u32 big-endian length followed by JSON.
  - `hello`: `v: 1`, a 64-hex secret minted per module load, `boot_id`, `kernel`, `module`,
    `landlock_abi`. The host pins the first hello per VM start.
  - `heartbeat`: every second, with `seq`, `dropped` (ring full), `rate_limited` (token
    bucket) and `probes {armed, total, missed}`.
  - `event`: carries `seq` and `kind`; heartbeats and events share one counter.

## Host alarms

Events are judged by meaning, not by which syscall fired (a false alarm in the first minute is
how users learn to ignore the real ones). The watchdog trips at a score of 20 within 60
seconds.

| Condition | Watchdog weight |
|---|---|
| A second sentry, a wrong secret, a `seq` gap, 15 s of silence, disarmed probes (`armed < total` or a dead canary), a digest mismatch, or a connection while the guest reports the sentry unavailable | 20 (tampering, trips on its own) |
| `cred_gain` (uid 0 or permitted capabilities the task couldn't already assume) **under strict, from inside the sandbox**. Capabilities gained inside a new user namespace (`unshare -U`, rootless podman, bwrap) are not a gain; the sentry counts them as `caps_in_userns` in the heartbeat | 20 |
| `cred_gain` without strict (sudo is allowed there), or under strict from Bromure's own unconfined helpers | 0, shown on the timeline |
| `module_load` not signed (or refused, e.g. `-EKEYREJECTED` under lockdown); `bpf_load` (except from systemd, pid 1), `kexec_attempt` | 10 |
| `lockdown_change_attempt` that tries to lower the level or is refused | 10 |
| Garbage on the port | 10 |
| `ptrace` | 3 |
| `mount`, `unshare`, `setns` (except from systemd, pid 1) | 2 |
| `sandbox_denied`: an LSM refused a file operation for a task in the sandbox cgroup (`op` = `open_read`/`open_write`/`open_exec`/`create`/`mkdir`/`rmdir`/`unlink`/`symlink`/`link`/`rename`/`truncate`; the kernel doesn't say which LSM) | 1 |
| `seccomp_denied`: the process layer blocked a syscall (`syscall` is the arm64 number) | 3 |
| One program refused 20+ times in 60 s (`sandbox_probing`; counts `count`, not rows) | 10 |
| Dropped or rate-limited events, missed probe hits | 2 |
| 5 s of silence; the guest reports the sentry unavailable (with its reason); `phase: boot` past the boot budget | 0 (warning) |

- **Counted only** (tallied, never a row): `exec`, `connect`, raw `setuid`/`setgid`/`capset`
  calls, signed module loads, systemd's (pid 1) unit BPF and mounts, and anything labelled
  `phase: "boot"` (Bromure's own helpers assembling the VM) or `phase: "shutdown"` (poweroff).
  Both labels have a host-side budget (90 s after VM start, 20 s after the first shutdown
  frame); past it, events are judged as session events and a warning is raised, so neither
  label can be used to hide activity. A `sandbox_status` of `pending` (the guest still
  assembling) is ignored: no row and no cross-check.
  A root agent in a non-strict workspace could route a BPF load or mount through a systemd
  unit to make it look like pid 1; at those weights that's accepted. The phase flips one way, boot → session, when the supervisor starts
  the session server; the host honours `boot` only within the 90 s boot budget.
- **Sandbox denials on the Security Timeline:** each is a "Guest sandbox · denied" row, `<program>
  (pid N) — <op> <path>` or `syscall <name>` (named from `SecurityTimeline.arm64Syscalls`, a
  copy of the guest's table). The guest folds repeats within one process for 1 s (`count`);
  the host folds identical denials from new processes (a shell loop) for 60 s: the first shows
  at once, the rest become one "×N more in the last minute, from N processes" row. Heartbeat
  tallies (`allowed_file_ops`, `denied_file_ops`, `denied_syscalls`) become a "since boot"
  activity row every 5 minutes, or 30 s after denials grow. A denial Linux's own permissions
  refuse first (e.g. under 0700 `/root`) never reaches the LSM and never shows.
- **Never alarms:** a paused, quarantined or suspended VM.
- **Sentry never connects** (after a 90 s boot budget): required and unexplained → tampering;
  the guest reporting `unavailable` (e.g. no module for its kernel) → a warning with the reason.

## Lockdown

The sentry raises kernel lockdown right after loading: `integrity` for best effort,
`confidentiality` for required. Measured on the shipped image (6.8.0-142): neither costs a
workload Bromure cares about (docker, published ports, iptables, k3s modules, signed modprobe,
virtiofs, vsock). `confidentiality` additionally closes `/proc/kcore` (which could leak the
hello secret) and root-registered tracefs kprobes, at the price of kernel tracing.

## Capture

The sentry uses kprobes only, not eBPF:
- `security_bprm_committed_creds` for exec;
- `__arm64_sys_*` for the credential, namespace, module and kexec syscalls;
- `security_socket_connect` for connect;
- a kretprobe on `security_file_open` for denied opens.

That leaves no bpffs pin, BPF link or perf fd to detach, and no kernel command-line change,
so no image bump. BPF-LSM (for true Landlock attribution) stays an optional future upgrade
that would need `lsm=…,bpf` and therefore an image bump.

## Container traffic exempt from the MiTM

Per-workspace option "Don't intercept container traffic" (`Profile.containerTrafficDirect`).
Containers are NAT'd behind the guest's own address, so after MASQUERADE the host switch can't
tell a container's packet from the guest's own (measured: same source address, both). The
label has to come from something root in the guest can't forge, so the **sentry module** sets
it:

- **DSCP 43** (`VMNetSwitch.containerDSCP`, local/experimental pool) on packets the guest
  forwards from a **veth or bridge port**, in one netfilter hook at POSTROUTING with the last
  priority (after NAT and after any iptables rule root can add). Packets originated in the
  guest (`skb_iif == 0`) or arriving via any other device (a TUN a root process could use to
  re-inject its own traffic) have DSCP 43 cleared. MASQUERADE preserves it (measured).
- The hello announces `container_mark: 43`; heartbeats count marked and forgery-cleared
  packets; a forgery attempt is a `container_mark_forged` event (tampering, weight 10).
- The **switch** reads and **always strips** the mark on egress (it never leaves the host), and
  skips the MiTM diversion for a marked packet only when the workspace's option is on **and**
  that VM's sentry is connected and announced the mark (`KernelSentryService.noteContainerMark`
  → `VMNetSwitch.setContainerTrafficDirect`). No sentry, no exemption: fail closed. The L4
  firewall still applies; the flow is logged with `layer: "container"`.
- **`tc` can defeat the hook** (measured: an egress `pedit` action rewrites DSCP inside
  `__dev_queue_xmit`, after netfilter; root only). So the sentry reports every `tc_change`
  (filter/qdisc/action), and one after the boot phase **revokes the exemption for the rest of
  that boot** (`KernelSentryService.revokeContainerMark`): container traffic goes back to the
  proxy and a tampering alarm (weight 10) says why. The next boot's first hello re-arms it.
- Not applied (`effectiveContainerTrafficDirect`) without the sentry, or when the OpenShell
  policy has request-level (L7) rules, which only the MiTM can enforce.
- agentd stops injecting proxy settings into containers when `$META/containers-direct`
  exists; dockerd's own proxy stays, so image pulls are still checked.
- Lost for container traffic: credential brokering, supply-chain checks on in-container
  installs, prompt-injection/PII scanning, per-request logs. Lineage still sees the flows.

## Module distribution

Modules are **not** in the app or in git. `Jenkinsfile.sentry` builds one per Ubuntu kernel
and publishes it to the CDN; the app downloads the ones its workspaces need.

- **Identity.** A module is published per module *source*: `sourceHash` = sha256 over
  `Makefile`, `bromure_sentry.c`, `bromure_sentry.h` (sorted, each `name\n<len>\n<bytes>`),
  computed by `scripts/openshell-guest/sentry/source-hash.sh` and
  `SentryModuleStore.sourceHash(of:)`. The app only loads modules built from the source it
  ships (`vm-setup/sentry-dist/src`).
- **CDN layout** (bucket `bromure-dl`, `https://dl.bromure.io`):
  `sentry/<sourceHash>/catalog.json` (60 s TTL) and immutable
  `sentry/<sourceHash>/<kernel>/bromure_sentry-<kernel>-<sha12>.ko` (+ `.txt` build record).
  Publishing is additive; nothing is deleted.
- **Catalog trust.** Signed with the Sparkle ed25519 key (the one behind `SUPublicEDKey`),
  domain-separated by the payload's first line `bromure-sentry-modules-v1`; the signature
  covers every module's kernel, path, sha256 and size (`tools/make-sentry-catalog.mjs` and
  `SentryModuleCatalog.signingPayload` build identical bytes). The app refuses unsigned or
  foreign-key catalogs, older ones than it has cached, paths outside the source's prefix, and
  any module whose bytes don't match; cached modules are re-hashed before every staging.
  **Each module is also signed on its own** (same Sparkle key) over a domain-separated
  statement: `bromure-sentry-module-v1`, sourceHash, kernel, sha256, size. Never over the raw
  `.ko` bytes: Sparkle signs raw update archives, so a raw-bytes signature would let a module
  pass for a signed update. The signature sits in the catalog entry and in a detached
  `<module>.ko.sig` beside it on the CDN; the app refuses a module without a valid one even
  under a valid catalog, and a merge refuses to keep an entry it can't re-verify.
  (Kernel-native module signing isn't used: the guest kernel only trusts Canonical's keys and
  MOK enrolments, and the sentry loads before lockdown, so it isn't needed.)
  `BROMURE_SENTRY_CATALOG_BASE` points it at a test server (unsigned accepted there, like
  `BROMURE_IMAGE_CATALOG_BASE`).
- **CI** (`Jenkinsfile.sentry`, daily, kube-builder-a): for this checkout's source and the last
  `RELEASES` `agentic-coding-v*` tags' sources, a `ubuntu:24.04` arm64 container
  (`scripts/openshell-guest/sentry/Dockerfile` + `ci-build.sh`) lists the archive's
  `linux-headers-6.8.0-*-generic`, skips kernels already in that source's catalog, and builds
  the rest with `build.sh --verify` (two builds must be byte-identical; the container
  reproduced the hand-built 6.8.0-142 module exactly). A node container
  (`scripts/publish-sentry-modules.sh`) signs the merged catalog, uploads modules then the
  catalog, and verifies both from the CDN. Failed kernels mark the run UNSTABLE.
- **App.** The guest reports `sentry_kernel` and `installed_kernels` (kernels with a
  `modules.dep`) in `sandbox_status`; the host remembers them per workspace
  (`sentry-modules/kernels.json`), prefetches them at launch, and stages the cached module of
  every known kernel into `$META/sentry/` before boot. A kernel it hasn't seen (first boot, or
  an `apt upgrade`) is fetched while the guest waits (sentry `waiting`; inline for `hard`,
  in the background otherwise) and dropped into the running meta share atomically. When none
  is coming (not built yet, offline), the host writes
  `bromure_sentry-<kernel>.unavailable` with its reason; otherwise the guest gives up after
  45 s. Either way the sentry ends `unavailable` with that reason: a warning, never tampering.
- **Measured** (hard requirement, 6.8.0-142): known kernel, shell in 4 s; unknown kernel
  fetched on demand, 6 s; no module published, clean `unavailable` naming the host's reason,
  4 s. A host that never answers (offline, older app) costs the full 45 s in hard mode.

A local build inside the guest remains the last resort and usually fails (it runs apt
through the workspace's egress policy).

## Reconnect proof

The first hello (`conn: 0`) carries the secret; a reconnect carries `conn: n` and
`proof = sha256(secret-hex || boot_id || decimal n)`, never the secret. The host refuses a
replayed first hello, a reused or lower index, a wrong proof, and a reconnect with the secret
in the clear. The pin is kept (0600) in the workspace folder across host restarts for a
restored VM and deleted on a fresh boot.
