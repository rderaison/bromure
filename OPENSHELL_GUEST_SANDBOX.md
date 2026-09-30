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

## Module distribution

`sentry-dist/` holds one prebuilt `bromure_sentry-<kver>.ko` per supported image kernel, each
with a `.txt` recording the headers package version, compiler and sha256 (builds are
reproducible). The host stages the whole set; the guest picks a module by exact file name
(`$(uname -r)`), and a missing one is reported as `sentry: unavailable` with the reason.

**Every new base image must get its module built before it's published**, or the sentry is
unavailable on it. Inside a VM of the image being released (or any Ubuntu arm64 machine with
that kernel's headers), run `scripts/openshell-guest/sentry/build.sh`. It writes
`bromure_sentry-$(uname -r).ko` plus its `.txt` and a build log, and refuses to produce a test
build. Copy them into `Sources/AgentCoding/Resources/vm-setup/sentry-dist/` **alongside** the
existing modules, never replacing them, so rolling back to the previous image still finds its
module. An on-guest DKMS build is a last resort that usually fails (it runs apt through the
workspace's egress policy).

## Reconnect proof

The first hello (`conn: 0`) carries the secret; a reconnect carries `conn: n` and
`proof = sha256(secret-hex || boot_id || decimal n)`, never the secret. The host refuses a
replayed first hello, a reused or lower index, a wrong proof, and a reconnect with the secret
in the clear. The pin is kept (0600) in the workspace folder across host restarts for a
restored VM and deleted on a fresh boot.
