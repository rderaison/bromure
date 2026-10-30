# Kernel sentry on x86_64 (Linux/KVM hosts)

The module source is shared (`scripts/openshell-guest/sentry/`). Its arch-specific facts are three macros: `SENTRY_SYS`, `SENTRY_ARG` and `SENTRY_USER_ARG`. This directory holds what checked the port.

## arm64 is unchanged

```bash
linux/sentry/arm64-identical.sh <ref before the port> [ref|WORKTREE]
```

This cross-builds both sources for arm64 `6.8.0-147-generic` on an x86_64 host and compares the stripped modules. It needs `gcc-13-aarch64-linux-gnu`, and it fetches Ubuntu's arm64 headers into a scratch directory. It never installs them.

With line numbers matched, the old and new modules differ only in `srcversion` and the build-id. The disassembly with relocations is identical, and so is every data section.

## x86_64, measured (6.8.0-147-generic, a guest of `bromure-ac image bake`)

How it was run:

- A daemon VM (q35, 8 vCPU, 8 GiB, passt at MTU 65520).
- The suites were staged into the meta share with the repo layout (`scripts/openshell-guest/` plus `Sources/AgentCoding/Resources/vm-setup/`).
- `linux-headers-$(uname -r)` was installed in the guest. Ubuntu's own gcc-13 13.3.0 is already there.

| suite | result |
|---|---|
| `sentry/build.sh --verify` | reproducible (two builds agree) |
| `test_sentry.sh` | all pass. 43/43 probes armed. Every alarm-class probe fires: exec, cred_gain, module_load, sandbox_denied, seccomp_denied, unshare, setns, mount, ptrace |
| bpf_load, kexec_attempt, lockdown_change_attempt | driven by hand. All fire with decoded arguments (bpf cmd 5 / prog_type 1; `__x64_sys_kexec_load`; result -1 lowering) |
| `test_syscall_table.py`, `test_attestd_identity.py`, `test_idmap.py`, `test_strict.sh` | pass |
| `test_sandbox.sh` | 244/244 pass (after the per-arch numbers and the sentry-hold catch-up) |
| `test_net_flow.sh` | everything that ran passes. IPv6 is skipped (the image disables it) |
| `test_boot.sh` | sentry-only, Landlock-only, strict, landlock+sentry idled, strict-only, strict+network-only: pass, both directly and through `vm exec` over vsock 5800. **`run_as_user: sandbox`: fails on the Linux host** (see below) |
| `test_lockdown.sh --raise` | before/after table recorded. Raising to integrity stops `/dev/mem`, unsigned modules and the kprobes switch |

`ia32_emulation=0` (setup.sh on amd64, and the bake's cmdline): a getpid through `int 0x80` returns the pid without it, and dies with SIGSEGV with it. The sentry probes only `__x64_sys_*`, so this is the 32-bit entry it would otherwise miss.

## Open on the Linux host (not arch)

- **The idmapped home: done.** The daemon now attaches a per-VM `home.img` as vdb, and agentd mounts it at `/home/ubuntu`. `test_boot.sh`'s `run_as_user` configs take the idmap path: HOME=/home/ubuntu, and a file the workload writes is uid 999 inside and uid 1000 on disk.
- **`run_as_user` and the shares: open.** The guest enforces DAC on virtiofs (virtio_fs mounts with `default_permissions`), so uid 999 can't use shares owned by uid 1000. That's 3 checks in each of the two `run_as_user` configs, and the only failures left there. The options are in `linux/VIRTIOFS_DAC.md`, for a decision.
- One SKIP remains in those configs, "nothing seeded in /home/ubuntu": the Linux daemon doesn't stage `meta/home-seed` yet.
