# OpenShell `filesystem_policy` / `landlock` / `process` + kernel sentry — guest side

This is the design note the contract asks for: what was built, why it is shaped
the way it is, every place it departs from OpenShell or from the contract, and
what was actually measured rather than assumed.

Everything here was built and tested in an Ubuntu 24.04.5 arm64 workspace VM,
kernel `6.8.0-139-generic`.

---

## 0. The guest, measured

| | |
|---|---|
| kernel | `6.8.0-139-generic` (aarch64, PREEMPT_DYNAMIC) |
| Landlock | enabled, **ABI 4** |
| active LSMs | `lockdown,capability,landlock,yama,apparmor` — **no `bpf`** |
| lockdown | `[none] integrity confidentiality`, writable at runtime |
| BTF | `/sys/kernel/btf/vmlinux` present |
| module signing | `CONFIG_MODULE_SIG=y`, `sig_enforce=N`, `MODULE_SIG_FORCE` unset |
| module unload | `CONFIG_MODULE_UNLOAD=y`, **`CONFIG_MODULE_FORCE_UNLOAD` unset** |
| kprobes | `CONFIG_KPROBES=y` |
| kernel headers | not in the image; `linux-headers-6.8.0-139-generic` installs from noble-updates |
| vsock | `vmw_vsock_virtio_transport` loaded, `/dev/vsock` present |

Two of these decided the architecture. **ABI 4 ≥ the ABI 3 OpenShell pins**, so
on this kernel there is no degradation path at all: `AccessFs::from_all(ABI::V3)`
is fully supported and `CompatLevel` never has to downgrade anything. And **`bpf`
is not in the LSM list**, which is why the sentry is kprobes (§4).

---

## 1. Enforcement

### 1.1 What was built

`bromure_openshell.py` reimplements the enforcement half of OpenShell's
`sandbox-linux` crate in pure Python/ctypes: Landlock (`landlock.rs`), the three
seccomp filters (`seccomp.rs` + `child_seccomp.rs`), and `drop_privileges`
(`process.rs`). It has no build step and no dependency beyond CPython, because
it has to run inside the workspace VM from agentd's world, where there is no
toolchain and no cargo at boot.

### 1.2 Why you should believe it matches

Not by inspection. `differential/` builds a Rust harness against the **real
`landlock` 0.4.7 and `seccompiler` 0.4.0 crates**, running OpenShell's
`prepare`/`enforce`/`build_filter_rules` ported from the reference tree with
only the OCSF emission and miette wrappers removed. `diff.py` feeds byte-identical
jobs to both sides — same policy, same workdirs, same probe list, each in its own
fixture tree — and compares outcomes probe by probe.

**1845 probe comparisons across 30 cases, 0 differences.**

15 policy shapes × best_effort/hard_requirement × with and without seccomp:
ro+rw, ro-only, rw-only, `include_workdir` on/off/already-present, no-paths,
one-missing-path, all-missing-paths, device nodes, empty compatibility string,
read_only nested in a read_write parent, read_write nested in a read_only parent.
Probes cover every Landlock ABI-3 right on both a directory and a file, plus 40
syscall probes — all eight socket domains including the NETLINK_ROUTE-vs-other
split, every unconditional block, every conditional block with the flag both set
and clear, and ENOSYS-vs-EPERM on `clone3`/`pidfd_open`.

Run it with `cd differential && cargo build --release && ./diff.py`.

### 1.3 Who applies the sandbox, and to what

**The tmux server, applied by a persistent root supervisor.**

```
bromure-sandboxd (root, Restart=always)        <- the supervisor
  ├── owns /run/bromure-sandbox/ctl.sock       (SO_PEERCRED-checked)
  └── fork per server start
        ├── open Landlock path fds AS ROOT     (OpenShell phase 1)
        ├── setsid()
        ├── idmapped mounts, if run_as uid ≠ the workspace uid
        ├── drop_privileges(extra_groups=bromure-tmux)
        ├── no_new_privs → restrict_self → child filter → compat → main filter
        └── exec tmux -S … new-session -d      (server inherits all of it)

agentd (uid ubuntu, systemd, NOT sandboxed)
  ├── connects to the server's socket          (can connect, cannot create)
  └── asks ctl.sock when a server is needed
```

Every agent and every user shell is a descendant of that server, so everything
the agent can reach is inside the ruleset. agentd stays outside, which is what
lets it keep the vsock channels and the host bridges.

**Why a persistent supervisor and not a one-shot launcher.** The first version
was one-shot, and it was wrong twice over:

1. **It could never run under the strict sandbox.** `task_strict_sandbox`
   writes `ubuntu ALL=(ALL) !ALL` and exits; the restarted agentd then called
   `sudo -n … bromure-sandboxd`, which fails. Every strict workspace with an
   OpenShell policy would have got no session at all — and strict is exactly
   the configuration the process layer requires (§1.8), so this hit the case
   that matters most. Now every root helper — attestd, sentryd, sandboxd — is
   started by the root script *before* the revocation, and nothing needs sudo
   afterwards. `tests/test_sandbox.sh` §8 runs the whole post-revocation path
   with `sudo` stubbed to fail.
2. **It left a way to create an unsandboxed server.** See §1.4.

**Why not per-pane.** A per-pane sandbox would have to be applied by the tmux
server, which would then be *outside* it — and the server is reachable from
every pane through its own control socket. The server is the narrowest boundary
with nothing trusted inside it.

**Why not agentd itself.** agentd cannot setuid, so it could not honor
`run_as_user`; it cannot open path fds for a mode-700 directory; and a sandbox
covering agentd would cover the vsock channels, which must stay outside.

**Why `setsid()`.** By default the sandboxed tree shares agentd's uid, so
OpenShell's child self-protection filter is what stops the workload attacking
its supervisor. That filter's blanket denial of `kill(0, …)` and
`kill(<negative>, …)` would break job control in every interactive pane, so it
is narrowed (§1.9). `setsid()` is what makes the narrowing sound: the sandbox
gets its own session, so the only process groups it can name are its own.

### 1.4 The socket, and why nothing outside the sandbox can create a server

The escape this closes: the agent runs `tmux kill-server` — it is its own
server, nothing stops it — while leaving a detached process alive. The next time
anything **outside** the sandbox runs a tmux command against that socket, the
tmux client starts a server itself. Many commands carry `CMD_STARTSERVER`, not
just `new-session`, so this is not one call site to fix. That server is
unsandboxed, and the survivor can `send-keys` into its panes. Landlock at ABI 4
does not scope unix-socket connects — scoping arrived in ABI 6 — so nothing
blocks the last step.

Two answers that do **not** work, both rejected on evidence rather than taste:

- **Permissions on the socket directory.** In the default configuration agentd
  and the workload share uid 1000, because that is what keeps the virtiofs
  workdirs writable (§1.12). Any mode that lets the server bind also lets agentd
  bind; any mode that stops agentd stops the server.
- **A private mount namespace** holding a tmpfs for the socket, exposed to
  agentd by bind-mounting it out of `/proc/<pid>/root`. The kernel refuses:
  `do_loopback` calls `check_mnt`, which requires the source mount to be in the
  caller's own namespace. Measured, not assumed.

What works is a **supplementary group**. The uids stay equal; the group lists do
not.

```
/run/bromure-sandbox/            root:root          0755
    nothing but root creates entries here; ctl.sock lives here
/run/bromure-sandbox/server/     root:bromure-tmux  0771
    group rwx -> the sandboxed server creates its socket
    other  --x -> agentd traverses to the socket, creates nothing
/run/bromure-sandbox/server/tmux.sock
    created by the server, 0600, owned by the workload uid, so agentd
    (same uid) can connect
```

`bromure-tmux` is a system group with **no members in `/etc/group`**. The only
way to hold it is for the supervisor, as root, to grant it to the child it is
about to confine — `drop_privileges(extra_groups=…)`, the one additive change to
OpenShell's privilege drop. The supervisor refuses to run if the layout is not
exactly this, including if anyone has added a member to the group.

Measured, all four in `tests/test_sandbox.sh` §9:

- agentd connects to the server fine;
- agentd starting a server there fails with `error creating … (Permission denied)`;
- after `kill-server`, agentd cannot even resurrect one — it cannot unlink the
  stale socket, so it gets `EADDRINUSE`;
- a sandboxed process *can* create another server in `server/`, but that server
  is inside the sandbox too, so it buys nothing.

`TMUX_TMPDIR` is deliberately **not** set. tmux exports `$TMUX` into every pane
and a bare `tmux` inside a session reads the socket path from there, so panes
find the server without a tmpdir — and without a tmpdir there is no second,
guessable socket location for anything to bind.

**Who may start a server.** Only the supervisor, and agentd asks it over
`ctl.sock`. The peer is checked with `SO_PEERCRED`, so the kernel supplies the
credentials rather than the peer asserting them: the uid must be the workspace
user's **and** the pid must be agentd or one of its descendants. Uid alone would
not do — every sandboxed process has the same uid. Starts are rate-limited (5 per
60s), and `server_restarts` in the status counts supervisor-performed starts
after the first, so the host can treat a burst as a watchdog signal.

**The supervisor never restarts the server on its own.** A server exit is
either `kill-server` or the user closing their last window, and they are
indistinguishable. Auto-restarting would change the poweroff behavior users rely
on, so `session_monitor_service` still decides. An agent that kills its own
server just ends its workspace — a self-DoS, and an acceptable one.

> The first end-to-end run looked like this had failed: `tmux kill-server` from
> inside the sandbox was followed by agentd restarting and a **new** sandboxed
> server appearing. The supervisor had not restarted anything — the *restarted
> agentd* asked for a session at startup, which is exactly what it should do at
> boot. What was actually broken sat underneath: `session_monitor_service`
> powers the VM off with `sudo poweroff`, and the strict sandbox has revoked
> sudo, so that call fails silently and the VM stays up. A restarted agentd then
> resurrects a workspace the user had finished with.
>
> Fixed with a `poweroff` op on `ctl.sock`. This is not new authority — agentd
> did exactly this with sudo before the strict sandbox existed — and it is
> subject to the same peer check as everything else, so the sandbox cannot reach
> it. `session_monitor_service` tries sudo first and falls back to asking.


### 1.5 agentd is a deputy, and deputies execute workspace content

The sandbox confines the agent. It does not, on its own, stop **agentd** — uid
1000, unconfined, outside the ruleset — from running things the agent controls
through files. That is a family of holes, not a bug, and enumerating the members
is not a fix:

- **`_run_interactive` execs `bash -lc` / `bash -li`.** A login or interactive
  bash sources `~/.bash_profile`, `~/.profile` and `~/.bashrc`. Whenever the
  policy makes the home writable — and OpenShell's own example policy does
  exactly that, `/sandbox` read-write being our `/home/ubuntu` — the agent
  appends a line and the next **host attach runs it outside the sandbox**. Those
  files also set `PATH`, so `~/.local/bin/tmux` shadows `tmux`.
- **agentd runs `git -C <workdir>` about twenty times** — `status --porcelain`,
  `worktree add`, `rev-parse`, `branch -D`. A repository the agent controls can
  set `core.fsmonitor`, `core.hooksPath`, `core.sshCommand`, `diff.external`,
  smudge/clean filters and credential helpers. Every one is an exec vector, and
  `worktree add` runs post-checkout hooks.
- **The host's non-interactive `vm exec`** runs an arbitrary command in a
  workdir; **`npm install`** in the agent-writable plan-driver home runs package
  scripts and reads `.npmrc`; **the plan driver** runs in a workdir.

The fix is structural: **when a sandbox is applied, anything agentd runs that
touches workspace content runs inside the sandbox**, through a supervisor `exec`
op.

```
agentd  --{"op":"exec","argv":…,"cwd":…}--> ctl.sock
        --SCM_RIGHTS: stdin/stdout/stderr, or a pty slave-->
                          supervisor
                            └── fork → confine_self() → execvpe
```

`confine_self` is the **same function** that confines the tmux server, so a
command run on agentd's behalf can never be confined differently from the
session — the two cannot drift. Descriptors cross by `SCM_RIGHTS`: agentd keeps
its own ends (pipes for a captured command, the pty master for an interactive
one), so the bridging code is unchanged and `_run_interactive` still owns its
pty exactly as `pty.fork` left it.

The child's environment is **built**, not passed through: `LD_*`, `BASH_ENV`,
`ENV`, `SHELLOPTS`, `PYTHONSTARTUP`, `GIT_CONFIG` and friends are dropped, and
`PATH` is a fixed system one. A caller that forgets to scrub is a caller that
silently reopens the hole.

On top of that, and **not instead of it**, every `git` agentd runs — sandbox or
no sandbox — gets `GIT_CONFIG_NOSYSTEM=1`, `GIT_TERMINAL_PROMPT=0`,
`GIT_ASKPASS=/bin/false` and `-c core.fsmonitor= -c core.hooksPath=/dev/null -c
protocol.file.allow=never -c core.sshCommand=/bin/false -c diff.external= -c
credential.helper=`.

`tests/test_sandbox.sh` §12 plants a `~/.bashrc` line, a `core.fsmonitor` and a
`post-checkout` hook **from inside the sandbox**, all aimed at a marker file the
policy denies — so only a process outside Landlock could create it. It then
drives agentd's git and shell paths and asserts the marker never appears. It
also runs the identical payload **unconfined** and asserts that it *does* fire,
because a test that would pass against a broken implementation proves nothing.

#### One hazard this introduced, and how it is closed

The supervisor is now multi-threaded — a thread per control connection, because
an `exec` blocks for the lifetime of the command and an interactive shell lasts
as long as the session. Forking from a multi-threaded process is a deadlock
hazard: the confinement path calls NSS (`pwd.getpwnam`, `os.initgroups`) in the
child, glibc's NSS takes locks, and a child forked while another thread held one
inherits it held by a thread that no longer exists. It would hang before
`execve`.

Closed three ways: every fork that leads to `confine_self` is serialized through
one lock, so no other thread can be inside that code when the snapshot is taken;
NSS is warmed in the parent before any thread exists; and
`harden_child_process`'s `import resource` moved to module scope, because an
import in such a child can deadlock on the import lock too.

### 1.6 Default with none of the sections present

Exactly today's behavior. Each section is keyed off **its own presence**, not
the file's:

| section absent | effect |
|---|---|
| `filesystem_policy` | no Landlock at all |
| `landlock` | only meaningful when `filesystem_policy` is present |
| `process` | no uid switch, no seccomp, no `no_new_privs` |

This is a **deliberate divergence from OpenShell**, agreed with the host side.
OpenShell's `FilesystemPolicy::default()` is `include_workdir: true` with empty
lists, so an absent section there means "Landlock on, allow only the workdir" —
no `/usr`, no libc, nothing can exec. OpenShell survives this only because its
drivers always ship an explicit policy document. Bromure ships none, and "no
behavior change for workspaces without the section" wins.

`tests/test_sandbox.sh` §2 pins it.

### 1.7 The strict sandbox's revocation is RUNTIME-ONLY

The strict sandbox takes `sudo`, the `docker` group and the console away from
the workspace user before any agent code runs. The original implementation did
that by editing the disk — `rm /etc/sudoers.d/90-ubuntu`, write a denial,
`gpasswd -d ubuntu docker sudo lxd adm`.

**A workspace's root disk is persistent ext4; `/run` is tmpfs.** So the
revocation survived a reboot and its completion marker did not, and the second
boot of any strict workspace went:

1. no `/run/bromure-strict.done`, so agentd runs the root script;
2. the root script needs `sudo` — which the *first* boot already took away — so
   nothing in it ran: no attestor, no sentry, no supervisor, no marker;
3. `os._exit(75)`, systemd restarts, and it repeats forever.

The host saw neither vsock 5800 nor 5840, and the VM was indistinguishable from
a dead one. And turning the strict sandbox *off* never gave the user back sudo
or docker, because nothing undid the edits.

`bromure-strict.py` replaces it, and writes **nothing to disk**:

| what | how |
|---|---|
| `sudo` | a copy of `/etc/sudoers.d` in `/run`, minus the NOPASSWD drop-in and plus a `!ALL` denial, bind-mounted over `/etc/sudoers.d` |
| groups | `/etc/group` and `/etc/gshadow` rewritten in `/run` with the user dropped from `docker`, `sudo`, `lxd`, `adm`, `wheel`, bind-mounted over the originals |
| console | `systemctl mask --runtime`, which was already runtime |

Bind mounts are discarded by the kernel at reboot, so every boot starts from the
stock image state and strict is applied — or not — from scratch. There is no
undo to get wrong and no migration to write.

The group rewrite is deliberately conservative: comments, blank lines and any
line it does not understand pass through byte for byte, and it refuses to
install a result that changed the line count or lost `root`. This file is how
the machine resolves every user it has, and a clever rewrite that drops one it
did not parse is a machine that cannot log in.

#### The attestor must be impossible to kill

Without the attestor the host fails closed on every binary-scoped network rule:
`curl` simply does not work, for the whole boot, and nothing in the guest says
why. So "attestd never exits" is a correctness property, not tidiness — and it
was not one. Reported as intermittent, on a strict workspace with no spec.

**I could not reproduce it.** Twenty consecutive real boots of that exact
configuration, and the attestor connected and sent a `sandbox_status` on all
twenty. What follows is therefore hardening of every path that could produce the
reported symptom, not a fix for a failure I have seen.

The first thing to fix was that the question could not be asked. attestd
hardcoded `HOST_CID = 2`, which nothing inside a guest can bind, so **every boot
test ever run had no attestor and could not tell** — sixteen rounds of a boot
harness that never exercised the one channel the host depends on. It now takes
`BROMURE_HOST_CID` like agentd, the root script passes the override through
(its `systemd-run` line was missing `%(setenv)s` that agentd's sandboxd line
had), and `tests/test_boot.sh` listens on 5840 and asserts a connection and a
status on every case, with `REPEAT=N` for the intermittent kind.

Three real defects came out of looking:

1. **`load_secret()` was outside the retry loop.** Any `OSError` from it — a full
   `/run`, a stale file — killed the process before the loop began.
2. **The loop caught only `OSError`**, so any other exception type escaped a
   daemon whose entire job is to stay reachable.
3. **The unit had no `reset-failed` and no `StartLimitIntervalSec=0`**, which
   `bromure-sandboxd` was given rounds ago for exactly this reason. With
   `Restart=always` and systemd's default limit, **five exits in ten seconds
   leave the unit failed and no longer restarted** — which is precisely
   "sometimes never connects for the whole boot", and precisely why it would be
   intermittent. sandboxd got that treatment; attestd, the more important of the
   two, did not.

And a fourth, in the status line attestd sends every second:
`bromure_sandbox_status.build()` raised `AttributeError` on `{"sentry": null}`,
because a key *present* with value `null` returns `None` rather than the `.get()`
default. A host saying "no sentry" that way would have taken the whole status
line down. The builder is now total over every spec shape, including malformed
ones, and a test asserts it.

**And then it turned out not to be a crash at all.** The next live run showed the
attestor coming up **~80 seconds into a spec-less boot** — not failing, just late,
with twenty denied outbound connections in the meantime because the host fails
closed on binary rules without an identity. The hardening above was right and
addressed the wrong failure.

The cause was an `import` at module scope. attestd did
`sys.path.insert(0, dirname(__file__))` — the **meta share** — and then
`import bromure_sandbox_status`. The host stages that file, possibly later than
attestd itself, and a workspace with no sandbox spec does not need it at all. So
an `ImportError` killed the process **before it ever opened 5840**, systemd
restarted it a second later, and the loop repeated until the file turned up.

The ordering was backwards, and naming it that way is what makes it obvious:

> attestd's **first** job is to answer `who`. Building `sandbox_status` is a
> second job. Nothing belonging to the second job may sit on the path to the
> first.

The import is now lazy, retried, and never fatal: attestd connects, sends its
hello, and answers identity queries immediately; the status watcher reports
`sandbox status unavailable for now … identity still served` and tries again
every five seconds. `tests/test_sandbox.sh` runs attestd from a directory
containing **only** attestd and asserts it still connects, that its first frame is
the hello, and that connecting happens before the status module is even looked
for.

And the boot test now asserts the attestor connects **within 8 seconds**, not
merely eventually. A test that asked "did it connect at all?" called an 80-second
delay a pass.

**Legibility, since the attestor cannot report its own absence.** `sandbox_status`
is the thing attestd sends, so a workspace without one cannot say so through the
usual route. The root script now captures `systemctl is-active` / `Result` /
`NRestarts` and the unit's journal **while it is still root** — after the
revocation there is no sudo left to ask systemd anything — and agentd logs it
with an `ATTESTD-DIAG` prefix. The shell channel carries an additive `warnings`
key on exec replies, which is the one channel that still works when 5840 does
not.

#### The gate waits for what was requested, and nothing else

The window above is closed by `sandbox_gate()`, and the first version of it
closed too much. It waited **unconditionally** for a supervisor, which made a
**strict-only** workspace permanently unusable: `strict_sandbox: true`, no
`filesystem_policy`, no `process`, no sentry. The host correctly stages no
`openshell-sandbox.json` for such a workspace, so no supervisor runs — and every
exec answered `rc 75, sandbox unavailable … (still starting)`, forever. That is
the plain Phase-4 strict sandbox that predates all of this work, and it was dead
on every boot for six rounds.

The two conditions are independent, and the gate now treats them that way:

| requested | waits for |
|---|---|
| strict marker | the revocation (`STRICT_DONE`, and `strict.json.applied`) |
| a staged spec | the supervisor (`tmux_socket` in the status) |
| neither | nothing — no gate at all |

A workspace with no spec never waits for a supervisor, and its commands run
exactly as they did before any of this existed: unconfined by Landlock, under the
revoked privileges. That is not a weakening — it is what "strict only" *means*,
and the alternative was a workspace that ran nothing at all.

**Waiting for attestd is deliberately not a condition**, though it was suggested.
attestd reports; it does not confine. Gating execs on it would turn an
observability outage into a workspace outage, and `STRICT_DONE` plus
`strict.json` already answer the question attestd would only be relaying.

The timeout message names **which half** is missing. "still starting" on its own
sent a round looking at the wrong daemon; `still waiting for the sandbox
supervisor (ruleset refused)` does not.

#### The pre-sandbox exec window

§1.3 moved the shell service ahead of the session work so a hung sandbox step
could not cost the host its only way into the VM. That was right, and it opened a
window of its own: on the second boot `vm exec` answered at **uptime 4.4 s**,
before the root script had run — so host commands were served **unconfined, with
sudo still present**, and `bash -lc` sourced whatever the previous session's agent
had left in `~/.bashrc`. The home is persistent, so this is §1.5's confused
deputy again, reached through timing rather than through a missing route.

The connection is still accepted immediately — the host can always see the VM,
and health and status answer at once. What waits is anything that runs workspace
content: `sandbox_gate()` holds execs, interactive sessions and file operations
until the revocation has happened *and* the sandbox is up. If it never arrives,
the caller gets `sandbox unavailable: <reason>` and exit 75. **There is no
fallback to running it unconfined**, which is the whole point.

`agentd` also no longer exits 75 when it cannot apply strict. If the marker is
absent and `sudo -n true` fails, it says so, keeps running so the host can reach
it, and refuses to start a session — fail closed, and visibly, instead of a
silent restart loop.

The outcome is **published**, to `/run/bromure-sandbox/strict.json`, and
`sandbox_status` carries `strict_applied`. A revocation that failed but was
reported as applied would be worse than one that never ran — the host would treat
the workspace as strict while the agent still held sudo — and the root script
touches its completion marker regardless, so the marker alone cannot be trusted
to mean it worked. `applied` is true only when every mount landed; anything else
arrives with the reason in `warnings`.

`tests/test_strict.sh` uses mount namespaces as the reboot: it takes a baseline
of `/etc`, applies the revocation inside `unshare -m` and checks there that
**real `sudo` refuses** and the user is out of the groups, then leaves the
namespace and asserts `/etc/group`, `/etc/gshadow` and `/etc/sudoers.d` are
byte-identical. Then it does it a second time, which is the boot that used to
fail.

### 1.8 Interaction with the strict sandbox

- **Landlock does not require it.** It touches no credentials and is
  irreversible only for the restricted tree.
- **`process` / seccomp *does* require it.** `no_new_privs` is irreversible and
  disables every setuid binary in the tree, `sudo` included. A workspace without
  the strict sandbox still grants the agent user sudo, and silently breaking it
  would be worse than not applying the filters. So `bromure-sandboxd` applies
  Landlock either way, and applies the process layer only when the strict
  sandbox is applied or requested — recording a `warnings` entry when it
  declines, so the host can say why.

**Recommendation for the host:** force `strict_sandbox: true` whenever the
policy has a `process` section. (Done on the host side; the warning path below
stays for a hand-edited spec.)

#### The shipping blocker this used to be

`confine_self` has two modes, and the first version only had one. It called the
enforcement with `child_hardening=False` when the process layer was off — but
that flag only skips the *child* filter. `no_new_privs` was still set and the
*main* seccomp filter was still installed.

So a workspace that switched on nothing but the kernel sentry got, on every pane:

```
NoNewPrivs: 1   Seccomp: 2
$ sudo -n true  →  sudo: The "no new privileges" flag is set
```

while `status.json` truthfully reported `"filesystem":"off","seccomp":"off"`.
That would have reached every user who merely enabled the sentry, and it
contradicted this very section. The fix is that with no `filesystem_policy`, no
`process` and no strict sandbox, `confine_self` applies **nothing**: no nnp, no
filters, bounding set intact. `tests/test_sandbox.sh` §2b pins it for both a pane
and an exec-op child.

Applying Landlock *without* nnp needs one more thing, because the kernel wants
either nnp or CAP_SYS_ADMIN for `restrict_self`: in that mode the ruleset is
applied **while still root**, before the privilege drop, and the drop then uses
pre-resolved numeric ids so nothing has to reach NSS after the policy is live.

#### What Landlock-without-strict actually guarantees

Precisely, because this is the configuration where the agent still has `sudo`
and it would be easy to over-claim. All of the following was measured on this
kernel, as a **root** task inside a Landlock ruleset and with no seccomp:

All of it is also asserted by `tests/test_sandbox.sh` §3, which exercises this
exact configuration — a `filesystem_policy` with no `process` section and no
strict sandbox — so the table stays true rather than being a one-off measurement.

| | |
|---|---|
| write a denied path, as root | **EACCES** — the ruleset holds against root |
| `mount` a tmpfs into an allowed directory, as root | **EPERM** — Landlock denies `mount`/`umount2`/`pivot_root` for *any* landlocked task, because it cannot reason about new mounts |
| `ptrace(PTRACE_ATTACH)` a process outside the sandbox | **EPERM** |
| read `/proc/<outside-pid>/mem`, `/proc/<outside-pid>/environ` | **EACCES** — both go through `ptrace_may_access` |
| `kill()` agentd, attestd or the supervisor | **DELIVERED** — Landlock does not scope signals until ABI 6 (kernel 6.12); this kernel is ABI 4 |
| `init_module` | **not restricted** — root can load a kernel module and undo anything, unless the sentry has already raised lockdown |

So Landlock-without-strict gives you **filesystem confinement, including against
root**, and it gives you ptrace isolation. It gives you **no userland
tamper-resistance**: a sudo-capable agent can kill agentd, attestd and the
supervisor, and can load a kernel module. The kernel sentry is what covers the
second of those, and only because it raises lockdown before the agent runs.

Under the strict sandbox all of it closes: `sudo` is gone, `no_new_privs` makes
setuid binaries inert, and the seccomp child filter narrows signals (§1.8) and
blocks `init_module` and `bpf`.

### 1.9 Divergences from OpenShell, and why

Four: three in the seccomp layer and one in the privilege drop, all argued at
the point of divergence in the source.

1. **Architecture-mismatch action.** The compiled filter's arch check returns
   `SECCOMP_RET_KILL_PROCESS` where seccompiler returns `SECCOMP_RET_KILL_THREAD`.
   Unreachable on a single-arch aarch64 guest; strictly safer if ever reached.

2. **The child filter's `kill` targeting.** OpenShell denies `kill(0, …)` and
   `kill(<any negative>, …)` outright. Narrowed to `kill(-1, …)`, the
   supervisor's TGID, and the supervisor's PGID.

   *Why:* `kill %1` in bash is `killpg`, i.e. `kill(-pgid)`. The blanket rule
   breaks POSIX job control in every interactive pane — fine for OpenShell,
   whose workload is one command, fatal for a product whose whole surface is
   interactive shells. The property OpenShell wanted (a workload cannot rejoin a
   trusted process group and then signal it) is obtained instead from `setsid()`
   on the sandboxed tree plus the explicit PGID denial. `tests/test_sandbox.sh`
   asserts both halves: `killpg` on the pane's own group works, `kill(-1)` is
   EPERM.

3. **`allow_inet` pinned true.** OpenShell derives it from `network_policies`,
   which is not one of the three sections this work covers. Bromure's egress
   control is the host MITM proxy plus attestd, not a socket-domain ban.

4. **`SECCOMP_FILTER_FLAG_LOG`** on every filter. It changes nothing about what
   is allowed or denied — only whether the kernel tells anyone. Without it a
   refused syscall leaves no trace at all: `audit_seccomp` is the only call the
   kernel makes on a blocked syscall, and it is reached only when the filter
   asked for logging *and* the action is in `actions_logged`. A sandbox whose
   denials cannot be observed is one nobody can tell is working. Requested
   best-effort: if the kernel rejects the flag the filter is installed without
   it, because refusing to confine for want of telemetry has the priorities
   backwards. Invisible to `differential/`, which compares probe outcomes.

5. **`drop_privileges(extra_groups=…)`**, additive: supplementary gids added
   after `initgroups` and before `setuid`. Exactly one is used, `bromure-tmux`,
   and it is what makes §1.4 work. With an empty tuple the function is
   byte-for-byte upstream's, which is what `differential/` exercises.

**Not a divergence, though it looks like one:** `no_new_privs` is set explicitly
before `restrict_self`. OpenShell reaches `restrict_self` with nnp already set,
inherited across fork from the workload-launcher thread that sets it in
`install_workload_listener`. There is no such thread here, and without nnp the
kernel rejects `landlock_restrict_self` with EPERM for any caller that is not
CAP_SYS_ADMIN — which, after the privilege drop, is us. Same end state.

### 1.10 Bromure's additions layer

Modelled on the network policy's `_provider_*` rules: reported to the host in
`sandbox_status.additions`, with a `why` for each, and **never merged into the
user's lists**.

| path | access | why |
|---|---|---|
| `/run/bromure-sandbox/tmux` | rw | the tmux control socket, shared with agentd |
| `/dev/ptmx`, `/dev/pts` | rw | pty allocation for panes |
| `/run/utmp` | rw | login records for `who`/`w`; every pane is a login shell |
| `/mnt/bromure-meta` | ro | proxy.env, api_key.env, MCP shims, agent stubs |
| resolver directory | ro | DNS resolver configuration — see below |
| `/home/<run_as_user>` | rw | fallback home, only when the workspace home cannot be idmapped (§1.12) |

`/run/utmp` is a **file**, not a directory, so it grants nothing else under
`/run` — `ctl.sock` in particular stays out of reach. Without it, Landlock denies
the `utempter` helper and the journal gains
`utempter: pututline: Permission denied` on every new pane, while `who` and `w`
come back empty.

It is **inert under the strict sandbox**, and the reason is worth recording
because it looks like a bug otherwise: `utempter` is setgid `utmp`, and
`no_new_privs` makes `execve` ignore the setgid bit, so the helper runs with the
workload's own gid and cannot write `/run/utmp` whatever Landlock says. Under
strict that message is expected; this addition is what removes it in the
Landlock-only mode, where there is no nnp.

#### The HTTP proxy, and how a loopback flow is still attributable

Every non-OpenShell workspace runs with `HTTPS_PROXY=http://127.0.0.1:<proxy_port>`
(65534 on a fresh boot; the file may say 8080 for a snapshot resumed under an
older daemon). So the destination of almost every real client's connection is
the proxy. The kernel sentry reports that flow (§4.3c), but a row saying
"curl → 127.0.0.1" tells nobody anything.

The one value both sides hold is the client's **source port**:

```
guest: net_flow  tcp 127.0.0.1:<proxy_port>  sport=45678  comm=curl  chain=[bash, …]
guest: bridge    BROMURE-CLIENT 1 sport=45678 peer=127.0.0.1
host:  MITM      that connection's CONNECT example.com:443, and its L7 decisions
```

`bridge_http_proxy_service` writes that one line to the **host** end of the
vsock bridge before any client byte. `addr` comes from `accept()`, so the port
is known before the client has sent anything, and the line is written before the
pump threads start rather than racing them. Properties that matter:

- **HTTP only.** `ssh`, `aws` and `llm` carry their own protocols from the first
  byte and must not be prefixed; `_bridge` takes no preamble by default and only
  the HTTP listener passes one. The suite asserts the ssh bridge is unprefixed.
- **A trailing newline and a version number**, so a host that does not know the
  line can skip it and a later field does not break the parse.
- **Docker-bridge peers are announced too**, with the container's address as
  `peer`. There will be no sentry flow for a process inside a container — it is
  not a guest process — so the host gets a peer it cannot join, which is better
  than a join made to the wrong process.
- **A write failure fails the connection** rather than bridging it unannounced.
  A stream the host reads as HTTP when it expected a preamble is worse than a
  refused request the client will retry, and a half-written line is the one
  state nobody can parse.
- `BROMURE_BRIDGE_PREAMBLE=0` turns it off, for a host that cannot take it.

This is a wire-format change on a channel that crosses the guest/host boundary,
which is why it is versioned, skippable, and has a kill switch; agentd ships in
the meta share with the host, so in practice the versions always match.

#### ICMP, which could not work in a sandboxed workspace at all

`net.ipv4.ping_group_range` ships as **`1 0`** on this image — low *above* high,
an **empty** range — so no group may open a `SOCK_DGRAM`/`IPPROTO_ICMP` socket.
`/usr/bin/ping` tries exactly that first and falls back to `SOCK_RAW` on its
`cap_net_raw` file capability, which is why `ping` works for a normal user.

Inside the strict sandbox the fallback cannot work: `no_new_privs` is
irreversible and a file capability is not honoured under it. So `ping` failed for
the agent in a way it never does for the user, for a reason neither the policy
nor any error message mentions.

Measured, before and after, with no capability anywhere:

| `ping_group_range` | `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)` | what `ping` does |
|---|---|---|
| `1 0` (shipped) | `EACCES` | falls back to `SOCK_RAW`, 1 hit on `raw_sendmsg` |
| `1000 1000` | succeeds | 1 hit on `ping_v4_sendmsg`, 0 on `raw_sendmsg` |

`bromure-sandboxd` sets it to the **workload's** gid — `plan.gid`, the gid the
session actually runs as. The kernel checks the caller's egid *and* its
supplementary groups against the range (measured: uid 999 with gid 1000 is
allowed, the same uid with gid 999 is refused), so it has to be the gid the agent
really has rather than the workspace owner's.

**Runtime only**, written to `/proc`, never to a `sysctl.d` drop-in — the same
rule as the strict revocation (§1.7): a boot-time change this daemon makes dies
with the boot. A workspace with no spec at all gets it too, before the "nothing
to do" early return, so `ping` does not depend on whether a policy happened to be
staged.

**One sysctl covers both families.** ICMPv6 ping sockets go through the same
`ping_init_sock`, so there is no `net.ipv6.ping_group_range`; verified that
`AF_INET6`/`IPPROTO_ICMPV6` opens with the same range set, and that the v6 path
does not exist in `/proc`.

Two consequences worth stating. It is also what makes ICMP *visible*: the dgram
path is a probe point the sentry can see (`ping_v4_sendmsg`, §4.3c) and the raw
path is the one a sandboxed process cannot reach anyway. And a range is a single
contiguous span, so when the workload's gid differs from the workspace owner's,
the owner's login shell loses `ping` — a contiguous range covering both would
also cover every system group between them. That case adds a `warnings` line
rather than leaving someone to discover it by running `ping`.

#### DNS, which was dead in every sandboxed workspace

`/etc/resolv.conf` on this image is a symlink to
`/run/systemd/resolve/stub-resolv.conf`, and **Landlock checks the resolved
path** — so a policy granting `/etc` does not grant the file it points at. Every
hostname lookup failed with `Temporary failure in name resolution`, which reads
as a *network*-policy denial rather than the filesystem one it is, so the symptom
pointed at the wrong layer entirely. OpenShell never meets this: its containers
have a real `/etc/resolv.conf`.

The addition is **unconditional**, because the alternative is a feature that
silently does not work — without it every hostname-based network rule is
unusable. It is also pure Bromure plumbing: systemd-resolved is an implementation
detail of our image, not something a user's policy should have to know about.

Three things about it were measured rather than reasoned:

- **The directory, not the file.** Grant the file and the first time
  systemd-resolved rewrites it — by atomic rename, on any DHCP renewal or link
  change — the path names a new inode that no rule covers, and DNS dies
  mid-session. Verified directly: a file grant reads `original` and then
  `Permission denied` across a rename; a directory grant follows the
  replacement. A fix that passes every test written at boot and fails hours
  later is worse than no fix.
- **Granting that directory gives nothing away.** It also holds
  `io.systemd.Resolve`, a world-writable varlink socket — and Landlock at this
  ABI does not mediate connecting to a unix socket at all (that is ABI 6
  scoping), so the workload could already reach it.
- **The `/etc` NSS files are not needed.** With only this directory granted and
  no `/etc` at all, `getaddrinfo` resolves: glibc's built-in
  `dns [!UNAVAIL=return] files` default suffices. So `/etc/nsswitch.conf`,
  `/etc/hosts` and friends are deliberately **not** added. A policy that wants
  `/etc/hosts` honoured can list `/etc`, and the baseline below adds it whenever
  there are network rules.

#### The policy advisor, and one thing that silently depended on the proxy

`http://policy.local` used to be reachable only through the **cooperative** MITM
proxy: the guest had `HTTP_PROXY` set, the proxy recognised the name and answered
it. OpenShell-policy workspaces no longer get proxy env vars — deliberate, matches
upstream (OpenShell's own `no_proxy` test asserts they are absent), and what the
strict sandbox already did — so that route is gone. The host now intercepts
`192.0.2.254:80` transparently. TEST-NET-1 is reserved for documentation and never
routed, so a workspace that somehow escapes the diversion fails closed rather than
reaching a stranger.

The guest's whole job is to make the name resolve, which is
`task_openshell_advisor_host`. Three properties, each of which was a bug in
something earlier in this project:

- **Ordering.** After `task_apply_hostname`, which rewrites `/etc/hosts` wholesale
  and would drop the line; before the strict revocation, after which there is no
  sudo. Asserted in `tests/test_boot.sh` against the real boot sequence, because
  that is the part a unit test cannot reach.
- **Idempotent, every boot**, and managed by a marker comment so only our own line
  is ever rewritten. `/etc/hosts` is how the machine resolves its own name; a
  clever rewrite that drops a line it did not understand is a machine that cannot
  `sudo`.
- **It converges both ways.** The mapping is removed when no OpenShell spec is
  active, so a workspace that stops using one does not keep a stale entry. That is
  the lesson from the strict revocation, which used to leave state on disk that
  outlived its cause.

**The trigger is not the spec.** It was, and that left a whole class of workspace
unable to reach the advisor: a policy whose rules are *all* network rules gets no
`openshell-sandbox.json` — correctly, there is nothing for a supervisor to
enforce — but it is still an OpenShell-policy workspace, and the advisor serves
every one of those. So the host stages `/mnt/bromure-meta/advisor.json`
(`{"host": ..., "address": ...}`) whenever the workspace's firewall is an
OpenShell policy, regardless of sections, and removes it otherwise.

The guest accepts **either** that file or the spec's `advisor` block as the
trigger, and `advisor.json` wins on the values. Accepting both is deliberate: the
host and the guest ship separately, so neither deployment ordering can break a
workspace that works today. When the host has fully moved over, the spec block
simply stops appearing and nothing here needs to change.

**What silently depended on the proxy.** `task_install_ca` delivers the CA-trust
variables (`NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, …) through
`/etc/profile.d` and `/etc/environment` — which covers login shells and PAM
sessions, so every pane has them. A `vm exec` confined by the supervisor reads
**neither**: `_sanitize_env` builds the child's environment from a fixed set, on
purpose. The only thing putting the CA paths there was the prelude sourcing
`proxy.env`.

With `proxy.env` gone, so were they — and the failure is **partial**, which makes
it worse than a clean break: the system trust store still covers OpenSSL clients
(`curl`, `git`), so only **node** (its own bundle) and **python-requests**
(certifi) fail certificate validation against the transparent MITM, in
non-interactive execs only, while the identical command in a pane works. Nothing
would have attributed that correctly. `_ws_run` and `_ws_popen` now supply the CA
paths explicitly, filtered to the files that actually exist — a variable naming a
missing file is worse than an absent one, since `REQUESTS_CA_BUNDLE` makes
requests *raise* rather than fall back.

#### OpenShell's baseline enrichment — a reversed decision

Round 2 settled on "no baseline: honour the policy verbatim, and if an agent CLI
cannot start under a policy that is valid in OpenShell, say so rather than
widening". The instinct was right and **the call was wrong**, because it was made
without knowing that OpenShell has a baseline of its own. When the policy has
**at least one network rule**, OpenShell adds read-only `/usr /lib /etc /app
/var/log /proc /dev/urandom` and read-write `/tmp /dev/null`, for the paths that
exist and are not already listed. Its own e2e test
`landlock.rs::hard_requirement_accepts_enriched_device_path` depends on it: the
policy lists neither `/dev/urandom` nor `/tmp`, and the workload reads
`/dev/urandom`.

So this is not Bromure inventing a baseline; it is Bromure failing to implement
one that upstream documents, which makes policies that work in OpenShell fail
here. **Parity wins.** Same condition, same paths, same de-duplication, reported
with `why = "OpenShell baseline (policy has network rules)"` so it is never
confused with the plumbing above.

It needs the host to stage the network rules, which the guest spec did not carry
(§2). When the key is absent the guest **cannot tell** "no network rules" from
"the host did not say" — so it applies no enrichment (the conservative,
no-regression answer) and **warns**, rather than guessing. Silently treating the
second as the first is how a workspace would lose parity with nobody noticing.

Beyond that baseline the list still deliberately does **not** grow. A policy that
omits `/usr` and has no network rules is a policy that is wrong, and repairing it
silently would mean the enforced policy is not the stated one.

The additions are also excluded from OpenShell's zero-valid-paths refusal: they
always resolve, so counting them would turn "none of the user's paths exist"
into an `enforced`-looking sandbox that allows nothing but `/dev/pts` and a
socket.

### 1.11 Two things the host UI should warn about

**Landlock is additive, not most-specific-wins.** A `read_write` entry on a
parent grants write to everything beneath it, *including* a subtree the same
policy separately lists under `read_only`. Verified against OpenShell's own
crates (`differential/diff.py`, case "read_only nested inside a read_write
parent"): with `read_only: [<root>/ro], read_write: [<root>]`, writing,
creating and truncating inside `<root>/ro` all succeed. So

```yaml
read_only:  [/home/me/project/secrets]
read_write: [/home/me/project]
```

gives `secrets` **no protection at all**, and nothing tells the user. The editor
should reject, or at minimum warn on, a `read_only` path that is a descendant of
a `read_write` path.

**`/dev/null` must be in `read_write`.** The tmux server opens it `O_RDWR` while
daemonizing. With `/dev/null` under `read_only` the server dies with a bare
"server exited unexpectedly" and the workspace gets no session, with nothing
anywhere pointing at the policy.

### 1.12 `run_as_user`: what it costs, and what it cannot do

This section was rewritten after `run_as_user: sandbox` was run on the real image
for the first time. Everything it said before was reasoned from the mode bits and
from the kernel documentation, and **most of it was wrong** — in both directions.
The measurements are below; each one contradicts something this file previously
asserted.

#### What a distinct run_as uid actually breaks

A `run_as_user` naming anything other than the workspace user changes four things
that nothing else in Bromure changes, and every one of them was broken. The
configuration reported itself as `filesystem enforced · runs as sandbox · seccomp
enforced · sentry running`, had **no session at all**, and answered every host
command with **exit 127 and no output** — including `/bin/echo hi`.

1. **`ctl.sock` was chowned to the workload's group.** `serve_control` used
   `plan.gid`, which is the same number as the workspace group in every other
   configuration. With `run_as_user: sandbox` it was 991, and agentd — gid 1000,
   and the only legitimate client there is — got `EACCES` from `connect`.
   `_sandbox_exec` returned `None`, `_ws_run` turned that into exit 127, and
   `status.json` (written by root, needing no socket) went on reporting a healthy
   sandbox. **This was the instant 127.** Fixed: the socket carries
   `owner_gid`, which is also strictly tighter, since nothing inside the sandbox
   needs it.

2. **tmux refuses any client whose uid is not the server's.** The check is in the
   server, on accept, against the peer credentials the kernel reports — so it is
   unaffected by the socket's ownership or mode. Measured on tmux 3.4: a `0666`
   socket, chowned to the client's own uid, is still answered with
   `access not allowed`. Worse, `has-session` prints that and **exits 0**, so
   agentd's "is there a session?" probe read as success, it never created one, and
   it never sent `session_ready` — which is why the sentry stayed in `phase: boot`
   and the host's boot budget fired. Fixed: every tmux **client** command routes
   through the supervisor's `exec` op when the uids differ, so it runs as the
   server's uid; and `_tmux_ok` now reads stderr for the refusal instead of
   trusting the exit status.

3. **The account had no home.** `ensure_user` created it with
   `--no-create-home`, so `pw_dir` named a `/home/sandbox` that did not exist and
   the supervisor fell back to the first workdir — i.e. `HOME` pointed at the
   user's project folder, and the agent's dotfiles would have landed in their
   repository. See *What HOME is* below for what it is instead.

4. **The account's shell was `nologin`.** tmux resolves `default-shell` from
   `$SHELL`, falling back to the *running* uid's passwd entry. So every pane
   printed "This account is currently not available" and exited, the session died
   with its last pane, and the server exited with the session — which the
   supervisor had already reported as a server that started. Fixed twice over: the
   account is created with `/bin/bash`, and the server child pins `SHELL`
   explicitly so the pane's shell is a property of the sandbox rather than of
   whatever environment the root script happened to have.

A fifth, found while fixing these and **not specific to `run_as_user`**: the
supervisor cached agentd's pid at startup and passed it to `os.getpgid()` in every
confinement. agentd is `Restart=always`, and the strict sandbox's two-incarnation
boot *guarantees* the incarnation that started the supervisor is gone — so
`getpgid` raised `ESRCH` and took the exec down with it. Fixed: the pid is
re-resolved per use, and a pid that cannot be resolved degrades to the
supervisor's own rather than failing the exec.

#### Idmapped mounts: measured

    open_tree(OPEN_TREE_CLONE) → mount_setattr(MOUNT_ATTR_IDMAP, userns_fd)
                               → move_mount() back over the same path

> The map direction is the reverse of the intuitive one: `uid_map` is
> `<on-disk-uid> <presented-uid> 1`. Writing it the other way round mounts
> successfully and silently reports every file as 65534/nobody.

The previous version of this section said virtiofs idmapping was unproven because
"this VM has no virtiofs share to borrow". **That was simply false** — this guest
has two, `/mnt/bromure-meta` and `/mnt/bromure-outbox`, and measuring took one
command. Two facts came out of it, and they point in opposite directions:

**Virtiofs cannot be idmapped on this kernel.** `mount_setattr(MOUNT_ATTR_IDMAP)`
returns `EINVAL` for every virtiofs mount, because virtiofs does not set
`FS_ALLOW_IDMAP` on 6.8. So idmapping a host-backed share is not a design we
chose against; it is one the kernel refuses. **This rules out idmapping
`/home/ubuntu` as the way to give a run_as user a usable home** wherever that
path is host-backed, which is why the home is a real directory on guest storage
instead.

**Virtiofs does not enforce the guest's DAC either, so the share is writable
anyway.** A share that `stat`s as `uid 1000 mode 0755` is nonetheless created in,
and written to, by uid 999 — verified directly and through the sandbox. The
lookup reports the host's ids; the operation is carried out by the daemon on the
host side. So the problem this whole subsection was written to solve **does not
exist for Bromure's shared folders**.

That mattered, because the old `check_workdir_access` inferred writability from
the mode bits and therefore emitted a prominent, confident, **false** warning on
exactly the configuration the feature exists for. It now forks, becomes the uid,
and tries to create a file. There is no way to get this right by inference.

So what the idmap is for is **not** the shares, which need no help. It is
`/home/ubuntu` — ext4 on this image, where DAC *is* enforced, and which has to be
the workload's home for the reasons in the next subsection. Verified in both
directions in `tests/test_boot.sh`: a file the workload writes there is its own uid
inside the remap and **uid 1000 on disk**, so nothing it creates needs a chown
afterwards and the host sees ordinary workspace-user files.

#### What HOME is, and what `run_as_user` therefore means

**HOME is the workspace user's home, seen through the idmapped mount** —
`/home/ubuntu`, presented to the workload as its own. Not a home of the run_as
user's own. The reason is function, and it decides the question: Bromure seeds the
agent's entire configuration into `/home/ubuntu` — `~/.claude`, `settings.json`,
the `.bashrc` hooks, `.gitconfig`, the agent stubs. A workload with
`HOME=/home/sandbox` sees none of it and starts **unconfigured**, which is a worse
workspace than the separation would be worth.

And the separation is worth little here, because a Bromure workspace VM is
**single-tenant**. Without `run_as_user` the agent runs *as* ubuntu and owns
everything in `~ubuntu` anyway, so this is no loss against the baseline. The guest
holds no real credentials — they are host-side, and the proxy substitutes them —
so there is nothing in `~ubuntu` the agent was not meant to reach. The boundary is
Landlock plus the network policy, exactly as in OpenShell, where the sandbox user
owns its whole workdir.

So, precisely, in Bromure `run_as_user: sandbox` means the workload:

- is **not uid 1000**, so anything keyed on that uid outside the remapped mounts
  is out of reach;
- holds **none of ubuntu's supplementary groups** — no `sudo`, no `docker`, no
  `adm` — and under the strict sandbox holds none of those in the first place;
- cannot drive the workspace user's tmux server, or be driven by it;
- and **sees ubuntu's home as its own** through an idmapped mount.

It is **not a secrecy boundary for the workspace user's files.** If a multi-tenant
mode ever needs one, the change is to stop remapping the home and let the "other"
bits apply — which still works for shared folders (they do not enforce guest DAC,
above) and not for a checkout on guest storage. That is a policy decision, recorded
here so it is not rediscovered as a bug.

**Two conditions, both checked before HOME is chosen**, because a home the workload
cannot enter is the original bug in a new shape:

1. the mount must be remappable — probed by `can_idmap()` with the same code the
   confined child will run, so the answer cannot disagree with what happens later;
2. the **ruleset** must grant write at or above it — `policy_grants_write()`.
   Landlock is path-based, so a grant on a parent counts; an absent
   `filesystem_policy` means no ruleset and the question does not arise.

If either fails, `ensure_run_as_home` creates `/home/<user>` on guest storage,
owned by the run_as uid, mode 0700, re-asserted on every start so a changed
`run_as_user` cannot leave a home owned by the previous uid — and it goes into the
ruleset as an addition, because otherwise it is a home the workload cannot write
either. `sandbox_status.run_as.home_via` says which of the two happened
(`idmapped workspace home` or `supervisor-created fallback`), so the host can
report it **without an informational line in `warnings`** — those are weighted, and
one that fires on every `run_as` workspace is noise.

#### What the policy template has to grant

Nothing new — with one condition it almost certainly already meets. HOME is the
workspace user's home, so the policy has to grant **write at or above
`/home/ubuntu`**, which the OpenShell template already does. If it does not, the
supervisor falls back to a home of the run_as user's own and grants *that* itself,
as a Landlock addition reported in `sandbox_status.additions.why`. Either way a
workspace naming `run_as_user` needs **no change to its `filesystem_policy`**.

#### Saying why, instead of exiting 127

Everything between `fork` and `execvpe` runs in a process with no stderr the
caller reads, no logger, and — after `confine_self` — no right to open a file to
write one. Both fork sites ended in `except BaseException: os._exit(127)`, and the
cost came due here: hours went into guessing at four different failures that all
presented as the same silent 127.

Now each step names itself (`StageError`), the message carries the operation, the
path and the errno, and it reaches the supervisor over a **CLOEXEC** pipe — which
makes the protocol unambiguous: bytes mean the child failed before `execvpe`, EOF
means it reached it. So:

    chdir /tmp/x/forbidden: Permission denied (EACCES)
    exec /nonexistent/binary /home/sandbox: No such file or directory (ENOENT)

instead of `exit 127`, empty output. agentd puts the supervisor's reason on the
caller's **stderr** — where anyone debugging a failed command is already looking —
and into the pane itself when a pane fails to start.

**A refusal is not a missing command.** `_sandbox_exec` used to swallow the errno
and return `None`; `_ws_run` turned that into exit **127 with empty stdout and
stderr**, which is exactly what "command not found" looks like. So the one failure
that mattered — `connect()` returning `EACCES` on `ctl.sock` — was indistinguishable
from a typo, for two rounds. Now:

- the errno travels, so the reason names the socket and the errno:
  `bromure sandbox: cannot run /bin/echo: no reply from the supervisor:
  [Errno 13] Permission denied (/run/bromure-sandbox/ctl.sock)`;
- it goes to the caller's stderr, the journal, and the pane when a pane fails;
- and it exits **126**, not 127. 127 stays "the command was not found", which is
  the caller's problem; 126 is "the sandbox could not run it", which is ours. A
  support log has to be able to tell those apart without a round trip.

**And the status line has to actually resend.** The `warnings` list was not part of
attestd's change fingerprint, so the supervisor's no-session diagnosis was written
into `status.json` exactly as designed and then **never sent** — the diagnostic that
existed to end an ambiguity silently preserved it. `warnings` is now in the
fingerprint as a *sorted set*: a warning appearing or disappearing resends, while
the reordering that the original exclusion was worried about does not.

`status.build` carries short hashes of the guest scripts actually running
(`sandboxd`, `openshell`, `idmap`, `agentd`). This is here because a whole round
was spent on a blocker whose symptoms were equally consistent with the fix not
being deployed, and neither side could tell from the status line which code the
workspace was running. It is four small hashes once per start, and it turns that
into a field.

And the supervisor now answers the other question the host could not ask: **why is
there no session?** `session_diagnosis()` fires 60 s after the server started if
agentd has not reported one, and names the socket's real ownership and mode, the
workload's uid and its home. A workspace that never produces a shell should not
also be silent about it.

#### Still open, and host-side

1. *(host, only if multi-tenant ever matters)* a DAC boundary between the run_as
   user and the workspace user's home would mean virtiofsd presenting the share as
   the run_as uid and the home no longer being remapped. Deliberately not done —
   see *What HOME is* above.
2. *(kernel)* virtiofs idmapping needs a kernel with `FS_ALLOW_IDMAP` for FUSE.
   Nothing to do until then; the degradation is reported and, per the measurement
   above, currently costs nothing.

Moving *agentd* to a different uid instead was considered and rejected: agentd's
protection from the workload is the child self-protection filter, which blocks
ptrace/process_vm/pidfd and kill-by-TGID regardless of uid, so a separate uid
adds a second home directory, tmux access problems and DAC work on the bridge
sockets for very little.

---

## 2. Host → guest spec

Implemented as specified. Notes on two fields:

- **`workdirs`** — the host's list is the better source of truth and is used
  when present; entries that do not exist are dropped and reported. The guest
  fallback (share slots from `shares.txt`) exists only for a spec that omits it.
- **`strict_sandbox`** — read, and it gates the process/seccomp layer (§1.5).

---


**`advisor`** — `{"host": "policy.local", "address": "192.0.2.254"}`, the name and
address of the policy advisor the host intercepts transparently. Optional, and
now secondary to **`/mnt/bromure-meta/advisor.json`**, which carries the same
object and is staged for *every* OpenShell-policy workspace including those with
no spec at all (§1.10). Either triggers the `/etc/hosts` mapping; `advisor.json`
wins on the values; the constants are the last fallback. Both are read on every
boot, so a change takes effect without an image bump.

**`network_policies`** — the policy's network rules, staged so the guest can
apply OpenShell's baseline enrichment (§1.10). Only the count matters here; a
list, a dict with `rules`, an int or a bool are all accepted, and an **empty list
means "no network rules"**, which is a different and useful statement from the
key being absent. When it is absent the guest warns instead of guessing, because
"no rules" and "not told" lead to different rulesets.

## 3. Guest → host status

`bromure_sandbox_status.py` merges two files written by two different programs
at two different times — `bromure-sandboxd`'s `status.json` and
`bromure-sentryd`'s `sentry.json` — into the contract's §3 line. A missing file
is a defined state, never an exception.

Fields beyond the contract are additive: `warnings` (§1.8, §1.12), `lockdown`,
`tmux_socket`, `ping_sockets` (the gid that may open an ICMP echo socket, read
**live** from `/proc` rather than from a recorded intention, so it is reported
even in a workspace with no spec and stays honest if anything else moves it —
§1.10), and **`sentry_digest`** — `sha256` of the hex secret string the
module puts in its 5841 hello, `null` whenever the sentry is not running, so the
host can alarm on "guest says unavailable but something is connected".

#### `pending` is not `off`

attestd connects within seconds of boot and sends its first `sandbox_status`
immediately — on a strict workspace, **before** the supervisor has published
anything. Reporting `off` there was wrong twice over: it put a misleading "no
filesystem policy" row in the user's timeline on every boot, and if the sentry
won that race and connected on 5841 first, the host's cross-check saw "connected
while the guest says the sentry is off" and scored it as tampering, weight 20. A
false alarm at second four of every boot, which is the fastest way to teach
someone to ignore the real ones.

So `filesystem` and `sentry` can also be **`pending`**: asked for, not yet
answered. The host treats it as unknown — no timeline row, no cross-check. The
distinction comes from the spec rather than a clock: a `filesystem_policy` that is
present but unpublished is `pending`, one that is explicitly `null` is already
known to be `off`, and a `sentry` that was never enabled is `off` immediately.

`sandbox_status` also carries **`requested`** — `{filesystem, process, strict,
sentry}` as booleans straight from the spec — so the host can tell "not yet" from
"not wanted" without inferring it from a state machine.

#### How far to trust this line

`sandbox_status` travels over attestd, which is userland. Under the **strict
sandbox** that is sound: sudo is gone before any agent code runs, so nothing the
agent can do reaches attestd, the status files or the supervisor.

**Without** strict, it is not, and the reason is the same one that makes attestd's
binary-identity answers untrustworthy there: the agent has `sudo`. As root it can
rewrite `status.json` and `sentry.json`, kill attestd, move a process out of the
sandbox cgroup to defeat the control socket's peer check, or simply stop the
supervisor. None of that is a new weakness introduced here — it is §1.8's stated
guarantee, restated where someone reading the status line will see it: **without
strict, `sandbox_status` is advisory.**

What remains trustworthy in that mode is the **kernel sentry's own channel on
5841**, and only because of the load order (§4.8): the module is loaded and
lockdown raised to `integrity` before any agent code runs, so root-after-the-fact
cannot load a module, cannot write kernel memory, and cannot silence a kthread it
has no handle on. That is why anything security-critical should be read from 5841
and cross-checked against 5840, rather than the other way round.

**This needs attestd to exist without the strict sandbox.** Today agentd starts
it only from `task_strict_sandbox`. It must be started whenever
`openshell-sandbox.json` exists, or a workspace with an OpenShell policy and no
strict sandbox has no way to report its own status. See `PATCHES.md`.

---

## 4. The kernel sentry

### 4.1 Architecture, and why it is not eBPF

The contract asked for eBPF capture (LSM hooks and tracepoints) drained by a
module. Two facts changed that:

1. **`bpf` is not in this kernel's active LSM list**, so `BPF_PROG_TYPE_LSM`
   cannot attach. Adding it means `lsm=…,bpf` on the kernel command line, i.e.
   an image rebuild for every user.
2. **`__tracepoint_sched_process_exec` is not exported to modules** on Ubuntu's
   kernel, so even the tracepoint half was not available the intended way.

So capture is **kprobes registered from kernel space**, and this is better for
the threat model, not a compromise: there is no bpffs pin to unpin, no BPF link
to detach, no perf fd to close, and no userland daemon to kill. It also takes
the image bump off the critical path entirely.

```
kprobes ──> in-kernel kfifo ──> kthread ──> AF_VSOCK (sock_create_kern) ──> host
```

The socket has **no file descriptor**, so it appears in no `/proc/<pid>/fd` and
cannot be closed from userland.

### 4.2 What is captured

38 **capture** probes (26 kprobes and 12 kretprobes), plus one more on the
module's own canary function, which captures nothing and exists only to prove the others
are firing (§4.5). The counts in `probes.armed`/`probes.total` and the hello's
probe list are the capture probes; the canary reports separately, as
`probes.canary`.

Each is registered by symbol name and individually optional — a kernel
that renames one loses that event kind and keeps the rest, which the loader
reports rather than refusing to load.

| kind | hook |
|---|---|
| `exec` | `security_bprm_committed_creds` (kernel-side `linux_binprm`, so the path cannot be swapped under us) |
| `cred_gain` | `commit_creds` — a real gain only; see §4.3 |
| (counted, not emitted) | `__arm64_sys_set{,re,res}{u,g}id`, `__arm64_sys_capset` |
| `ptrace` | `__arm64_sys_ptrace` |
| `module_load` | `do_init_module` (name + signature) and a kretprobe on `load_module` (refusals) |
| `bpf_load` | `__arm64_sys_bpf` |
| `kexec_attempt` | `__arm64_sys_kexec_{load,file_load}` |
| `lockdown_change_attempt` | kretprobe on `lockdown_write`, rejected writes only |
| `mount`, `unshare`, `setns` | the corresponding `__arm64_sys_*` |
| `net_flow` | `tcp_connect`; `udp{,v6}_sendmsg`; `ping_v{4,6}_sendmsg`; `raw{,v6}_sendmsg` — seven probes, one kind (§4.3c) |
| `file_open_denied` | kretprobe on `security_file_open`, `-EACCES`/`-EPERM` only |

**`file_open_denied` is deliberately not called `landlock_denied`.** Landlock
has no tracepoint and its hooks are static; the kernel never says which LSM
refused. The event carries the `hook` name and the host presents "the kernel
denied this open", which is the true statement. In a Bromure workspace AppArmor
is unconfined for these paths so in practice it is Landlock, but that inference
belongs to whoever reads the timeline, not to the wire format.
`BSK_LANDLOCK_DENIED` stays reserved in the ABI for a BPF-LSM or upstream path
that really can attribute.

### 4.3 Event semantics: reporting meaning, not syscalls

The first version's probes were syntactically right and semantically useless.
One idle minute of boot produced **924 credential events, 4 capset, 3
module_load and 1 lockdown_change_attempt**, and the host's watchdog scored it as
"privilege, tampering" with nobody doing anything. Shipped like that, the first
thing a user would see is a tamper alarm and a timeline of 900 rows, and the
rational response is to turn the sentry off — which is worse than not having it.

Four changes, each replacing a syscall-entry probe with one that knows what
happened.

**agentd must never exec `sudo` under strict.** Not a module change, but the
same problem. A *failed* `sudo` is still a real credential gain: the binary is
setuid root, so the exec raises euid to 0 and only then does the policy refuse.
`ports_loop_service` ran `sudo -n ss -tulnpH` **every three seconds**, which on
an idle strict workspace produced a `cred_gain` from agentd roughly every 70
seconds — about twenty in five minutes, enough to trip the host's watchdog on a
workspace where nothing was happening. Every call site now goes through a cached
`_have_sudo()` that is false once the revocation has happened, and falls back to
the unprivileged equivalent (`ss -tulnH`) or the supervisor's control socket.

**Credentials → `cred_gain`, and only on a real gain.** The
`set*uid`/`set*gid`/`capset` entry probes fired on every call a healthy machine
makes — every privilege *drop* by systemd, PAM and cron — and on failures too,
since an entry probe runs before the kernel decides anything. They are now
**counted in the heartbeat and never emitted**. The event comes from a probe on
`commit_creds`, comparing the incoming cred to the current one.

Getting the comparison right took two attempts, and the second one matters:

| rule | events for 5 `sudo` |
|---|---|
| `euid` changed to 0, or any capability gained | **55** |
| authority the task could not already assume | **10** (one per sudo) |

The naive rule reported, per sudo: the setuid exec (1000→0), sudo making it
permanent with `setresuid` (1000→0 again), and three more as sudo juggled through
uid 1. Only the first is an escalation — after the setuid exec sudo holds
saved-uid 0 and a full permitted set, so re-taking root is not news. The rule is
therefore:

- **uid**: `new->euid` or `new->fsuid` becomes 0 **and** the task was not already
  entitled (`old->suid`, `old->uid` and `old->euid` are all non-zero);
- **caps**: `new->cap_permitted` gains bits `old->cap_permitted` did not have.
  Effective is always a subset of permitted, so only growth in *permitted* is new
  authority. This is what catches an exploit that never touches uid.

Suppressed transitions are still counted — `cred_drop` and `cred_reassert` — so
quiet is distinguishable from a dead probe. Measured: 613 setuid + 397 setgid +
972 drops + 144 re-assertions, **zero events**, and exactly one `cred_gain` per
sudo, every one `via: "exec"`.

**Modules → name and signature.** `do_init_module(struct module *)` knows both.
dockerd starting pulls in overlay, br_netfilter and several nf_* modules; udev
loads vsock transports. All in-tree and distro-signed, all routine. The tamper
signal is an **unsigned** load or a refused one — under `integrity` an unsigned
load is impossible, so an attempt means someone is trying. A kretprobe on
`load_module` reports refusals with their errno (`-EKEYREJECTED` is specifically
"unsigned module under lockdown"); there is no name to report at that point and
the errno is the actionable part.

**Lockdown → only rejected writes.** The interface can only *raise*: the kernel
refuses any write that would lower the level. So a successful write is either our
own loader raising to `integrity` — the thing that makes the sentry
tamper-resistant in the first place, previously reported as a tampering attempt —
or a further tightening. A **failed** write is what an attempt to lower looks
like, so the probe is a kretprobe that reports only negative returns.

**`sandboxed`, on every event.** True when the task is in the sandbox's cgroup
— the agent's confined tree — rather than one of Bromure's own unconfined
helpers. Under strict this is what separates signal from noise: `no_new_privs`
makes a credential gain *impossible* inside the sandbox, so one from there is an
escalation, while the same event from agentd or the supervisor is ordinary. The
supervisor sets the cgroup id (a cgroup v2 id is its directory's inode number,
so this needs no new interface) through a **one-way** root-only parameter, for
the same reason `phase` is one-way: otherwise root could point it at a cgroup the
agent does not live in and have its own activity attributed to Bromure.

**`phase`, on every event.** `boot` while Bromure's own root helpers are still
assembling the VM, `session` once the supervisor starts the tmux server and agent
code becomes possible. Nothing the boot phase does is a security event.

`shutdown` matters too: systemd tears the machine down by unmounting everything,
which arrives as a burst of `mount` events from pid 1 on a machine that is going
away. The kernel's reboot notifier fires **after** userspace has finished
unmounting, so it is only a backstop; the primary signal is a transient unit
(`Conflicts=shutdown.target`, `Before=shutdown.target`, `RemainAfterExit=yes`)
whose `ExecStop` runs at the front of systemd's stop transaction.

That makes phase 2 reachable from userspace, and there is no way around it — the
kernel has no hook for "systemd began stopping things". So a root agent in a
non-strict workspace can declare shutdown early and have everything after it
judged as teardown. The module does not pretend it can tell a Bromure helper from
anything else root runs; it records **who** said so and reports
`phase_set_by: {pid, comm}` in every heartbeat. The host pairs that with a
shutdown budget — events still arriving well after the declaration are judged as
session events — and has the pid and comm to name in the warning rather than an
unattributed "the phase looks wrong".

**agentd** announces the move to `session`, over `ctl.sock`, once it actually has
a session — not the supervisor when the server starts. Under strict the root
script starts the supervisor *before* the revocation, so the earlier moment
labelled the revocation's own bind mounts (`/etc/group`, `/etc/gshadow`,
`/etc/sudoers.d`) as session activity: Bromure's own setup reported as if the
agent had done it. The parameter is **one-way**. A plain
writable one would have handed a root agent (which the non-strict mode still
permits) a one-line way to downgrade all of its own activity: write `0`, act,
and every event is counted-only. A write of 0 after the transition is refused
with `-EPERM` and logged with the offending pid and comm; a VM assembles once and
there is no legitimate reason to go back. `tests/test_sentry.sh` asserts the
refusal, including that the value is unchanged afterwards.

This was a hole I introduced with the phase field itself, and found by re-reading
my own parameter permissions rather than by being told. The same pass caught that
nothing was setting the phase at all in production — only the test was — which
would have left every event labelled `boot` and therefore informational forever.

Field names, for the host decoder:

| kind | fields |
|---|---|
| `cred_gain` | `old_uid`, `new_uid`, `old_caps`, `new_caps` (both *permitted*), `via` (`"exec"` or `"syscall"`), `path`, `comm`, `phase` |
| `module_load` | `name`, `signed` (bool), `taints`, `result` (0 on success, negative errno on refusal), `phase` |
| `lockdown_change_attempt` | `result` (negative errno), `lowering` (bool), `phase` |
| every event | `phase` |
| heartbeat | `tallies: {setuid, setgid, capset, cred_drop, cred_reassert}`, `phase`, `probes.ftrace` |

`setuid`, `setgid` and `capset` remain mapped as kind names so an older host
decoding a newer stream never sees "unknown", but nothing emits them.

### 4.3b Sandbox denials — and two probes that could never fire

The user's question is "can I see the agent trying to get out of its own
permissions?". Before this, the answer was one event, `file_open_denied` — and
**it had never fired once, in any workspace, since the day it was written.**

    long ret = regs_return_value(regs);
    if (ret != -EACCES && ret != -EPERM)
            return 0;

Every `security_*` hook returns `int`. `regs_return_value()` hands back the raw
64-bit register, whose upper half is **not sign-extended** — so `-EACCES` arrives
as `0x00000000fffffff3`, which is `4294967283`, which is not `-13`. The probe
registered perfectly and returned early every single time. **`load_module`'s
refusal probe had the identical bug** (`ret >= 0` was true for every negative
return), so a rejected unsigned module had never been reported either.

Nothing caught it because the suite asserted that probes were **registered**,
which they always were. A probe that registers and cannot fire is the worst kind
of green: it looks like coverage and is the absence of it. `tests/test_sentry.sh`
now drives a real trigger for every alarm-class kind and asserts an event
arrives — and prints the kinds it does *not* exercise, because an honest gap
beats an implied guarantee.

That gap has since been narrowed to three. `unshare`, `setns`, `mount` and
`ptrace` are driven for real: an unprivileged user namespace, a `setns` to our own
(EINVAL), a `mount(2)` that EPERMs, and `PTRACE_ATTACH` to our own child. All four
are **entry** kprobes on `__arm64_sys_*`, so the attempt is what fires them —
verified with tracefs before the assertions were written, and the handlers apply
no filter. `mount` is driven as the **syscall** rather than `/usr/bin/mount`,
which is setuid root and would both succeed and add a `cred_gain` of its own,
testing the wrong thing.

`bpf_load`, `kexec_attempt` and `lockdown_change_attempt` are deliberately left
out: loading a BPF program, a kexec and a lockdown write all change the machine in
ways a routine suite should not, and lockdown in particular is one-way for the
boot — which this project learned the hard way.

> `long` is right in exactly one place nearby: `lockdown_write` returns `ssize_t`,
> which is 64 bits, so that register really is the signed value. The rule is the
> hook's declared return type, not a habit.

#### What is reported

`sandbox_denied`, from kretprobes on ten LSM hooks — `security_file_open`,
`security_path_{mknod,mkdir,rmdir,unlink,symlink,link,rename,truncate}` and
`security_file_truncate`. Fields:

| field | meaning |
|---|---|
| `op` | `open_read`, `open_write`, `open_exec`, `create`, `mkdir`, `rmdir`, `unlink`, `symlink`, `link`, `rename`, `truncate` |
| `path` | the target, rendered with `d_path` plus the dentry name for the `path_*` hooks |
| `hook` | the LSM symbol that refused, e.g. `security_path_mkdir` |
| `errno` | 13 or 1 |
| `access` | the open flags, for the `open_*` ops |
| `count` | how many identical denials this record stands for |
| `comm`, `pid`, `uid`, `sandboxed`, `phase` | as every event |

`seccomp_denied`, from a kprobe on `audit_seccomp`: `syscall` (the **number** —
the host already has the arm64 table, and a second copy in the module would
eventually disagree with it), `action` (`errno`, `kill_thread`, …),
`action_code`, `path` (the exe), `count`.

**An execve denial arrives as `open_exec`, not as a separate exec event.**
Landlock checks its EXECUTE right in `file_open`, so probing
`security_bprm_check` would add nothing. The EXEC bit is read from **both**
`f_mode & FMODE_EXEC` and `f_flags & __FMODE_EXEC`: measured, `do_open_execat`
sets it in `f_flags`, and checking only `f_mode` reported a denied binary as
`open_read` — true, and useless.

#### Attribution: what the probe proves

**Not "Landlock denied this".** This image runs
`lockdown,capability,landlock,yama,apparmor`, Landlock's own hook functions are
static and absent from kallsyms, and the generic hook returns the same `-EACCES`
whoever produced it. What the probe proves is **"an LSM refused this, for a task
in the sandbox cgroup"**. Landlock is the cause in every case that can be
constructed here, and the event claims no more than that. `BSK_LANDLOCK_DENIED`
stays reserved for the day BPF-LSM or an upstream tracepoint can name the LSM.

#### Deduplication, because the rate limiter erases exactly the wrong burst

Identical `(kind, op, syscall/errno, path, exe, pid)` denials inside a window
collapse into one event carrying `count`. Without it a retry loop produced a
hundred rows — or worse, sixty-four rows and then silence, as the token bucket
dropped the rest: **the burst that most deserves attention is the one the rate
limiter erases.** The window is one second by default (`dedup_ms`), short because
a denial nobody sees for ten seconds is a denial nobody acts on. Sixty-four slots;
when all are busy the event is submitted immediately rather than lost, and
anything still held is flushed on unload.

The key includes the syscall number. Leaving it out merged a refused `unshare`
and a refused `setns` by the same binary into one row reading `count: 53`, which
is not deduplication — it is losing one of two facts.

#### Tallies, so a denial count means something

Every heartbeat carries `sandbox: {allowed_file_ops, denied_file_ops,
denied_syscalls}`, counted in-kernel for sandboxed tasks only. `allowed` is what
makes `denied` readable: a hundred denials against two hundred operations is a
policy that is wrong; a hundred against two million is an agent feeling for the
walls. The denial count alone cannot tell those apart.

#### A user namespace is not a privilege gain

`unshare(CLONE_NEWUSER)` hands the task a **full permitted capability set inside
its new namespace** — measured: `CapPrm` 0 → `0x1ffffffffff`, global uid
unchanged, `/proc/self/ns/user` now a different namespace. `commit_creds` duly
reported it, and the `cred_gain` rule counted a growth in `cap_permitted` as new
authority.

It is authority over nothing the init namespace owns. And the cost of saying
otherwise is not a stray row: `cred_gain` from a sandboxed task is weight 20
under strict, so **every rootless container, every `bwrap`, every Chrome sandbox
and every test runner that creates a user namespace read as privilege
escalation** — enough to quarantine a workspace for doing something entirely
ordinary.

So a capability growth counts only when `new->user_ns == &init_user_ns`. A **uid**
gain still counts everywhere, because `uid_eq(…, GLOBAL_ROOT_UID)` compares kuids
and is namespace-independent: real root is real root wherever it is seen from.
Nothing is lost by the suppression — the `unshare` and `setns` events report the
namespace creation itself, which is the fact that matters.

And it is **counted, not silently dropped**: `caps_in_userns` in the heartbeat's
`sandbox` block. Every invisible suppression in this module has cost a round.

> Worth recording how this was found. The bug was pre-existing and unreachable by
> the suite until the round that added an `unshare` driver — added only because
> the probe was *registered but unproven*. Driving it turned a latent false
> positive into a failing check on the next run. That is the same lesson as
> `file_open_denied`, arriving from the other direction: the first time a probe
> is exercised is the first time anyone knows what it does.

#### Bromure's own polling must not look like an agent

The first live run of the denial events found the noise before it found an agent:
**33 of the first 59 timeline rows after a boot were Bromure asking itself how
much disk was left.** `_capture` routed everything through `_ws_run` — right for
`git -C <workdir>`, wrong for `df -kP /` — so the status loops ran *inside* the
sandbox and were denied every couple of seconds, forever. They fed the host's
drift score, and the host could not tell them apart: same comm, same cgroup, same
uid.

That is precisely the failure mode these events exist to avoid. A user who learns
to ignore a row that arrives on a timer has been taught to ignore the real one.

So housekeeping is split out into `_sys_capture(args, reason)`, which runs as
agentd rather than as the workload: `df`, `ss`, `runlevel`, `ps`, `findmnt`,
`lsblk`, `ip route`, `hostname`, and the docker status polls. The bar for using
it is **"the command's behaviour cannot be influenced by workspace content"** —
fixed argv, no path from a workdir, no config file the agent can write. `git`,
`tmux`, anything under a workdir and anything reading the home stay on `_ws_run`;
a repository can redirect git through `core.fsmonitor`, `core.hooksPath` and
`diff.external`, which is the whole reason `_ws_run` exists.

The distinction is not "confined vs unconfined" — it is **whose activity is
this**. The sentry already tags every event with `sandboxed`, keyed on the
cgroup, so housekeeping that runs outside it is distinguishable by construction.

Three smaller things fell out of the same run:

- **`docker` reads `~/.docker/config.json`**, which the agent can write, and
  `credsStore` / `credHelpers` / `cliPluginsExtraDirs` are all exec vectors. The
  subcommands used (`ps`, `stats`, `images`, `top`, `volume ls/inspect`) are
  builtins that consult none of them, so this was never live — but running docker
  unconfined makes it worth closing anyway. `DOCKER_CONFIG` is pinned at a
  **root-owned** directory the supervisor creates, which the workspace user
  cannot write.
- **`sudo -n ss -tulnpH` every three seconds.** `sudo` is setuid root, so the
  exec raises euid to 0 before any policy has a say: a `cred_gain` every three
  seconds, forever, on every workspace. Measured, sudo is worth having — 8 of 8
  sockets named against 2 of 8 — so the unprivileged snapshot is taken every time
  and the privileged one only when the socket **set** changes. Full output, rare
  privilege.
- **`/dev/tty` and `/var/log/wtmp` are additions now.** bash probes `/dev/tty` on
  every `sh -c`, and `utempter` writes *both* `/run/utmp` and `/var/log/wtmp` for
  every pane — granting only the first left one denial per pane forever. Both are
  Bromure's pane model, the same justification as `/dev/ptmx`.

> **`df` was not broken.** The report suggested disk usage would read 0 because
> `/` is not in the policy. Measured: `df -kP /` returns rc 0 with full output —
> it is denied the `open` but uses `statfs` for the numbers. The event was real;
> the functional consequence was not.

`tests/test_boot.sh` now boots a filesystem-policy workspace **with the sentry**,
waits for the session, and asserts **zero new `sandbox_denied` during a 60-second
idle** — separating the one-shot reads at session start (a shell reading its own
profile) from the steady drip that was the actual problem. It found three more on
its first run, of which one — `/var/log/wtmp` — was ours.

> **And then it could not run again, on this VM, because of it.** Letting
> `bromure-sentryd` do its job in a test meant letting it raise lockdown, which is
> **one-way for the life of the boot** and, at `integrity`, refuses to load an
> unsigned module. So the first run of that case was the last one this development
> VM could do: `tests/test_sentry.sh` cannot load its own build here either, until
> reboot. The same shape as the round-8 incident where a test applied the strict
> revocation to the real `/etc` and took this machine's `sudo`.
>
> Two fixes. `BROMURE_SENTRY_NO_LOCKDOWN` is a **test-only** override that
> `tests/test_boot.sh` always sets; it cannot take effect silently, because
> sentryd reports it in `sentry.json` and in the journal, and it widens nothing an
> attacker could reach (sentryd runs as root from the root script; anyone who can
> set its environment already owns the machine). And both the sentry suite and
> that boot case now **detect the lockdown state and SKIP LOUDLY** — exit 77,
> named in the summary as *"SKIPPED for environment reasons — not a pass"* —
> rather than failing obscurely or, worse, quietly reporting success for something
> they never ran.
>
> The honest consequence: the three fixes that idle run found were made but
> **not re-verified here.** That run needs a fresh VM.

#### What it costs, measured

`security_file_open` fires on **every open in the machine**, so this is a number
rather than an assurance:

| workload | no module | sentry loaded | delta |
|---|---|---|---|
| tight loop, one hot file | 792 ns/open | 1006 ns/open | **+214 ns (+27%)** |
| 8000 distinct files in a source tree | 1391 ns/open | 1613 ns/open | **+222 ns (+16%)** |

So a build doing 100k opens pays about 25 ms. The cost is the **kretprobe entry
trampoline**, not the handler: on arm64 a kretprobe is a kprobe at function entry
that hijacks the return address, and returning non-zero from the entry handler to
skip the return handler measured *identically*. That change is kept anyway,
because `maxactive` is 64 on a hook this hot and an instance recycled at entry is
one that cannot be missed.

#### The one userspace change

The filters are installed with `SECCOMP_FILTER_FLAG_LOG`. **A divergence from
OpenShell**, and a deliberate one: it changes nothing about what the filter
allows or denies, only whether the kernel says so — and without it a refused
syscall leaves no trace anywhere. It is requested best-effort, because a sandbox
that refused to install itself for want of *telemetry* would have the priorities
backwards. `bromure-sandboxd` also verifies `/proc/sys/kernel/seccomp/actions_logged`
covers the actions in use; measured as already correct on this image, so it is a
guard against an image change rather than a fix.

### 4.3c Network lineage: `net_flow`, and the chain that caused it

One event when a socket first talks to a destination — **never per packet**.
`exec` gained `argv` and `start_ns` in the same change, because the host's join
needs both halves: the flow says what left the VM, the process table says which
tool call produced it.

#### The probe points, and why nine

| probe | protocol | when |
|---|---|---|
| `tcp_connect` | TCP | after the source port is chosen, which is why `sport` is reliable |
| `udp_sendmsg`, `udpv6_sendmsg` | UDP | the first send — connected or not |
| `ping_v4_sendmsg`, `ping_v6_sendmsg` | ICMP, ICMPv6 | a ping socket's first send |
| `raw_sendmsg`, `rawv6_sendmsg` | RAW | a raw socket's first send |

#### The `connect` kind is retired

`security_socket_connect` is no longer probed and `connect` is no longer
emitted. `net_flow` reports the same connection with strictly more — the
protocol, the source port, the process's start time, the ancestor chain — and
**folds repeats**, where `connect` had no dedup at all and emitted one event per
call. That made it the noisiest kind in the module: before the loopback filter,
every `sudo` on the machine produced three of them.

It survived two rounds past being redundant because the host said it might be
feeding an attestor cross-check, and removing something another side may depend
on is not a guest-side call. Once the host confirmed nothing consumed it, the
probe, its handler and its renderer went; `BSK_CONNECT_UNUSED = 13` stays in the
ABI so the number can never come to mean something else, which is the same
convention `BSK_FILE_OPEN_DENIED_UNUSED = 14` follows. The suites assert that a
`connect()` now produces **only** a `net_flow`, and that
`security_socket_connect` is not among the registered probes — because "no
`connect` events arrived" would also be true of a probe that simply never fired.

**A datagram connect is not a packet, so it is not probed.** `connect()` on a
UDP socket only records where that socket would send if it ever sends. The first
version watched `ip4_datagram_connect`/`ip6_datagram_connect` and put rows on the
timeline for traffic that never existed — live, in the host's own Security
Timeline:

```
Network | seen | systemd → python3 → bash → ping → UDP 1.1.1.1:1025
```

iputils connects a UDP socket to `dst:1025` purely to ask the routing table
which source address it would use, and never sends a byte. Any
`getaddrinfo`-style route lookup does the same. So UDP — connected or not — is
reported on its **first send**: a connected send leaves `msg_name` NULL and the
destination comes off the socket, which the handler already reads, so nothing is
lost by not watching the connect. Measured after the change: a UDP socket that
connects and never sends hits **no probe at all**, a connect-then-send hits
`udp_sendmsg` once, and `ping -c1` hits `ping_v4_sendmsg` once and nothing else.

TCP is different and unchanged: `tcp_connect` *is* a packet — the SYN.

**Nor is a send with nowhere to go.** Removing the connect probes left the
guard below them unreachable: it tested `addr_family`, which cannot be zero once
the family has been filtered, and the `connect(AF_UNSPEC)` case it was written
for can no longer arrive. The *situation* is real, though — `send()` on an
unconnected UDP socket runs `udp_sendmsg` **before** failing with
`-EDESTADDRREQ` (measured: one probe hit, errno 89), which would emit
`dst: 0.0.0.0, dport: 0` for a packet that never left. So the guard now tests
the destination address itself, and on the address alone: ICMP and RAW
legitimately carry no destination port, so a `dport == 0` condition would have
discarded every ping.

#### The protocol label comes from the socket, not from the probe

`ip4_datagram_connect` is `udp_prot`'s connect **and** `ping_prot`'s. Measured:
a single `ping -c1` fires it twice. A static per-probe label therefore reported a
ping as `proto: "udp"`, which is simply wrong. `sentry_proto_from_sock()` asks
the socket instead and the table's label survives only as a fallback. `sk_type`
is checked before `sk_protocol`, because `socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)`
has `sk_protocol == IPPROTO_ICMP` and is still a raw socket — a different
capability that belongs in a different bucket.

**A ping socket reports its send, never its connect** — now because no datagram
connect is probed at all. While connects *were* probed this needed an explicit
guard, for two reasons worth keeping on record: the echo identifier is the local
port and the socket may not be bound at connect time, so the connect event would
carry `sport: 0`; and since the dedup key is `(pid, proto, dst, dport)`, the
connect event would *win* the slot and fold the send into it, leaving the host
the one event without the identifier. The guard is gone with the probes — an
unreachable branch in a security module is a claim nobody can check.

#### Loopback is counted, not reported

Measured over 90 s on a VM doing nothing but running one agent session: **97 hits
across every flow probe, of which 93 were datagram connects to 127.0.0.53**, the
systemd-resolved stub — three per `sudo`. Each is a different short-lived pid, so
the dedup cannot fold them; an `npm ci` would turn that into thousands of rows.
None of them can ever be joined to a switch decision, because none of them leaves
the VM. They would bury exactly the flows the feature exists to show.

So a loopback destination increments a tally and emits nothing. What that costs:
the agent's own DNS goes through the stub, so the *process → name* link via
127.0.0.53 is not reported. The name is still recoverable — systemd-resolved's
**upstream** query is a real egress flow and is reported, attributed to
`systemd-resolve` rather than to the agent — and the host snoops DNS anyway.
`flow_local=1` turns them back on, and every heartbeat carries
`flows.local_suppressed`, so the decision is a visible number rather than
something inferred from an absence. The same filter was applied to the older
`connect` kind, which needed it more: that kind has no dedup at all, so before
this every `sudo` on the machine produced three events.

This is the round-19 lesson applied before it bit: an event stream whose bulk is
the platform's own plumbing trains people to ignore it.

**One loopback destination is not plumbing: the proxy.** agentd sets
`HTTPS_PROXY=http://127.0.0.1:<proxy_port>` in every non-OpenShell workspace, so
`curl`, `npm`, `pip` and git-over-https all connect to **loopback** — and the
blanket filter swallowed every one of them. Measured live: `curl https://1.1.1.1/`
produced no flow at all. That is the exact inverse of the mistake the filter was
added to prevent; suppressing the agent's real egress while keeping noise would
be worse than keeping both.

`flow_local_ports` (a `ushort` array, up to 8) names loopback ports to report
rather than suppress, and `bromure-sentryd` sets it from `$META/proxy_port` —
**the same file agentd's `_read_proxy_port()` reads**, with the same fallbacks,
so the two cannot disagree about which port the proxy is on. The exemption is
one port, not loopback in general; the suite asserts that other loopback ports
stay suppressed, so the fix cannot quietly reopen the flood.

The destination of such a flow is the proxy, not the site, so on its own the row
reads "curl → 127.0.0.1" — true and useless. The join is `sport`: see §1.10.

**What suppressing the resolver stub actually costs, measured.** For *proxied*
traffic it costs nothing, because a proxied client does not resolve anything in
the guest at all — it hands the name to the proxy in `CONNECT`. Measured, with a
name that does not exist and a proxy that is not listening:

| | curl's error |
|---|---|
| `--proxy http://127.0.0.1:…` | `(7) Failed to connect to 127.0.0.1 port …` |
| `--noproxy '*'` | `(6) Could not resolve host: …` |

Error 7 rather than 6 is the whole point: with a proxy configured there is no
guest DNS query for that name, so there was never a stub query to attribute. The
name reaches the host from the `CONNECT` line, which the MITM already parses —
a better source than snooping would be.

It costs something only for traffic that does *not* go through the proxy — a
database client, `ssh`, git-over-ssh — where the guest does resolve through the
stub. There the host has "process → IP" from the flow and "name → IP" from
resolved's upstream query (a real egress flow, reported, attributed to
`systemd-resolve`), and joins them on address and time rather than on pid.

#### Two fields that were quietly incomplete

Found by re-reading the contract's field list against the code rather than
against memory — both had shipped for rounds.

**`path` (the exe) was always empty.** `sentry_fill_common` never set it, and
the flow handler did not either, so every `net_flow` carried `"path": ""`. The
key was *present* in the JSON, so a test that checked for the key passed; the
required-field tuple in the suite simply did not list `path`. It matters for the
case `chain` exists to cover: a process that started before the sentry loaded
has no `exec` event, so there is nothing else to resolve its binary from.

Filling it naively would have cost a `d_path` dentry walk **per packet** — which
is the per-packet cost this kind exists to avoid, since a QUIC-style workload
sends thousands of packets a second to one destination already folded into a
single event. So the exe and the ancestor chain are now resolved **lazily**:
`sentry_dedup_live()` asks, under the lock that already exists and with no
allocation, whether a slot is already holding this key, and only if none is are
either resolved. That required taking `path` out of the *flow* branch of the
dedup key — the key is computed once before the exe is filled and again inside
the absorb, and hashing `path` would make those disagree and give every flow a
slot of its own. Nothing is lost: for a flow, `pid` already determines the exe.

**`icmp_type` was always "not read".** The contract asks for it "when cheap", it
was not cheap when first written (reading the message meant a faulting copy from
a kprobe handler), and the condition changed when `sentry_copy_user_nofault`
arrived. It is one guarded byte now: a ping socket's send begins with the ICMP
header the application built, so byte 0 is the type, read through
`copy_from_user_nofault` — the raw primitive, not the string helper beside it,
because that stops at the first NUL and type 0 (echo reply) would come back as
"nothing copied", leaving the field unread for exactly the value hardest to
tell from absent.

**Ping sockets only, never raw.** A raw socket with `IP_HDRINCL` supplies the IP
header itself, so byte 0 there is version/IHL — `0x45` — which would be reported
as `icmp_type: 69`. The type is not determinable for a raw socket without
parsing a header whose presence depends on a socket option, so it stays unread
and the field is omitted. A field that is honestly absent beats one that is
confidently wrong, and the suite asserts both halves: `8` for `ping`, absent for
the raw-socket driver.

#### Dedup, and two different windows

Per `(pid, proto, dst, dport)`, folded with a `count`, in a **10 s** window —
separate from the denial window (`dedup_ms`, 1 s), because the two measure
different things: a connection is something a process does occasionally, a
denial is something it does in bursts. Sharing one parameter would have quietly
given flows the denial's 1 s.

**This paragraph was false for one round, which is worth recording.** The key
was `(kind, op, aux1, path, arg, pid)` — nothing in it distinguishes one
destination from another — so **every flow a process made in the window folded
into its first one.** It shipped documented as "(pid, proto, dst, dport)" in
this file, in a code comment, and in the handover, because the property was
written down rather than checked.

It was caught by the first live run, in a line that reads like a pass:

```
ok   ping flows to 1.1.1.1: 2 event(s) for 1 + 5 + 1 packets, folded counts [2, 6]
```

`count: 2` for `ping -c1` is the UDP source-address probe **plus** the ICMP
send, folded together. `count: 6` for `ping -c5` is that probe plus five sends.
Nothing was wrong with the probe, the socket-based label, or the
report-the-send-not-the-connect path: the ICMP event was built correctly and
then absorbed into the slot the UDP probe already held, so the only flow the
host saw was the one nobody asked about. It was never really about ping — a
process connecting to ten hosts reported one event with `count: 10`.

The key now folds in `proto`, `addr_family`, `dport` and all sixteen address
bytes (by explicit length: an address is binary and may contain NULs, and
1.1.1.1 against 1.1.1.2 differs only in the last octet). Kind-gated, so the
denial key is bit-for-bit what it was — `aux2` is a file's `f_flags` on a denial
and the destination port on a flow, and folding it in unconditionally would
have re-cut denial dedup that is already verified in the field.

Two things this cost. The comment immediately above that function already
described this exact bug class, written after a missing `aux1` merged a refused
`unshare` with a refused `setns`; the same mistake was made one field along, in
the same function, one feature later. And the test that would have caught it was
correct from the start and had **never been executed**, because this VM cannot
load the module. A suite that cannot run is not a weaker form of a suite that
passes.

The contract also asks for dedup per `(socket, destination)` for the socket's
life. That is **approximated** by the window: per-socket state would have to live
in `sk_user_data`, which belongs to the protocol. For TCP it makes no difference
— `tcp_connect` fires once per connection anyway.

#### `chain`, and `(pid, start_ns)`

`chain` is the ancestors, nearest first, up to 8: `[{pid, start_ns, comm}]`,
walked through `current->real_parent` under RCU, stopping at pid ≤ 1 and
defensively on a cycle. The host normally rebuilds the tree from `exec`; the
chain is what covers processes that started before the sentry loaded, and pid
reuse.

`start_ns` is `task->start_boottime` and is on **every** event, not only on
flows. `(pid, start_ns)` is a process's identity because pids are reused and
start times are not. `tests/test_net_flow.sh` cross-checks it against field 22 of
`/proc/<pid>/stat` — which is what proves the field is the process's start time
and not the time the event was built.

#### `argv`

Read in the exec hook from **`bprm->p`**, not from `mm->arg_start`: at
`security_bprm_committed_creds` the new mm's `arg_start` is not set yet — it is
filled later, in `create_elf_tables` — so reading from there yielded an empty
argv. NUL-separated args are joined with single spaces, capped at 1024 bytes,
with `argv_truncated` when cut. The read goes through `copy_from_user_nofault`
(see below), so it cannot fault or sleep.

#### Two things this change had to fix in the module itself

**A 1792-byte event does not belong on a kernel stack.** `argv[1024]` and
`chain[8]` took the event from 512 to 1792 bytes, and sixteen probe handlers
staged one as a local — sixteen 1808-byte frames, inside `udp_sendmsg`, inside
the LSM hooks, on a 16 KB arm64 stack already partly spent by the kprobe
trampoline. A watchdog that can overflow the stack of what it watches is worse
than no watchdog. The handlers now share a **per-CPU** staging buffer, which
needs no lock for a reason specific to this context: a kprobe handler on arm64 is
reached from the debug exception, which `debug_exception_enter()` enters with
preemption disabled, and same-CPU re-entry is refused by the kprobe framework
itself — `kprobe_breakpoint_handler()` reads the per-CPU `current_kprobe`, sees
one in flight and accounts the hit to `nmissed` rather than calling a second
`pre_handler`. So "one user per CPU" is a property of the context, not a hope,
and it stops being true anywhere else: the two sleepable emitters (the sentry
thread's drain buffer and the dedup flush) have their own storage, the flush's
under a mutex because module exit flushes *before* `kthread_stop()`. The
`memset` in `sentry_fill_common()` is load-bearing for a shared buffer rather
than incidental, so it is checked for all sixteen callers rather than assumed.
`tests/test_net_flow.sh` fails the build if a frame-size warning comes back.

**`strncpy_from_user` can sleep, and a kprobe handler cannot.** Pre-existing in
`sentry_kp_mount` and found while reading that path. `strncpy_from_user_nofault`
is not exported to modules; `copy_from_user_nofault` is, so
`sentry_copy_user_nofault()` is built on it in 32-byte chunks and both the mount
path and `argv` use it.

#### Cost

Measured as `security_file_open` was — the same loop with and without, on
loopback so nothing is hidden behind a network round trip, which makes it an
upper bound:

| | without | with | delta |
|---|---|---|---|
| TCP connect | 6301 ns | 6870 ns | +569 ns (+9.0%) |
| UDP send | 1770 ns | 1896 ns | +127 ns (+7.2%) |

Those figures are the **kprobe mechanism** on these exact symbols, measured with
tracefs kprobes because this VM cannot load the module (lockdown, §4.8).
`tests/test_net_flow.sh` repeats the measurement against the real module, loaded
and unloaded, and prints both; that is the number to quote. The percentage is
against the tightest loop the kernel will run: a connect to a real destination
costs orders of magnitude more, so the proportional cost in a workload is far
smaller. The allowed path of the hot denial hook pays nothing — the staging
buffer is claimed *after* the early returns, so an allowed `security_file_open`
does not touch it.

### 4.3d The container mark

A workspace can opt out of MITM interception for *container* traffic. That is
only offerable if the host can tell a container's packets from the guest's own,
and every label the guest could apply — an alias IP, a port range, an iptables
mark — is settable by guest root. So the sentry applies it, from a netfilter
hook outside iptables, in a module lockdown keeps loaded. **DSCP 43**
(`0b101011`, in RFC 2474's local/experimental pool, so it collides with no
standard class — EF is 46, the AF classes 10–38, CS0–7 multiples of 8).

#### "Forwarded" is the container test, measured

In a Bromure VM the guest forwards only for containers. One capture on the
egress interface, with a mangle rule standing in for the hook, a container ping
and a guest curl running together:

```
172.28.66.5 -> 1.1.1.1   DSCP 43 (tos 0xac)  x3    container, forwarded + MASQUERADEd
172.28.66.5 -> 1.1.1.1   DSCP 0  (tos 0x00)  x11   the guest's own curl
```

Three facts at once: NAT does not touch TOS, so the mark survives MASQUERADE;
the guest's own traffic is unmarked even with the hook active; and **both leave
with the same source address**, which is why a label is needed at all — after
NAT the host has nothing else to tell them apart by.

#### One hook, on POSTROUTING, and why the obvious design was wrong

The first design marked on `NF_INET_FORWARD` and cleared forgeries on
`NF_INET_LOCAL_OUT`, both at `NF_IP_PRI_LAST`. **That had a forgery hole.**
LOCAL_OUT runs *before* POSTROUTING, so root could add

```
iptables -t mangle -A POSTROUTING -j DSCP --set-dscp 43
```

which runs after the clear and stamps the mark back on its own traffic. "Last
in the chain we chose" is not the same as last.

One hook on **POSTROUTING** at `NF_IP_PRI_LAST` is after nat (priority 100) and
after every iptables rule anyone can add. It decides from the **ingress
device**, the one property of a packet iptables cannot rewrite:

| `skb_iif` | verdict |
|---|---|
| 0 — originated here | clear |
| a bridge, a bridge port, or a veth | mark |
| anything else | clear |

The device *type* check closes a second hole: **a TUN device**. Root can create
a tun, route its own traffic into it and write packets back from userspace, and
those arrive with a non-zero `skb_iif` — "forwarded" by any naive test.
Requiring a bridge or veth means the only way to earn the mark is to actually be
behind one, which is what a container is.

Measured which device: `-i docker0` in mangle FORWARD counted a container's
packets, so the IP layer sees them arrive on the **bridge**, not the veth —
hence `netif_is_bridge_master` and not only `netif_is_bridge_port`. The veth
kind is accepted too, for CNIs that wire pods with veths and no bridge.

Verified live, module loaded, all four at once: container → 43, guest → 0,
`setsockopt(IP_TOS, 0xAC)` → 0, root's mangle POSTROUTING rule → 0. For the tun,
the counters are the proof rather than a capture: `marked: 2` (only the real
container) and `forged_cleared: 6` (every injected packet stripped). A first
attempt at that test proved nothing — Docker sets `FORWARD policy DROP`, so the
tun packets never reached POSTROUTING at all, and "no marked packet on the wire"
was indistinguishable from "no packet on the wire".

#### The accusation requires the socket's own TOS

The forgery event first named whichever process sent a marked packet. With a
global mangle rule active that meant `forged_cleared: 36` and events accusing
`curl` and the coding agent itself — **neither had ever touched `IP_TOS`**. One
root rule made every process on the box look guilty, which in a security UI is
worse than no event at all.

At POSTROUTING the packet cannot say who set the field; the socket can
(`IP_TOS`/`IPV6_TCLASS` is recorded on it). So the **tally** counts every
clearing — the alarm stays complete — and the **event** fires only when the
socket itself asked for the mark. Re-measured: 24 clearings, exactly one process
named, the one that really called `setsockopt`.

The same principle governs context: the event is emitted only `in_task()`. On a
softirq — a retransmit, a delayed ACK — `current` is whatever thread was
interrupted, and naming it would accuse a process that did nothing.

#### `tc` can defeat it, so `tc` is reported

An egress qdisc action runs inside `__dev_queue_xmit`, **after** netfilter has
finished, so there is no later hook to take. Measured, with the hook active:

```
tc filter add dev enp0s1 ... action pedit ex munge ip dsfield set 0xac
guest curl -> DSCP 43 on the wire        (DSCP 0 immediately before and after)
```

This is not a priority that can be out-bid. So `BSK_TC_CHANGE` reports the
attempt instead — `tc_modify_qdisc`, `tc_new_tfilter` and `tc_ctl_action`, with
`op` ∈ {qdisc, filter, action}, the `dev` resolved from the message's
`tcm_ifindex` and the `kind` from its `TCA_KIND` attribute. The netlink message
is already kernel memory, so parsing needs no faulting copy — which is what made
`kind` cheap enough to include. Emitted unfolded and immediately, because the
host revokes the container exemption on the first one.

**Measured safe to act on**, which matters when the consequence is a revocation:
nothing on this image calls those paths legitimately — not 12 s idle, not
`docker run`, not `docker network create` with a container on that network, not
a dockerd restart. Docker attaches a veth's default qdisc without going through
tc's netlink interface. Not tested: kind/k8s, where a CNI that installs an
egress qdisc (Cilium's bandwidth manager, for one) *would* trip it.

#### The agentd half

With `$META/containers-direct` staged, `_docker_run` withholds the proxy
variables from containers so they connect out directly — otherwise they would
still reach the MITM at `host.docker.internal:65534` and the option would do
nothing while appearing to work. **dockerd's own proxy drop-in is untouched**,
deliberately: image pulls stay inspected, so the supply-chain checks still see
every layer entering the VM. Only the containers' own traffic goes direct.

Exactly six variables are withheld (`http_proxy`, `https_proxy`, `no_proxy` and
their upper-case forms); the nine CA/SSL variables are kept, since they cost
nothing unused and an image may expect the bundle for its own reasons. The
marker is read on every call rather than cached, so the host can turn the option
on or off while the workspace runs.

### 4.4 Tamper resistance

| vector | answer |
|---|---|
| kill the daemon | there isn't one; capture and transport are in-kernel |
| close the socket | the kthread's socket has no fd |
| `rmmod` | no exit function → `-EBUSY`; **and** `__module_get` holds a reference. `CONFIG_MODULE_FORCE_UNLOAD` is unset on this kernel, so there is no `rmmod -f` |
| load a module to undo it | blocked once lockdown is `integrity` |
| write kernel memory / kexec | blocked by `integrity` |
| **disarm the kprobes** | see below — this one needed real work |
| flood the channel | per-kind token bucket; drops **counted**, never silent |
| crash the VM | detectable as heartbeat silence; that is the residual risk |

### 4.5 Blinding detection — and a hole in the first answer

Reporting per-probe `kprobe_disabled()` was **not enough**, and this was caught
by measurement rather than reasoning. Writing `0` to debugfs
`kprobes/enabled` runs `disarm_all_kprobes`, which sets the file-scope
`kprobes_all_disarmed` and physically disarms every probe **without touching any
`p->flags`**. Measured: with the global switch off, every probe still reported
itself armed and no events flowed. A host trusting that count would have watched
a healthy-looking sentry go blind.

`kprobes_all_disarmed` is not exported, so the fix does not try to read kernel
state at all. The module keeps a kprobe on a `noinline` function of its own and
calls it once per heartbeat. If the counter does not move, probes are not
firing — whatever the reason, whether the global switch, ftrace, or something
not yet invented. The host then sees `canary:false` and `armed:0`.

Measured with the switch toggled mid-run: `armed seen: [0, 21]`,
`canary seen: [False, True]`.

Every heartbeat carries `probes:{armed,total,missed,canary}`; the hello carries
the full 21-entry probe list so the host knows the baseline.

### 4.6 Wire format

As contracted — `u32` big-endian length, then UTF-8 JSON — with additions:

- hello gains `abi`, `probes` (the probe list), and `landlock_abi`/`boot_id`
  passed in by the loader (the kernel gives a module neither);
- heartbeats gain `rate_limited` beside `dropped` (token-bucket drops and
  ring-full drops are different problems) and `probes` (§4.5);
- the denial kind is `file_open_denied` with a `hook` field (§4.2).

`secret` is 32 random bytes rendered as 64 hex characters.

> **Residual risk, stated plainly.** Under `integrity`, root can still read
> `/proc/kcore` with `kallsyms` addresses, so it can read the secret out of
> module memory. What that buys is limited: the kernel owns the socket, the host
> pins the first hello per boot and treats a second connection as an alarm, and
> the `sentry_digest` cross-check on 5840 catches a userland impostor. The gap is
> a **reconnect** — the module does reconnect if a send fails — where an impostor
> holding the stolen secret could race the module.
>
> **Both ways are now closed.**
>
> **(a) `requirement: hard` raises to `confidentiality`, not `integrity`.**
> Measured on the shipped image: the only differences from `integrity` are
> `kcore_read` and `tracefs_kprobe_events` going from yes to no — and **no
> workload cost at all** (docker run, an nginx pull with a published port and a
> curl through it, module autoload, virtiofs, and the sentry itself all fine).
> What it costs is kernel tracing, which is exactly what "hard" should forbid.
> `best_effort` keeps `integrity`.
>
> **(b) Only the first hello carries the secret.** Every reconnect carries
> `conn` and a `proof`:
>
> ```
> proof = sha256( <secret: 64 lowercase hex ASCII>
>               || <boot_id: ASCII, exactly as passed to the module>
>               || <conn: decimal ASCII, no padding> )
> ```
>
> concatenated with no separators and no trailing NUL, rendered as 64 lowercase
> hex. The first hello is `conn: 0` and carries `secret`; every later one carries
> `proof` and **never** repeats the secret. The host recomputes it, rejects an
> index at or below the last one seen, and treats a reconnect carrying the secret
> in the clear as tampering. Verified end to end by killing the listener and
> letting the module reconnect.
`/sys/module/bromure_sentry/parameters/secret_digest`, mode **0400**, holds
`sha256` **of that hex string** — so the host computes
`sha256(hello["secret"].encode())` with no decoding step.

### 4.7 Distribution

**A `.ko` per kernel ABI, built by CI and fetched by the host.** Not bundled with
the app, not in git, and no image bump.

A daily job builds one module for every noble `linux-headers-6.8.0-*-generic` ABI
and publishes it under a content hash of the source; the host verifies the
catalog signature, keeps a local cache, and stages into `$META/sentry/` the
modules for the kernels it knows a workspace has — under the same names as
before, `bromure_sentry-<kver>.ko`, so nothing in the guest's discovery changed.
`sentry-dist/src/` still travels with the tree for the local-rebuild fallback.

#### Telling the host which kernels exist

The host cannot know the kernel of a workspace it has never booted, nor one that
just `apt upgrade`d. So `sandbox_status` reports, **whenever the spec is active
and whether or not the sentry is enabled**:

- `sentry_kernel` — `uname -r`;
- `installed_kernels` — every kernel release installed on disk, sorted.

Reported with the sentry *off* on purpose: a workspace that switches it on
tomorrow should already have had its module prefetched, and the prefetch is the
whole point.

`installed_kernels` tests for `modules.dep`, not for a directory under
`/lib/modules`, and that is not pedantry: on this project's own development
machine `/lib/modules/6.8.0-142-generic` exists and contains nothing but a
`build` symlink, because the *headers* package is installed for a kernel that is
not. A naive glob would report a phantom kernel and have CI build a module
nothing can ever load. `/boot/vmlinuz-*` is the cross-check in the other
direction. Cached for 30 s, because attestd rebuilds the status every second and
the answer changes only when somebody runs apt.

#### Waiting for a module that does not exist yet

When there is no module for `uname -r`, the guest asks rather than compiling. It
publishes sentry status **`waiting`** — a state of its own, because the host
*acts* on it: seeing `waiting` is what makes it fetch and stage. (`pending` means
"a producer has not spoken yet"; this is "it has spoken and is blocked on the
other side".) `waiting` had to be added to `VALID_SENTRY` or the status builder
would coerce it to `off` and deadlock both sides.

The wait is bounded at 45 s. **Whether it blocks the session depends on the
policy, and that choice is the interesting part.** 45 s with no session is long
enough to trip the host's boot-phase budget; but starting the session first opens
a window in which agent code runs with nothing watching it, which is the one
thing the sentry exists to prevent. So:

| `sentry.requirement` | behaviour |
|---|---|
| `hard` | the wait is **inline**. The workspace demanded the sentry; a blind window would break that promise, and a slower boot is the honest price. |
| anything else | the wait moves to a transient unit (`bromure-sentry-await`) and the session starts now. The sentry joins when the host delivers. |

Either way the status says `waiting` immediately, so the host can both fetch and
account for the delay. The background unit runs **the same code path** — it is
this program re-entered with `--await-module` — so loading, lockdown and every
status the host reads cannot drift between the two entry points. And it resolves
its own `waiting`: on timeout it falls through to the local build and then to
`unavailable`, because a `waiting` nobody ever resolves leaves the host fetching
for ever.

**The timeout is the fallback, not the mechanism.** Measured live: on a workspace
whose kernel had no published module, the host knew within 5 s and a hard-mode
guest still waited the full 45 — the shell took 50 s for a question that had been
answered in 5. So the host writes
`$META/sentry/bromure_sentry-<kver>.unavailable`, one line saying why, as soon as
it knows, and removes it if it later stages a module. The wait ends on that
marker as well as on the `.ko`, and the host's own line goes into the reason:

    no module for 6.8.0-146-generic: the host says: no module published for
    6.8.0-146-generic yet; and building one here failed: …

which is an answer, where *"the host did not deliver one within 45s"* was a guess.
The 45 s timeout stays for a host that says **nothing** — an older app that does
not write the marker, or one that is simply gone — and its wording now says so
rather than implying a refusal.

Two orderings matter, and both are asserted:

- **the `.ko` is checked first on every pass**, so a module that arrives after
  the marker still wins. A host that said "none is coming" and then found one
  must not be held to its earlier word;
- **staleness is deliberately not guarded against.** The marker names a specific
  kernel release, so one left from an earlier boot says "there was still no
  module for *this* kernel", which is almost certainly still true — and because
  the `.ko` wins, a marker the host forgot to remove cannot mask a module that is
  there.

Lockdown is still raised only *after* a successful load, in both paths.

`sentry/build.sh` runs in CI (and still works in a guest VM by hand) and
emits `sentry-dist/bromure_sentry-<kernel-release>.ko` plus the source. (Not
under `sentry/`: kbuild's `make clean` deletes `*.ko` recursively beneath the
module directory, which ate the release artifact once.) It pins the
kernel's own compiler, `SOURCE_DATE_EPOCH` and `KBUILD_BUILD_*`, maps build
paths out of the debug info, and `--verify` builds twice and compares —
byte-identical. **An externally set `SOURCE_DATE_EPOCH` now wins**: CI builds in a
container with no git history, where `git log` returns nothing and the mtime
fallback differs per machine — unreproducible exactly where reproducibility is
being claimed. The caller knows the commit it is building; this must not overrule
it. It also **refuses to ship a module built with
`BROMURE_SENTRY_TESTABLE`**, so a testable build cannot reach users.

Naming the file by kernel release means a guest that has apt-upgraded its kernel
never silently loads a mismatched module. For that case `bromure-sentryd` falls
back to building locally from the staged source, installing
`linux-headers-$(uname -r)` if needed. That is the fallback and not the default
deliberately: making every first boot pay for an apt install and a compile, and
fail without network, is a bad trade for a case most workspaces never hit.

If neither works, the loader reports `sentry: unavailable` with a reason and
**never crash-loops**. Whether that blocks agent sessions is
`sentry.requirement`, and it is the host's decision.

### 4.8 Load order, which is one-way

```
insmod (unsigned, allowed because lockdown is still none)
   ↓
read /sys/module/bromure_sentry/parameters/secret_digest
   ↓
echo integrity > /sys/kernel/security/lockdown     <- irreversible for this boot
```

Under `integrity` the kernel demands a valid signature for every module, and
ours is not signed by a key the kernel trusts. **A sentry not loaded before
lockdown cannot be loaded at all this boot.**

---

## 5. Lockdown: measured cost

`tests/test_lockdown.sh` probes ~20 surfaces, optionally raises lockdown, and
re-probes. It does **not** raise without `--raise`, because that is one-way for
the boot.

Before lockdown, the surfaces that matter:

| surface | state |
|---|---|
| `kprobes/enabled` writable | **yes** (the blinding vector; §4.4 detects it) |
| tracefs `kprobe_events` writable | **yes** |
| `kernel.ftrace_enabled` writable | yes |
| unsigned `insmod` | yes |
| signed `modprobe` | yes |
| `/proc/kcore` readable | yes |
| `/dev/mem` readable | no (`CONFIG_STRICT_DEVMEM`) |
| virtiofs, vsock, docker, k3s modules, iptables | all working |

**Decision: `sentry.requirement: hard` raises to `confidentiality`; anything
else raises to `integrity`.** Confidentiality's only measured differences are
`kcore_read` and `tracefs_kprobe_events` going from yes to no, at no workload
cost — so it closes the one real residual (root reading the hello secret out of
module memory) in exchange for kernel tracing, which is what "hard" should mean.

**After `integrity`**, measured on the shipped image (6.8.0-142-generic,
lockdown raised by sentryd, `sig_enforce` N):

| surface | before | after |
|---|---|---|
| unsigned `insmod` | yes | **no** |
| `perf_event_open` | yes | **no** |
| `bpf` prog load | no | no |
| `/dev/mem` | no | no |
| debugfs `kprobes/enabled` write | yes | **no** |
| tracefs `kprobe_events` write | yes | yes |
| tracefs `events/kprobes/` dir | no | no |
| `kernel.ftrace_enabled` write | yes | yes |
| `kernel.kptr_restrict`, `perf_event_paranoid` | yes | yes |
| `/proc/kcore`, `/proc/kallsyms` addresses | yes | yes |
| signed `modprobe`, docker module autoload, k3s modules | yes | **yes** |
| docker run, iptables, virtiofs, vsock | yes | **yes** |

Workloads verified under `integrity`: `docker run hello-world`, an alpine
container with apk over the network, `overlay`/`br_netfilter` autoload, and the
virtiofs meta and outbox shares. **`integrity` costs no workload Bromure cares
about**, which is what makes it worth raising unconditionally.

Three rows in that table are surfaces root still has, and all three were chased
down rather than left as question marks:

- **`kernel.ftrace_enabled=0`** would silently disarm any ftrace-based kprobe.
  On this kernel none are: `CONFIG_KPROBES_ON_FTRACE` is not set, no probe in
  `kprobes/list` carries the `[FTRACE]` marker, and writing `0` left every event
  flowing with the canary true. That is a kernel CONFIG away from changing, so
  the module reports `probes.ftrace` in every heartbeat — the host can alarm if
  it is ever non-zero instead of relying on someone else's build options.
- **tracefs `kprobe_events`** lets root register its own probes. Measured: a
  competing `p:` kprobe *and* an `r:` kretprobe on `commit_creds` left our events
  entirely intact, and trying to remove ours by name fails with `EIO` — tracefs
  can only remove tracefs-owned probes. Tracefs probes cannot alter control flow,
  so they cannot suppress or forge anything.
- **`/proc/kcore` + `kallsyms`** let root read the hello secret out of module
  memory. This is the one real residual, and §4.6 says what it does and does not
  buy an attacker.

---

## 6. What ships, and what needs the image

| file | ships via | image bump |
|---|---|---|
| `bromure_openshell.py` | meta share | no |
| `bromure_idmap.py` | meta share | no |
| `bromure-sandboxd` | meta share | no |
| `bromure-sentryd` | meta share | no |
| `bromure_sandbox_status.py` | meta share | no |
| `sentry-dist/` (the .ko + `src/`) | meta share | no |
| agentd / attestd edits (`PATCHES.md`) | meta share | no |

**Nothing needs an image bump.** The one thing that would have — `lsm=…,bpf` for
BPF-LSM — is off the critical path (§4.1). It remains the only way to attribute
a denial to Landlock specifically (§4.2), so it is worth raising with the user
on its own merits, but nothing here waits on it.

---

## 7. Tests

| | what it covers |
|---|---|
| `differential/diff.py` | 1845 probe comparisons against OpenShell's real crates, 0 differences |
| `tests/test_sandbox.sh` | all three configurations — sentry-only, Landlock-without-strict, and strict — observed from inside real panes; privilege drop; hard_requirement fails closed; best_effort degrades; absent sections are no-ops; the status line's shape; **the post-revocation path with sudo stubbed to fail; the escape route; the control socket's peer check; no auto-restart; the confused-deputy payloads** |
| `tests/test_sentry.sh` | build, load, stream, framing, seq continuity, heartbeats, drop counters, probe health, the blinding canary, `secret_digest` mode and preimage, refcount unload refusal, clean teardown |
| `tests/vsock_sink.py` | stands in for the host's 5841 listener and runs the host's own checks |
| `tests/test_strict.sh` | the revocation leaves /etc byte-identical, twice over |
| `tests/test_boot.sh` | the real agentd main(), booted twice, for all three configurations |
| `tests/test_idmap.py` | idmapped mount remap, namespace privacy, honest degradation |
| `tests/test_sandbox.sh` §26 | the HTTP bridge's client preamble, over a **real** vsock on `VMADDR_CID_LOCAL`: the exact line, the newline and version, docker peers, the kill switch, a malformed `accept()` address, that it is the first thing the host reads and the client's bytes follow it byte for byte, that ssh is *not* prefixed, and that sentryd and agentd read the same proxy port from the same file |
| `tests/test_net_flow.sh` | **fresh VM only.** Drives `ping`, a bound ping socket with a known echo id, a raw-socket echo request, `curl`, a bare TCP connect, connected and unconnected UDP, `dig`/`nc` when installed, IPv6 when routable — and asserts a `net_flow` for each whose `chain` names the shell that spawned it. Also: no event per packet, loopback counted not emitted, a ping socket reporting its send rather than its connect, `argv` and its truncation flag, `start_ns` against `/proc`, chain order and depth, no stack-frame warning in the build, and the per-connect/send cost with the module loaded against unloaded. Since the first live run it also asserts that **one process's three destinations are three events** (the dedup-key regression), that a proxied `curl` to loopback *is* reported while every other loopback port stays suppressed, and that `ping`'s own UDP source-address probe is reported as what it is rather than treated as a mislabel |
| `tests/test_container_mark.sh` | **needs a loadable module and docker.** The mark on a container's traffic and its absence on the guest's; three forgery paths (`IP_TOS`, a mangle POSTROUTING rule, a tun-injected packet) each ending at DSCP 0; `tc` qdisc/filter changes each producing one `tc_change` with its `dev` and `kind`, and `docker run`/`network create` producing none; the hello's `container_mark` and tc probes; that no innocent process is accused; and agentd's `containers-direct` handling, including that dockerd's own proxy survives |
| `tests/test_lockdown.sh` | before/after table for ~20 kernel surfaces |

### Not proven by execution

**Loading the shipped module.** My sandbox refuses `insmod` of a module that by
design cannot be unloaded, on the grounds that it is irreversible for this VM —
a fair call, and @openshell will prove it on a disposable VM during the
end-to-end run. Everything testable is covered by a `BROMURE_SENTRY_TESTABLE`
build flag that compiles in an exit path (`build.sh` never defines it,
`tests/test_sentry.sh` always does), so all sentry results above are from
identical code with teardown added. The unload refusal itself is covered in two
halves:

- the **refcount** half is executed, reversibly: a test-only `pin` parameter
  performs the same `__module_get` and can release it again. `rmmod` refuses
  while it is held (`refcnt: 1`) and succeeds after unpinning;
- the **no-exit-function** half is a kernel invariant (`kernel/module/main.c`
  refuses a module with no exit routine unless forced), and this kernel has
  `CONFIG_MODULE_FORCE_UNLOAD` unset so there is no forcing path. The test
  asserts that config.

**Lockdown's "after" column** (§5), for the reason stated where it appears.

**Virtiofs idmapping is no longer open — it was measured** (§1.12), and both
results contradicted what this file previously inferred: virtiofs cannot be
idmapped on this kernel, *and* it does not enforce the guest's DAC, so the
problem the idmap was meant to solve for shares does not exist. What remains
open there is host-side only: the **ownership macOS sees** for a file the
sandbox creates in a share. The guest reports uid 1000 through the share; only
the host can say what that is on the other side.
