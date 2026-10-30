# `run_as_user` and the virtiofs shares on a Linux host: options

**Status: options only, for a decision. Nothing here is implemented.**

## The problem

With `run_as_user: sandbox`, the workload runs as uid 999 and the shares are owned by the workspace user (uid 1000). On a Linux host (virtiofsd 1.13.2, guest kernel 6.8.0-147) the workload cannot use them. `test_boot.sh` fails three checks in each of its two `run_as_user` configs: read, append, and create in a host-backed workdir on `/mnt/bromure-outbox`. With the home disk in place, nothing else in those configs fails.

What the guest sees:

```
/mnt/bromure-outbox  virtiofs  rw,relatime        stat: 1000:991 0700
$ sudo -u sandbox ls /mnt/bromure-outbox   ->  Permission denied
```

**Where the check happens.** virtiofsd runs with `--translate-uid squash-guest:0:0:4294967295`, which maps every guest uid to the namespace root (the host user). So the host side would allow the operation. The refusal is the **guest kernel's**: virtio_fs always mounts with `default_permissions`, and the guest checks the mode bits against the ids virtiofsd reports (`host:0:1000:1`, so uid 1000). FUSE can't idmap a mount on 6.8 (`mount_setattr` → EINVAL), which DESIGN.md already notes. That's why the home needed a disk of its own.

**DESIGN.md says the opposite for VZ:** "a share that stats as uid 1000 mode 0755 is nonetheless created in, and written to, by uid 999". The guest kernel is the same, and its virtio_fs enforces mode bits whatever the device. So the VZ result probably comes from the ids or modes VZ's device reports, or from a step around the check, not from a mount option. The Mac should repeat the same probe (`stat` as 999, then `sudo -u sandbox touch` in a 0755 directory owned by 1000) before Linux copies that behaviour.

There are two layers here. The Linux daemon also creates `outbox` with mode 0700, where macOS's is presumably 0755. 0700 stops even reads, but 0755 alone would still refuse writes.

## Options

| # | What | Side that changes | What breaks | Security effect |
|---|---|---|---|---|
| 1 | **Per-share owner = the run_as uid.** virtiofsd `--translate-uid host:0:999:1` (and the gid likewise) for shares the workload must write, so the guest sees them owned by 999. | host (the virtiofsd argv per share, chosen from the policy's run_as) | agentd (uid 1000) becomes "other" on those shares: its writes (outbox messages, git in the workdir) need `o+w` or must go through the sandbox. A share can't serve both uids as owner. | Neutral to slightly better: the workload owns only the shares it is granted. A per-share decision, made on the host. |
| 2 | **A shared group.** `--translate-gid host:0:<G>:1` with a guest group G that both ubuntu and sandbox are in, plus group-writable modes on the host side (setgid directories, umask 002). | host (gid mapping, and the modes of the user's files) and guest (group membership) | It needs the HOST files to be group-writable. virtiofsd has no mode override, so this means changing the user's project files on disk, or a umask the user didn't choose. Files the user creates later on the host come back 0644. | Weaker on the host: group-writable project files. In the guest, any member of G gets the same access. |
| 3 | **POSIX ACLs.** virtiofsd `--posix-acl`, with a named-user ACL entry for the sandbox uid on the shared tree, written by the host (in the guest's numbering, through the translation) or by the guest (as 1000, the owner, before the workload starts). | host (`--posix-acl`), plus host or guest (setting ACLs) | ACL entries persist into the user's tree on the host. Default ACLs only cover new files, so existing ones need a recursive pass. ACL uids go through the translation and must be checked. | Precise (one uid, chosen access). It leaves visible ACLs on host files, and a host tool that copies modes and not ACLs loses them. |
| 4 | **Mount without `default_permissions`.** The guest kernel would then defer to the host side, which already allows everything (squash-guest), which is the VZ-like behaviour. | guest kernel | Not a mount option on 6.8: virtio_fs forces it. It needs a kernel patch. It also removes in-guest DAC on the share for every uid, not only the sandbox. | Weaker: every guest uid could write every share. Landlock (which the workload runs under) still restricts paths, so the policy rather than DAC becomes the only fence. |
| 5 | **Idmapped share mounts** (the home's mechanism, applied to the shares). | guest kernel (a newer one: FUSE idmap support postdates 6.8; needs checking for virtiofs), plus server support | Not available on the image's 6.8 kernel. It means an HWE or newer kernel for amd64 guests, and the arm64 image would diverge. | Best fit: the same model as the home (999 inside, 1000 on disk), no host-side changes. |
| 6 | **Don't honour `run_as_user` on host shares.** The workload reaches shares only through a uid-1000 helper (e.g. sandboxd's exec op), or the policy refuses `run_as_user` together with a share workdir on Linux. | guest (sandboxd and the policy) | Feature parity: the `run_as_user` + share workdir combination doesn't work on Linux. | Clear and honest. No weakening; a documented limitation. |

## Notes for the decision

- Options 1, 3 and 6 need no kernel change. 1 is the smallest change, if a share used by a `run_as_user` workload doesn't also need agentd to write into it. Measuring what agentd writes in the outbox decides that.
- 2 and 4 weaken something: host file modes or in-guest DAC. 5 is right but is a kernel decision.
- Whichever is chosen, the daemon's `outbox` should probably be 0755 like the Mac's (to be confirmed there). 0700 is a Linux-only choice from the first daemon round.
