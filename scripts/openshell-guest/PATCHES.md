# Patches to `bromure-agentd.py` and `bromure-attestd.py`

**These are applied.** `patched/bromure-agentd.py` and
`patched/bromure-attestd.py` are the edited files, ready to drop into
`Sources/AgentCoding/Resources/vm-setup/`; `diffs/*.diff` are unified diffs
against the copies sent in the bundle. Both files ship through the meta share,
so no image rebuild.

`setup.sh` is **unchanged** — nothing here needs the image.

Everything below is inert on a workspace whose host stages no
`openshell-sandbox.json`: every hook checks for that file first and returns.

---

## What changed, and why

### `bromure-attestd.py`

1. **A status watcher thread.** attestd already runs as root before any agent
   code and already owns the one connection the host accepts on 5840, so
   nothing the agent can run can forge or suppress what it says. The thread
   polls the two status files once a second and pushes an unsolicited
   `sandbox_status` line on connect and on every change (change measured by
   `bromure_sandbox_status.fingerprint`, which ignores cosmetic churn such as
   warning ordering).

2. **A send lock.** The channel now has two writers — request replies and
   unsolicited status. Interleaved JSON on a line-delimited channel is a parse
   error on the host, which looks exactly like a compromised guest.

3. **A `sandbox_status` op**, so a host that reconnects can ask for the current
   picture rather than waiting for something to change.

> **attestd must now be started whenever `openshell-sandbox.json` exists**, not
> only under the strict sandbox. Today `task_strict_sandbox` is the only thing
> that starts it. Without this change a workspace with an OpenShell policy and
> no strict sandbox has no way to report its own status. This is the one change
> that belongs on the host side of the staging logic.

### `bromure-agentd.py`

Two of these exist because review found bugs in the first version; both are
called out so they are not quietly reintroduced.

0. **`task_openshell_root_helpers` starts attestd, sentryd and sandboxd — in
   that order — for a workspace WITHOUT the strict sandbox.** *(Found in the
   first end-to-end run.)* attestd used to be started only by
   `task_strict_sandbox`, so a workspace that merely switched the kernel sentry
   on ran with **no attestor at all**: the host received no `sandbox_status`,
   never ran its cross-check, and had no "Guest sandbox" row. attestd goes first
   because it owns the only channel for that status. Its binary-identity answers
   are not trustworthy without strict — the agent still has sudo — but the host
   only enforces binaries under strict, and status is what it needs here.

1. **`task_strict_sandbox`'s root script now starts every root helper —
   attestd, `bromure-sentryd` and `bromure-sandboxd` — BEFORE writing the
   revocation.** *(Blocker found in review.)* The first version started
   sandboxd from a task that runs on the post-revocation restart, with
   `sudo -n`. By then `ubuntu ALL=(ALL) !ALL` is in place, so **every strict
   workspace with an OpenShell policy would have got no session at all** — and
   strict is precisely the configuration the process layer requires. Nothing
   needs sudo after the revocation now; `tests/test_sandbox.sh` §8 runs the
   whole post-revocation path with `sudo` stubbed to fail.

2. **`task_openshell_sandbox` no longer launches anything under strict.** It
   starts the supervisor with `sudo -n systemd-run … -p Restart=always` only
   when there is no strict sandbox (so sudo still exists) and no supervisor yet.
   Otherwise it waits for `ctl.sock`, reads `status.json`, and logs. Every later
   agentd restart — upgrade, crash — takes the same path and needs no sudo.

3. **`session_monitor_service` falls back to the supervisor for poweroff.**
   *(Found in the first end-to-end run.)* It powers the VM off with
   `sudo poweroff`, and strict has revoked sudo — so that call failed silently,
   the VM stayed up after the user closed their last window, and a restarted
   agentd then asked for a session and resurrected a workspace they had
   finished with. It now tries sudo first and asks the supervisor if that fails.
   Not new authority: agentd did exactly this before strict existed.

3g. **`_sys_capture(args, reason)`**, new: Bromure's own status loops run as
   agentd, not as the workload. `_capture` routed everything through `_ws_run`,
   so `df -kP /`, the docker polls and `ss` executed inside the sandbox and were
   denied every couple of seconds — 33 of the first 59 timeline rows after a
   boot. The bar for using it is that the command's behaviour cannot be
   influenced by workspace content; `git` and `tmux` stay on `_ws_run`. The
   `reason` is mandatory and logged once per reason, so every escape is
   greppable and a two-second loop does not become its own noise.

3h. **The privileged `ss` runs only when the socket set changes.** `sudo` is
   setuid root, so `sudo -n ss -tulnpH` every three seconds was a `cred_gain`
   every three seconds. The unprivileged snapshot is taken every time; the
   privileged one fills in the system daemons when the set actually moves.

3f. **attestd imports the status builder lazily.** It lives in the meta share
   beside attestd, the host may stage it later, and a spec-less workspace never
   needs it — so a module-scope import made it a *startup dependency* and an
   ImportError killed attestd before it opened 5840. Answering `who` is the
   first job; building `sandbox_status` is the second; nothing from the second
   may sit on the path to the first.

3e. **attestd is startable, testable and unkillable.** `HOST_CID` takes
   `BROMURE_HOST_CID` (it was hardcoded to 2, so no boot test could ever
   exercise the attestor); the root script's `systemd-run` line gains
   `%(setenv)s`, `systemctl reset-failed` and `StartLimitIntervalSec=0`, which
   sandboxd already had; `load_secret()` moves inside the retry loop; and the
   loop catches every exception rather than only `OSError`. Without the
   attestor the host fails closed on every binary rule, so staying up is a
   correctness property.

3c. **`task_openshell_advisor_host`**, new. Writes `192.0.2.254 policy.local`
   into `/etc/hosts` — after `task_apply_hostname` (which rewrites the file
   wholesale) and before the strict revocation (after which there is no sudo),
   idempotently, on every boot, and removed again when the host says there is no
   advisor. Triggered by `$META/advisor.json` **or** the spec's `advisor` block:
   a policy that is all network rules has no spec and still needs the mapping,
   and accepting both signals means neither deploy ordering breaks a workspace. `BROMURE_HOSTS_FILE` redirects it for tests, which is not optional:
   a test that edits the real `/etc/hosts` can stop the machine resolving its
   own name.

3d. **`_ws_run` / `_ws_popen` supply the CA-trust variables.** A confined exec
   reads neither `/etc/profile.d` nor `/etc/environment`, so with `proxy.env`
   gone from OpenShell-policy workspaces the CA paths had no carrier — and the
   failure is partial (curl fine, node and python-requests not), which is the
   hardest kind to attribute. Filtered to files that exist, because
   `REQUESTS_CA_BUNDLE` naming a missing path makes requests raise.

3b. **The proxy preludes use `META`, not a hardcoded `/mnt/bromure-meta`.** Every
   host exec is prefixed with `if [ -r <meta>/proxy.env ]; then . …; fi`. The
   supervisor grants the meta share to Landlock *at the path it was told about*,
   so a prelude naming a different path is denied on `open` — while `[ -r ]` still
   says yes, because Landlock (ABI 4) hooks `file_open` and not `access(2)`. In
   production the two paths are the same string and nothing changes; the point is
   that they can no longer disagree. Found by the first test that drove
   `vm exec` over vsock instead of calling `_ws_run` in-process.

4. **`_tmux_argv()`**, and every `tmux` invocation routed through it. A tmux
   *client* will start a server itself for any command carrying
   `CMD_STARTSERVER` — not just `new-session` — so every call site has to point
   at the sandbox's socket, where the directory permissions make that fail
   cleanly.

4b. **`_tmux_client()` / `_tmux_uid_mismatch()`, because tmux refuses a
   cross-uid client.** The check is in the *server*, on accept, against the peer
   credentials the kernel reports — so no socket ownership or mode can satisfy
   it. Measured on tmux 3.4: a `0666` socket chowned to the client's own uid is
   still answered with `access not allowed`. So when a `process` policy names a
   `run_as_user` that is not the workspace user, every tmux **client** command
   goes through the supervisor's `exec` op and runs as the server's uid.

   And `_tmux_ok` reads **stderr** rather than trusting the exit status, because
   `has-session` prints that refusal and **exits 0**. That is what made this cost
   a shipping round: agentd's "is there a session?" probe reported a healthy
   session on a workspace that had none, so it never created one and never sent
   `session_ready`. See DESIGN.md §1.12.

5. **`ensure_sandbox_server()` and the control socket.** agentd cannot create a
   server (by construction, DESIGN.md §1.4), so it asks the supervisor over
   `/run/bromure-sandbox/ctl.sock` and waits. Called on session startup, on a
   host attach, and on a new tab.

6. **The view-attach string loses its `|| tmux new-session` fallback under a
   sandbox.** *(Escape found in review.)* That string runs in agentd's tree,
   **outside** the sandbox. With the sandboxed server gone — the agent can run
   `tmux kill-server` on its own server — the fallback would create an
   **unsandboxed** server on the sandbox's own socket, and a process the agent
   left running could then `send-keys` into its panes. It is now
   `has-session || exit 1`, with agentd asking the supervisor first.

7. **`create_session` never creates a server under a sandbox.** It asks, waits,
   and if none appears it stops. An unsandboxed session is worse than none.

8. **Failure does not exit.** An earlier draft raised `SystemExit(75)` on a
   failed launch, mirroring `task_strict_sandbox`. agentd is `Restart=always`,
   so that would crash-loop the workspace forever on a policy the user can only
   fix from the host. It logs instead and lets (7) refuse.

9. **`_ws_run` / `_ws_popen` / `_SandboxPty`, and every workspace command
   routed through them.** *(Confused-deputy family found in review.)* agentd is
   unconfined and executes things the agent controls through files: `bash -l`
   sources an agent-writable `~/.bashrc`; `git -C <workdir>` obeys an
   agent-controlled `core.fsmonitor`, `core.hooksPath`, filters and hooks;
   `vm exec`, `npm install` and the plan driver all run workspace content.
   Under a sandbox these now go through the supervisor's `exec` op and run
   inside the ruleset. Every `git` also gets `GIT_CONFIG_NOSYSTEM=1`,
   `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS=/bin/false` and
   `-c core.fsmonitor= -c core.hooksPath=/dev/null -c protocol.file.allow=never
   -c core.sshCommand=/bin/false -c diff.external= -c credential.helper=`
   **regardless of sandbox** — defense in depth, not instead of. See DESIGN.md
   §1.5.

   A refusal is also **reported** rather than swallowed, and with a distinct exit
   code. `_ws_run` used to turn "the supervisor did not answer" into exit 127 with
   empty output, which is how a `ctl.sock` agentd could not connect to presented
   as `command not found` for every command including `/bin/echo`. Now
   `_sandbox_exec` carries the errno, the reason lands on the caller's stderr
   (prefixed `bromure sandbox: `), in the journal, and in the pane when a pane
   fails to start — and the exit code is **126**, so a support log can tell "the
   sandbox could not run it" from "the command was not found".

   `_ws_run` **fails closed**: a keyword it cannot route into the sandbox raises
   `SandboxRoutingError` and does not execute. Two earlier versions got this
   wrong in the same direction — the first fell back to unconfined silently, the
   second logged and still ran — and both meant a future call site passing an
   ordinary keyword would have run workspace content outside the ruleset.
   Raising is the only version where the person who introduces the problem is
   the person who sees it.

   Anything that genuinely must run unconfined goes through
   **`_run_unconfined(args, reason=…)`** — named, grep-able, mandatory reason,
   logged once when a sandbox is active. The four docker call sites use it.

10. **No `TMUX_TMPDIR`.** An earlier draft exported it so panes could find the
   server. tmux already puts the socket path in `$TMUX` for every pane, and a
   tmpdir would only add a second, guessable socket location for something to
   bind at.

---

## One thing left for the host side to decide

`_run_interactive` runs a host-supplied `cmd` on a fresh pty in **agentd's**
process tree, not in the tmux server's — so a host-initiated `vm exec` is
**outside the sandbox**.

That is not reachable by the agent: the sandboxed tree cannot open `AF_VSOCK`
(the seccomp filter blocks the domain), so it cannot drive that path. It is the
host's own channel. But it does mean `vm exec` and a pane see different
filesystems under a `filesystem_policy`, which will confuse somebody eventually.

If you want them to match, route `_run_interactive`'s `cmd` through
`tmux new-window` on the sandboxed socket when `_SANDBOX.get("tmux_socket")` is
set. I have not made that change: it alters the semantics of a host-facing API
(exit codes, pty ownership, what happens when the command outlives the client)
and that is your call, not mine.

---

## What ships where

| file | ships via | needs an image bump |
|---|---|---|
| `bromure_openshell.py` | meta share | no |
| `bromure_idmap.py` | meta share | no |
| `bromure_sandbox_status.py` | meta share | no |
| `bromure-sandboxd` | meta share | no |
| `bromure-sentryd` | meta share | no |
| `bromure-strict.py` | meta share | no |
| `sentry-dist/bromure_sentry-<kver>.ko` | meta share | no |
| `sentry-dist/src/` (module source, for the rebuild fallback) | meta share | no |
| `patched/bromure-agentd.py` | meta share | no |
| `patched/bromure-attestd.py` | meta share | no |
| `setup.sh` | unchanged | — |

**Nothing needs an image bump.** The kernel already has
`CONFIG_SECURITY_LANDLOCK` (ABI 4), `CONFIG_KPROBES`,
`CONFIG_SECURITY_LOCKDOWN_LSM`, `CONFIG_MODULE_UNLOAD` without
`CONFIG_MODULE_FORCE_UNLOAD`, and vsock. The one thing that *would* have needed
one — `lsm=…,bpf` for BPF-LSM — is off the critical path; see DESIGN.md §4.1.
