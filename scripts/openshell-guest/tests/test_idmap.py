#!/usr/bin/env python3
"""Idmapped mounts: does the remap work, and is it private to the sandbox?

Must run as root. Uses tmpfs, not virtiofs — this VM has no virtiofs share to
borrow — so it proves the machinery (userns construction, map direction,
open_tree/mount_setattr/move_mount, mount-namespace privacy) but NOT that
virtiofs itself sets `FS_ALLOW_IDMAP`. That last question can only be answered
on a real workspace, and `bromure-sandboxd` is written so that the answer being
"no" degrades to an honest warning rather than a failure — which the last case
below exercises directly.

Run: sudo tests/test_idmap.py
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import bromure_idmap as idmap  # noqa: E402

OWNER_UID, OWNER_GID = 1000, 1000
SANDBOX_UID, SANDBOX_GID = 4242, 4242

failures = []


def check(name, actual, expected):
    if actual == expected:
        print("  ok   %s" % name)
    else:
        print("  FAIL %s (expected %r, got %r)" % (name, expected, actual))
        failures.append(name)


def in_child(fn):
    """Run in a forked child and return whatever it writes to the pipe.

    The remap only exists inside the child's mount namespace, so every
    assertion about it has to be made there.
    """
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(read_fd)
        try:
            payload = json.dumps(fn()).encode()
        except BaseException as exc:  # noqa: BLE001
            payload = json.dumps({"error": repr(exc)}).encode()
        os.write(write_fd, payload[:65536])
        os.close(write_fd)
        os._exit(0)
    os.close(write_fd)
    with os.fdopen(read_fd, "rb") as handle:
        payload = handle.read()
    os.waitpid(pid, 0)
    return json.loads(payload) if payload else {"error": "child wrote nothing"}


def main():
    if os.geteuid() != 0:
        sys.exit("must run as root")

    source = "/tmp/bromure-idmap-test"
    os.makedirs(source, exist_ok=True)
    subprocess.run(["umount", source], capture_output=True)
    subprocess.run(["mount", "-t", "tmpfs", "tmpfs", source], check=True)
    try:
        target = os.path.join(source, "file")
        with open(target, "w") as handle:
            handle.write("content")
        os.chown(target, OWNER_UID, OWNER_GID)
        os.chown(source, OWNER_UID, OWNER_GID)

        print("=== remap ===")
        result = in_child(lambda: _remap_and_stat(source, target))
        if "error" in result:
            print("  FAIL child: %s" % result["error"])
            failures.append("remap")
        else:
            check("mount was remapped", result["remapped"], [source])
            check("no problems reported", result["problems"], [])
            check("file appears as the sandbox uid", result["uid"], SANDBOX_UID)
            check("file appears as the sandbox gid", result["gid"], SANDBOX_GID)
            check("content still readable", result["content"], "content")

        print("\n=== privacy ===")
        check("ownership outside the namespace is untouched",
              os.stat(target).st_uid, OWNER_UID)

        print("\n=== honest failure on a filesystem that cannot idmap ===")
        # /proc never sets FS_ALLOW_IDMAP, so this is the real degradation path
        # and not a simulated one.
        result = in_child(lambda: _remap_only("/proc"))
        if "error" in result:
            print("  FAIL child: %s" % result["error"])
            failures.append("degradation")
        else:
            check("nothing was remapped", result["remapped"], [])
            if result["problems"] and "idmapped mounts" in result["problems"][0]:
                print("  ok   reports a reason the host can show: %s"
                      % result["problems"][0])
            elif result["problems"]:
                print("  ok   reports a reason: %s" % result["problems"][0])
            else:
                print("  FAIL failed silently")
                failures.append("degradation-reason")
    finally:
        subprocess.run(["umount", source], capture_output=True)

    print("\n%s" % ("ALL IDMAP TESTS PASSED" if not failures
                    else "%d CHECK(S) FAILED" % len(failures)))
    return 1 if failures else 0


def _remap_and_stat(source, target):
    idmap.unshare_mount_namespace()
    remapped, problems = idmap.apply([source], OWNER_UID, SANDBOX_UID,
                                     OWNER_GID, SANDBOX_GID)
    info = os.stat(target)
    with open(target) as handle:
        content = handle.read()
    return {"remapped": remapped, "problems": problems,
            "uid": info.st_uid, "gid": info.st_gid, "content": content}


def _remap_only(path):
    idmap.unshare_mount_namespace()
    remapped, problems = idmap.apply([path], OWNER_UID, SANDBOX_UID,
                                     OWNER_GID, SANDBOX_GID)
    return {"remapped": remapped, "problems": problems}


if __name__ == "__main__":
    sys.exit(main())
