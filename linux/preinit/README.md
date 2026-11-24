# Boot templates and `bromure-preinit`

A workspace's cold boot spends its first ~0.3 s booting the same kernel to
the same state every time. A **boot template** is that state, saved once:
a guest snapshotted right after its kernel booted, before it read anything
of a workspace. Later boots of the same shape start from the snapshot.

On this machine (2 vCPUs, 2 GB): `workspaces run` to the first command in
440-570 ms from a template, 690-800 ms without (`linux/cli-e2e/boottime.sh`).

## How a template is made

After an ordinary boot of a shape that has no template, in the background
(`BootTemplateStore.build`), the daemon boots a VM of that shape (same
kernel, command line, vCPUs, memory, as many disks, the same share tags, a
NIC, vsock) with:

- `bromure-preinit` (this directory) as its whole initramfs;
- a 1 MiB placeholder file for every disk, empty directories behind the
  shares, a NIC nobody is on the other end of.

preinit mounts /dev, /proc, /sys and /run, prints `bromure-preinit: ready`
and waits. The daemon snapshots the VM there (the pages the guest wrote
since it started, ~100 MB of the 2 GB: Firecracker's dirty-page tracking and
a `Diff` snapshot, so the guest's whole memory is never written out) and
finds preinit's **parameter page** in it by its magic
(`bromure_preinit_params.h`, shared with the daemon). About 0.9 s in all.

Templates live in `<state>/boot-templates/<id>/` (`vm.snap`, `vm.mem`,
`template.json`), one per shape, per user, per host. `<id>` is a hash of
everything the snapshot depends on: the kernel, Firecracker, virtiofsd and
preinit binaries, the command line, vCPUs and memory, the number of disks,
the share tags, the host's CPU and kernel. They are a cache: the newest few
are kept, and a boot never waits for one.

## A boot from a template

`FirecrackerMachine.startFromTemplate`:

1. the template's memory is copied into a memfd (4 threads, ~10 ms, while
   the disk and the virtiofsds are made ready): the guest's memory from
   here on, shared with virtiofsd as a boot's is;
2. Firecracker starts empty and loads the snapshot over that memfd, with
   this VM's backends: its vsock socket and CID, its virtiofsd sockets
   (patch 0005's `fs_overrides` and `vsock_override.guest_cid`), its NIC
   (`fd:3`, inherited);
3. the placeholder disks are swapped for the VM's (`PATCH /drives`): the
   guest learns their real sizes from the change;
4. this boot's parameters are written into preinit's page of the guest's
   memory: the wall clock, 64 fresh random bytes, the NIC's MAC, the disks'
   sizes; then `go`;
5. the vCPUs resume. preinit sets the clock, credits the seed and reseeds
   the kernel's random generator, waits for the disks' sizes, re-reads the
   partition table, sets the MAC, mounts the root file system named by the
   command line's `root=`, and execs its init: what the image's initramfs
   does, in ~25 ms (most of it ext4's mount).

Anything wrong before preinit hands over (a load Firecracker refuses,
preinit failing, a timeout) and the VM boots the ordinary way on fresh
backends; that template is dropped and not made again by that daemon.

A root file system that wasn't cleanly unmounted: the kernel replays its
journal at the mount, and preinit leaves out the marker that tells systemd
the initramfs already checked it, so `systemd-fsck-root` does.

## What guests from one template share

Every guest restored from a template starts from the same kernel memory:
the same kernel address-space layout (KASLR), the same early hash seeds and
stack canaries. The random generator itself is reseeded from 64 host bytes
before anything in userspace draws from it (`boot_id`, every key and token
made later are per boot). Templates are per user and never leave the host,
so what is shared is shared among one user's own workspaces.

## Switches

- `BROMURE_BOOT_TEMPLATE=0`: off (every boot is ordinary).
- `BROMURE_PREINIT`: the preinit binary (default: beside `bromure-ac`, else
  `~/.local/share/bromure-ac/bin/bromure-preinit`). Without one, templates
  are off.
- `BROMURE_BOOT_TEMPLATE_DELAY_MS`: how long after an ordinary boot its
  template is made (default 3000).
- `BROMURE_BOOT_TRACE=1` shows a template boot's phases, and preinit prints
  its own on the guest's console.

`build.sh [OUT_DIR]` builds preinit (static); the package ships it. A
Firecracker built before patch 0005 refuses the load: the daemon then turns
templates off for its lifetime.
