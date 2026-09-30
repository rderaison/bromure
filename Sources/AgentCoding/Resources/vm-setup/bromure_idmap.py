#!/usr/bin/env python3
"""Idmapped mounts, so a distinct `run_as_user` is real and not decorative.

The problem this solves is stated in DESIGN.md §1.9: `/home/ubuntu` and every
`/mnt/bromure-share-N` are virtiofs mounts whose file ownership comes from the
macOS host, not from the guest's passwd file. A policy that says
`run_as_user: sandbox` therefore produces a workload that gets only the "other"
permission bits on its own project folder — the agent starts, and then cannot
save a file.

An idmapped mount fixes that entirely in the guest. The same inodes are
presented through a second mount with the uid the workload actually runs as, so
no host-side change and no chown of the user's files is needed.

    open_tree(OPEN_TREE_CLONE)        detached copy of the mount
      → mount_setattr(MOUNT_ATTR_IDMAP, userns_fd)
      → move_mount()                  put it back over the same path

The userns carries the mapping, and its direction is the opposite of the one
intuition suggests. For an idmapped mount the kernel looks the filesystem's
on-disk id up as the *inside* id and presents the *outside* id, so `uid_map`
reads `<owner_uid> <sandbox_uid> 1` — "an inode owned by owner_uid on disk is
presented as sandbox_uid through this mount". Writing it the other way round
compiles, mounts and silently yields 65534 (nobody) for every file, which is
how this was caught.

All of this happens inside a private mount namespace that `bromure-sandboxd`
unshares for the sandboxed tree, so agentd — which is outside the sandbox and
still needs the original ownership — sees none of it.

Every step can fail for reasons outside our control: the kernel may be too old
(mount_setattr is 5.12+), the filesystem may not implement `FS_ALLOW_IDMAP`
(virtiofs support is recent and version-dependent), or the mount may be shared
in a way that refuses the move. Every failure is caught and returned as a
reason, never raised: the caller falls back to running without the remap and
reporting it honestly, which is a worse workspace but a working one.
"""

import ctypes
import ctypes.util
import os
import signal
import struct

_libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
_libc.syscall.restype = ctypes.c_long

# aarch64 numbers; same on x86_64 for all four.
SYS_open_tree = 428
SYS_move_mount = 429
SYS_mount_setattr = 442
SYS_mount = 40 if os.uname().machine == "aarch64" else 165

AT_FDCWD = -100
AT_EMPTY_PATH = 0x1000
AT_RECURSIVE = 0x8000

OPEN_TREE_CLONE = 1
OPEN_TREE_CLOEXEC = os.O_CLOEXEC

MOVE_MOUNT_F_EMPTY_PATH = 0x00000004

MOUNT_ATTR_IDMAP = 0x00100000

CLONE_NEWUSER = 0x10000000
CLONE_NEWNS = 0x00020000

MS_REC = 16384
MS_SLAVE = 1 << 19


def _syscall(number, *args):
    ctypes.set_errno(0)
    argv = [ctypes.c_long(a) if isinstance(a, int) else a for a in args]
    ret = _libc.syscall(ctypes.c_long(number), *argv)
    return ret, ctypes.get_errno()


class IdmapError(Exception):
    """Never fatal to the caller: a reason to report, not a reason to stop."""


def unshare_mount_namespace():
    """Give the calling process its own view of the mount table.

    `MS_SLAVE|MS_REC` on `/` afterwards is what keeps the remapping private:
    without it the new mounts would propagate back to agentd's namespace and
    change the ownership *it* sees.
    """
    ctypes.set_errno(0)
    if _libc.unshare(CLONE_NEWNS) != 0:
        raise IdmapError("unshare(CLONE_NEWNS): %s"
                         % os.strerror(ctypes.get_errno()))
    ret, err = _syscall(SYS_mount, b"none", b"/", None, MS_REC | MS_SLAVE, None)
    if ret < 0:
        raise IdmapError("make / rslave: %s" % os.strerror(err))


def make_idmap_userns(owner_uid, sandbox_uid, owner_gid, sandbox_gid):
    """A user namespace whose only purpose is to carry the mapping.

    Nothing ever runs in it. A child is forked solely so the namespace has a
    process to hang off while its maps are written from out here, where we still
    have the privilege to write them; then its `/proc/<pid>/ns/user` is opened
    and the child is killed. The open fd keeps the namespace alive.
    """
    read_fd, write_fd = os.pipe()
    ready_read, ready_write = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(read_fd)
        os.close(ready_read)
        try:
            ctypes.set_errno(0)
            if _libc.unshare(CLONE_NEWUSER) != 0:
                os._exit(1)
            os.write(ready_write, b"1")
            # Park until the parent has the namespace fd it needs.
            os.read(write_fd, 1)
        except OSError:
            pass
        os._exit(0)

    os.close(ready_write)
    try:
        if os.read(ready_read, 1) != b"1":
            raise IdmapError("child could not create a user namespace")
        # `<inside> <outside> <count>`. For an idmapped mount the filesystem's
        # on-disk id is the INSIDE id and the presented id is the OUTSIDE one,
        # so this is `owner_uid sandbox_uid 1` and not the reverse. See the
        # module docstring; the reverse yields 65534 for everything.
        with open("/proc/%d/uid_map" % pid, "w") as handle:
            handle.write("%d %d 1\n" % (owner_uid, sandbox_uid))
        with open("/proc/%d/setgroups" % pid, "w") as handle:
            handle.write("deny\n")
        with open("/proc/%d/gid_map" % pid, "w") as handle:
            handle.write("%d %d 1\n" % (owner_gid, sandbox_gid))
        userns_fd = os.open("/proc/%d/ns/user" % pid, os.O_RDONLY | os.O_CLOEXEC)
    except OSError as exc:
        raise IdmapError("building the idmap userns: %s" % exc)
    finally:
        os.close(ready_read)
        try:
            os.write(write_fd, b"1")
        except OSError:
            pass
        os.close(write_fd)
        os.close(read_fd)
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
    return userns_fd


def _mount_attr(userns_fd):
    """struct mount_attr { u64 attr_set, attr_clr, propagation; u64 userns_fd; }"""
    return struct.pack("=QQQQ", MOUNT_ATTR_IDMAP, 0, 0, userns_fd)


def remap_mount(path, userns_fd):
    """Replace the mount at `path` with an idmapped copy of itself."""
    tree, err = _syscall(SYS_open_tree, AT_FDCWD, path.encode(),
                         OPEN_TREE_CLONE | OPEN_TREE_CLOEXEC | AT_RECURSIVE)
    if tree < 0:
        raise IdmapError("open_tree(%s): %s" % (path, os.strerror(err)))
    tree = int(tree)
    try:
        attr = _mount_attr(userns_fd)
        buf = ctypes.create_string_buffer(attr, len(attr))
        ret, err = _syscall(SYS_mount_setattr, tree, b"",
                            AT_EMPTY_PATH | AT_RECURSIVE, buf, len(attr))
        if ret < 0:
            # EINVAL here is the common, undramatic one: this filesystem does
            # not set FS_ALLOW_IDMAP. Name it, because "invalid argument" on its
            # own sends the reader looking for a bug in the call.
            hint = (" (filesystem does not support idmapped mounts)"
                    if err == 22 else "")
            raise IdmapError("mount_setattr(%s): %s%s"
                             % (path, os.strerror(err), hint))
        ret, err = _syscall(SYS_move_mount, tree, b"", AT_FDCWD, path.encode(),
                            MOVE_MOUNT_F_EMPTY_PATH)
        if ret < 0:
            raise IdmapError("move_mount(%s): %s" % (path, os.strerror(err)))
    finally:
        os.close(tree)


def mountpoints_under(paths):
    """Keep only the paths that are their own mount point.

    `open_tree` needs a mount, not a directory. A workdir that is a plain
    directory inside an already-remapped mount is covered by its parent and must
    not be remapped again.
    """
    out = []
    for path in paths:
        try:
            if os.path.ismount(path):
                out.append(path)
        except OSError:
            continue
    return out


def apply(targets, owner_uid, sandbox_uid, owner_gid, sandbox_gid):
    """Remap every target that is a mount point. Returns (remapped, problems).

    The caller must already be in a private mount namespace (see
    `unshare_mount_namespace`) and must still be root.

    Partial success is a real outcome and is reported as one: remapping the
    home directory but not one share slot leaves a usable workspace with one
    unwritable folder, and the user should be told which.
    """
    remapped, problems = [], []
    candidates = mountpoints_under(targets)
    if not candidates:
        return remapped, ["none of %r is a mount point" % (list(targets),)]
    try:
        userns_fd = make_idmap_userns(owner_uid, sandbox_uid,
                                      owner_gid, sandbox_gid)
    except IdmapError as exc:
        return remapped, [str(exc)]
    try:
        for path in candidates:
            try:
                remap_mount(path, userns_fd)
                remapped.append(path)
            except IdmapError as exc:
                problems.append(str(exc))
    finally:
        os.close(userns_fd)
    return remapped, problems
