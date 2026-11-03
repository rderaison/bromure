# Guest-side drop: OpenShell `filesystem_policy` / `landlock` / `process` + kernel sentry

Everything here lands under `Sources/AgentCoding/Resources/vm-setup/` and ships
through the read-only meta share. **Nothing needs an image bump.**

Read `DESIGN.md` first — it answers the contract's §1 design questions, lists
every divergence from OpenShell with its reason, and says what was measured
versus what was not.

## Layout

```
vm-setup/
  DESIGN.md                    the design note (start here)
  PATCHES.md                   what changed in agentd/attestd, and one open question for the host
  README.md                    this file

  bromure_openshell.py         OpenShell's enforcement, in Python/ctypes
  bromure_idmap.py             idmapped mounts, for run_as_user != the workspace uid
  bromure_sandbox_status.py    the sandbox_status line attestd sends on 5840
  bromure-sandboxd             persistent root supervisor; the ONLY thing that
                               can start the tmux server (DESIGN.md §1.4)
  bromure-sentryd              loads the kernel sentry, then raises lockdown
  bromure-strict.py            the strict sandbox's privilege revocation, as
                               bind mounts from /run — it writes nothing to disk

  patched/
    bromure-agentd.py          PATCHED, ready to ship
    bromure-attestd.py         PATCHED, ready to ship
  diffs/
    bromure-agentd.py.diff     unified diff vs the bundle's copy
    bromure-attestd.py.diff    unified diff vs the bundle's copy

  sentry/
    bromure_sentry.c/.h        the module
    Makefile
    build.sh                   reproducible release build; refuses to ship a testable build
  sentry-dist/src/             module source, staged for the rebuild fallback
                               (the .ko files are built by CI and fetched by the
                               host now, not bundled — see DESIGN.md §4.7)
    bromure_sentry-6.8.0-139-generic.ko           one .ko PER IMAGE KERNEL
    bromure_sentry-6.8.0-139-generic.txt          kernel, vermagic, headers pkg, compiler, sha256
    bromure_sentry-6.8.0-139-generic.build.log
    bromure_sentry-6.8.0-142-generic.ko
    bromure_sentry-6.8.0-142-generic.txt
    bromure_sentry-6.8.0-142-generic.build.log
    src/                                          for the on-guest rebuild fallback

  differential/                Rust harness linking OpenShell's real crates
    src/main.rs
    diff.py                    feeds identical jobs to both sides and compares

  tests/
    run_all.sh                 everything except the one-way lockdown raise
    test_boot.sh               the two-incarnation boot, for all three configs
    test_strict.sh             the revocation leaves /etc byte-identical
    test_syscall_table.py      every hardcoded syscall number vs <asm/unistd.h>
    test_sandbox.sh            full root launch probed from inside real panes, plus
                               the post-revocation path, the escape route, the
                               control socket's peer check and no-auto-restart
    test_sentry.sh             build, load, stream, tamper, teardown
    test_idmap.py              idmapped mount remap and its degradation path
    test_lockdown.sh           kernel surfaces before/after lockdown (--raise is one-way)
    vsock_sink.py              stands in for the host's 5841 listener
```

## Staging

| meta share path | from |
|---|---|
| `bromure-agentd.py` | `patched/bromure-agentd.py` |
| `bromure-attestd.py` | `patched/bromure-attestd.py` |
| `bromure_openshell.py`, `bromure_idmap.py`, `bromure_sandbox_status.py` | as-is |
| `bromure-sandboxd`, `bromure-sentryd`, `bromure-strict.py` | as-is |
| `sentry/` | `sentry-dist/` |

**One host-side change is required**: start attestd whenever
`openshell-sandbox.json` exists, not only under the strict sandbox. See
PATCHES.md.

**Runtime layout** (created and verified by the supervisor; it refuses to run if
this is not exactly right, because the escape analysis in DESIGN.md §1.4 depends
on it):

```
/run/bromure-sandbox/                  root:root          0755
/run/bromure-sandbox/ctl.sock          root:<workspace>   0660
/run/bromure-sandbox/server/           root:bromure-tmux  0771
/run/bromure-sandbox/server/tmux.sock  <workload>         0600
```

`bromure-tmux` is a system group that must have **no members in /etc/group**.

## Running the tests in a guest

```sh
sudo apt-get install -y linux-headers-$(uname -r) build-essential
(cd differential && cargo build --release)     # needs rustc >= 1.77
tests/run_all.sh
```

## Adding a kernel to the release pipeline

`sentry-dist/` holds one `.ko` per image kernel and the host stages all of them;
`bromure-sentryd` picks the one matching `$(uname -r)`. So a new base image is
additive and never invalidates the old one:

```sh
sudo apt-get install -y linux-headers-<kver>
sentry/build.sh <kver> --verify        # two builds, compared byte for byte
```

The kernel does **not** have to be the running one — only its headers have to be
installed. `--verify` proves reproducibility, and the `.txt` records the exact
`linux-headers` package version, the compiler, and the sha256, so the pipeline
can say which build shipped.

**Build the `.ko` before publishing the image.** The first end-to-end run shipped
an image on `6.8.0-142-generic` with only a `-139` module staged, and the sentry
was `unavailable` for every user. The on-guest rebuild fallback does not save you
there: it runs apt through the workspace's egress policy and without an
`apt-get update`, so it usually fails with "has no installation candidate".

`tests/test_lockdown.sh --raise` is deliberately not in `run_all.sh`: raising
lockdown is one-way for the boot and, once raised, no unsigned module loads, so
it would break `test_sentry.sh` for every later run. Run it last, on a VM you
can reboot.
