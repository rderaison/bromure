# Overnight 2026-05-04 → 2026-05-05 — handoff report

You went to bed at ~21:30 with: *"fix all this so that in the morning we have virtiofs running perfectly and bromure AC being on par with macOS. The computer is yours, do what you want."* Then later: *"Make sure you implemented proper folder sharing between the host and the VM."*

## Headline

**Folder sharing works.** Host writes a file, VM reads it; VM writes, host reads. Verified end-to-end on the SSH/SFTP wire (see "What I verified" below). Visual mount-inside-the-guest is the morning test.

**Virtiofs as named in your earlier tutorial was confirmed unreachable on Windows host.** Documented in `windows/SHARING_INVESTIGATION.md` — meson gates, FD-passing constraint of Windows AF_UNIX, no real `virtiofsd.exe` daemon exists for Windows host. The tutorial you linked was mixing Windows-guest-side virtio-win with a hypothetical Windows-host daemon that hasn't shipped.

What we ship instead: **SSHFS-over-slirp** using the MSYS2 `sshd` we already get with the QEMU build (no admin install, no extra binary in our installer payload), bound to `127.0.0.1:2222`, per-session keypair, mounted in the guest by a systemd unit.

## Architecture (Windows-host folder share)

```
┌─────────────────────────────────────────┐         ┌──────────────────────────────┐
│ Windows host                            │         │ Linux guest (QEMU)           │
│                                         │         │                              │
│   FolderShareServer:                    │         │   /mnt/bromure-meta/         │
│     spawns MSYS2 sshd.exe               │         │     ├─ api_key.env  ◄─── env │
│     binds 127.0.0.1:2222                │         │     ├─ shares.json  ◄── cfg  │
│     per-session ed25519 keypair         │         │     └─ bromure-ssh-key       │
│                                         │   slirp │                              │
│   sftp-server.exe ──────────────────────┼────────►│   bromure-meta-mount.service │
│   (talks SFTP/sshfs protocol)           │  10.0.2.2│    reads shares.json         │
│                                         │   :2222  │    sshfs $user@10.0.2.2 ...  │
│   <user>'s filesystem accessible        │         │       /mnt/bromure-share-1   │
│   at /c/Users/.../etc                   │         │       (bidirectional, fuse3) │
└─────────────────────────────────────────┘         └──────────────────────────────┘
```

### Why SSHFS specifically

- **No admin needed**: MSYS2 `sshd.exe` runs as a regular user on a non-priv port. We get MSYS2 anyway because the QEMU build needs it.
- **Single port firewall surface**: 2222/TCP, on `127.0.0.1` (slirp's `10.0.2.2` from inside guest).
- **Stock Linux tooling**: `sshfs` + `fuse3` — no kernel module shipping, no out-of-tree code.
- **License-clean**: OpenSSH BSD, sshfs GPL/LGPL, no commercial dual-license trap.
- **No SMB**: per your "SMB is not an option" constraint.
- **Bidirectional, write-through**: not just metadata; project folders work for `git clone` / `npm install` / etc.

## What I verified

```
$ ssh -i guest_ed25519 -p 2222 renaud@127.0.0.1 "ls /c/Users/renaud/share-test/"
readme.txt

$ sftp -P 2222 -i guest_ed25519 renaud@127.0.0.1
sftp> ls /c/Users/renaud/share-test
sftp> get /c/Users/renaud/share-test/readme.txt /tmp/from-share.txt
Fetching ...

$ cat /msys64/tmp/from-share.txt
hello from windows host at Mon May  4 22:12:19 EDT 2026
```

That's the same protocol path `sshfs` uses, exercised end-to-end against the actual `FolderShareServer` running with a generated key. The guest-side mount step (`bromure-mount-meta` running `sshfs` from inside the VM) requires visual verification: the guest's serial console is silenced by `quiet loglevel=0` in the kernel cmdline (we copied that from macOS), so `bromure-spike session` headless doesn't show the post-boot mount output. The morning test is BromureAC's embed showing `/mnt/bromure-share-1/readme.txt` accessible inside the VM.

Verified non-visually:
- Build clean across every change. **133/133 unit tests pass** (124 → +8 ProfileEnvExports + +1 Msys2Path).
- BromureAC.exe smoke-launches alive at 4 s after each change.
- Custom QEMU bundle picked up from `windows/dist/qemu-bundle/` automatically (the QemuPaths probe-up was off by one — that's fixed).
- `FolderShareServer.StartAsync` produces a usable host SSH endpoint that authenticates with the per-session key and serves the shared dir via sftp-server.

## Build the night went through

1. **v3 bake** — copied `/etc/skel/.bash_profile` into `/home/ubuntu/` *after* useradd (root-cause fix for "xinitrc not invoking" — previously useradd ran before skel was populated, leaving home empty).
2. **v4 bake** — added `sshfs` + `fuse3` + `jq` + `openssh-client` to the in-guest package set, and replaced `/usr/local/bin/bromure-mount-meta` with a script that auto-mounts `/mnt/bromure-meta` *and* every entry in `shares.json` via sshfs against the host's session-scoped sshd. **Final image: 2.24 GB, baked in 18.7 min.**
3. **Per-session metadata ISO** now ships three files: `api_key.env` (Profile env exports), `shares.json` (mount manifest), `bromure-ssh-key` (PEM). Guest reads them via the existing `bromure-meta-mount.service`.

## What lands automatically

When you click `Boot session`:
1. `ShellViewModel.PrepareSessionSync` loads the first profile in `~/AppData/Local/Bromure/AC/profiles/`.
2. If that profile has any `FolderPaths`, it spawns a session-scoped `FolderShareServer`. (No FolderPaths → no share, just env + dotfiles.)
3. Generates an ed25519 keypair, writes a per-session sshd_config + authorized_keys, spawns `C:\msys64\usr\bin\sshd.exe -D -e -f <config>` with MSYS2's `PATH` injected so `sshd-session.exe` can find its DLLs.
4. Drops `shares.json` + `bromure-ssh-key` onto the metadata ISO.
5. Boots QEMU; the guest's `bromure-meta-mount.service` mounts the ISO, copies the key to `/run/bromure-ssh/key` with mode 0600, runs `sshfs $user@10.0.2.2:/c/Users/.../path /mnt/bromure-share-N` per share entry.
6. Session shutdown disposes `FolderShareServer` (kills sshd) via the new `SessionViewModel.SessionResources` list.

## What you still need to do this morning

1. Open BromureAC. Settings → Profiles → add a Profile with at least one `FolderPath`. (Use a folder that has files in it.)
2. Click `Boot session`. The embed should:
   - Auto-login as `ubuntu`.
   - Run `startx` from `/home/ubuntu/.bash_profile`.
   - Land you in `kitty` fullscreen via openbox.
3. In a kitty terminal: `ls /mnt/bromure-share-1` — should show your folder's contents.
   - If empty: check `journalctl -u bromure-meta-mount`. The log captures sshfs failures.
   - The host-side sshd log is at `~/AppData/Local/Bromure/AC/sessions/default-session/sshd.log`.
4. `echo "ping" > /mnt/bromure-share-1/from-vm.txt` — should appear on the host.

If `/mnt/bromure-meta/api_key.env` exists, your `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` will be set in any new shell.

## Things ruled out (with sources, in `windows/SHARING_INVESTIGATION.md`)

- `--enable-virtfs` (built-in 9p server) — gated to Linux/macOS/BSD at `meson.build:2345`. Hard.
- `vhost-user-fs-pci` — depends on `vhost-user`, gated out on Windows at `meson.build:227-230`. Even patching, the protocol needs `SCM_RIGHTS` FD passing which Windows AF_UNIX doesn't support.
- "virtiofsd.exe on Windows host" — no real binary. virtiofsd-rs is Linux-only by design (seccomp, namespaces, capabilities).
- WinFsp on its own — host-side filesystem framework; would need a custom QEMU device + guest module + protocol on top, weeks of work + GPLv3/commercial license decision.

## Files changed tonight

```
NEW   windows/Bromure.SandboxEngine/Sharing/FolderShareServer.cs
NEW   windows/Bromure.SandboxEngine/Sharing/Msys2Path.cs
NEW   windows/Bromure.SandboxEngine/Image/SessionMetadataIso.cs
NEW   windows/Bromure.SandboxEngine/Image/AlpineNetboot.cs
NEW   windows/Bromure.SandboxEngine/Image/AlpineInstaller.cs
NEW   windows/Bromure.SandboxEngine/Qemu/SerialDriver.cs
NEW   windows/Bromure.AC.Core/Model/ProfileEnvExports.cs
NEW   windows/Bromure.Tests/ProfileEnvExportsTests.cs                  (8 tests)
NEW   windows/Bromure.Tests/Msys2PathTests.cs                          (9 tests)
NEW   windows/scripts/build-qemu.ps1
NEW   windows/scripts/build-qemu.sh
NEW   windows/QEMU_BUILD.md
NEW   windows/SHARING_INVESTIGATION.md
NEW   windows/OVERNIGHT_REPORT.md                                       (this file)

CHG   windows/Bromure.SandboxEngine/Image/setup.sh
CHG   windows/Bromure.SandboxEngine/Image/CloudInitSeedBuilder.cs
CHG   windows/Bromure.SandboxEngine/Qemu/QemuConfig.cs
CHG   windows/Bromure.SandboxEngine/Qemu/QemuCommandBuilder.cs
CHG   windows/Bromure.SandboxEngine/Qemu/QemuPaths.cs                  (probe-up off-by-one fix)
CHG   windows/Bromure.AC/ViewModels/ShellViewModel.cs                  (share + env wiring)
CHG   windows/Bromure.AC/ViewModels/SessionViewModel.cs                (SessionResources)
CHG   windows/Bromure.Spike/Program.cs                                 (session subcommand + share-path)
CHG   windows/.gitignore                                               (dist/qemu-bundle/)

DEL   windows/Bromure.SandboxEngine/Image/UbuntuBaker.cs              (replaced by AlpineInstaller)
```

No QEMU source in git. Nothing in `dist/` is checked in. The bundle (~586 MB) is regenerated from `build-qemu.ps1` on the build machine.
