#!/usr/bin/env python3
"""bromure-strict — apply the strict sandbox's privilege revocation, at RUNTIME.

The strict sandbox takes `sudo`, the `docker` group and the console away from the
workspace user before any agent code runs. The original implementation did that
by editing the disk: `rm -f /etc/sudoers.d/90-ubuntu`, writing
`/etc/sudoers.d/zz-bromure-strict`, and `gpasswd -d ubuntu docker sudo lxd adm`.

**A workspace's root disk is persistent ext4; `/run` is tmpfs.** So the
revocation survived a reboot and its marker did not, and the second boot of any
strict workspace went:

1. no `/run/bromure-strict.done`, so agentd runs the root script;
2. the root script needs `sudo`, which the *first* boot already took away, so
   nothing in it runs — no attestor, no sentry, no supervisor, no marker;
3. `os._exit(75)`, systemd restarts, and it repeats forever.

The host never sees vsock 5800 or 5840, and the VM is indistinguishable from a
dead one. Worse, turning the strict sandbox *off* never gave the user back sudo
or docker, because nothing ever undid the disk edits.

So the revocation must leave **nothing on disk**. Everything here is a bind mount
from `/run`, which the kernel discards at reboot, so every boot starts from the
stock image state and strict is re-applied, or not, from scratch. There is no
undo to get wrong and no migration to write.

  apply    build the replacement files in /run and bind-mount them over /etc
  check    report whether the revocation is currently in effect (exit 0/1)
  verify   assert the on-disk files are untouched (what the test asserts)

Run as root.
"""

import grp
import json
import os
import pwd
import shutil
import subprocess
import sys

RUN_DIR = os.environ.get("BROMURE_STRICT_RUN", "/run/bromure-strict")
# Where the result is left for attestd to forward. A revocation that FAILED and
# is reported as applied is worse than one that never ran: the host would treat
# the workspace as strict while the agent still holds sudo.
RESULT_PATH = os.environ.get("BROMURE_STRICT_RESULT",
                             "/run/bromure-sandbox/strict.json")
WORKSPACE_USER = os.environ.get("BROMURE_WORKSPACE_USER", "ubuntu")

# Where the workspace user's privileges actually live.
SUDOERS_D = os.environ.get("BROMURE_SUDOERS_D", "/etc/sudoers.d")
GROUP_FILE = os.environ.get("BROMURE_GROUP_FILE", "/etc/group")
GSHADOW_FILE = os.environ.get("BROMURE_GSHADOW_FILE", "/etc/gshadow")

# The grant cloud-init leaves behind, and the groups that are worth having.
NOPASSWD_DROPIN = "90-ubuntu"
PRIVILEGED_GROUPS = ("docker", "sudo", "lxd", "adm", "wheel")
DENY_LINE = "%s ALL=(ALL) !ALL\n"


def log(message):
    sys.stderr.write("[strict] %s\n" % message)
    sys.stderr.flush()


# ---------------------------------------------------------------------------
# Building the replacements
# ---------------------------------------------------------------------------

def rewrite_group_line(line, user, groups):
    """Drop `user` from `line`'s member list when the group is one of `groups`.

    Format is `name:passwd:gid:member,member`. Everything else is passed through
    byte for byte, including comments and malformed lines, because this file is
    how the machine resolves every user and group it has and a clever rewrite
    that drops one it did not understand is a machine that cannot log in.
    """
    if not line.strip() or line.lstrip().startswith("#"):
        return line
    fields = line.rstrip("\n").split(":")
    if len(fields) < 4 or fields[0] not in groups:
        return line
    members = [m for m in fields[3].split(",") if m and m != user]
    fields[3] = ",".join(members)
    return ":".join(fields) + "\n"


def rewrite_group_file(source, user, groups):
    with open(source) as handle:
        lines = handle.readlines()
    rewritten = [rewrite_group_line(line, user, groups) for line in lines]
    # The two checks that matter, because getting this wrong costs the machine
    # its ability to resolve anybody: the same number of lines, and root still
    # present.
    if len(rewritten) != len(lines):
        raise RuntimeError("rewrite changed the line count of %s" % source)
    if not any(line.startswith("root:") for line in rewritten):
        raise RuntimeError("rewrite lost root from %s" % source)
    return "".join(rewritten)


def build_sudoers(user, staging):
    """A copy of /etc/sudoers.d with the NOPASSWD grant gone and a denial added.

    sudo is particular about ownership and mode and silently ignores a file it
    does not like, so both are set explicitly rather than inherited.
    """
    target = os.path.join(staging, "sudoers.d")
    shutil.rmtree(target, ignore_errors=True)
    os.makedirs(target, mode=0o750)
    for name in sorted(os.listdir(SUDOERS_D)):
        if name == NOPASSWD_DROPIN or name.endswith("~"):
            continue
        source = os.path.join(SUDOERS_D, name)
        if os.path.isfile(source):
            shutil.copy(source, os.path.join(target, name))
    with open(os.path.join(target, "zz-bromure-strict"), "w") as handle:
        handle.write(DENY_LINE % user)
    os.chown(target, 0, 0)
    os.chmod(target, 0o750)
    for name in os.listdir(target):
        path = os.path.join(target, name)
        os.chown(path, 0, 0)
        os.chmod(path, 0o440)
    return target


def build_file(source, staging, name, user, groups, mode, gid=0):
    content = rewrite_group_file(source, user, groups)
    target = os.path.join(staging, name)
    with open(target, "w") as handle:
        handle.write(content)
    os.chown(target, 0, gid)
    os.chmod(target, mode)
    return target


# ---------------------------------------------------------------------------
# Mounting
# ---------------------------------------------------------------------------

def is_mountpoint(path):
    return subprocess.run(["mountpoint", "-q", path],
                          capture_output=True).returncode == 0


def bind(source, target):
    if is_mountpoint(target):
        return True, "already bound"
    result = subprocess.run(["mount", "--bind", source, target],
                            capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        return False, result.stderr.strip() or "mount --bind failed"
    return True, None


def apply_revocation():
    user = WORKSPACE_USER
    try:
        pwd.getpwnam(user)
    except KeyError:
        return {"ok": False, "reason": "no such user: %s" % user}

    os.makedirs(RUN_DIR, mode=0o755, exist_ok=True)
    os.chown(RUN_DIR, 0, 0)
    os.chmod(RUN_DIR, 0o755)

    applied, problems = [], []

    # Groups first. If this is going to fail, fail before sudo is gone, so the
    # caller still has a way to put things right.
    try:
        gshadow_gid = grp.getgrnam("shadow").gr_gid
    except KeyError:
        gshadow_gid = 0
    for source, name, mode, gid in (
            (GROUP_FILE, "group", 0o644, 0),
            (GSHADOW_FILE, "gshadow", 0o640, gshadow_gid)):
        if not os.path.exists(source):
            continue
        try:
            staged = build_file(source, RUN_DIR, name, user,
                                PRIVILEGED_GROUPS, mode, gid)
        except (OSError, RuntimeError) as exc:
            problems.append("%s: %s" % (source, exc))
            continue
        ok, why = bind(staged, source)
        (applied if ok else problems).append(source if ok else "%s: %s" % (source, why))

    # Then sudo.
    try:
        staged = build_sudoers(user, RUN_DIR)
    except OSError as exc:
        problems.append("%s: %s" % (SUDOERS_D, exc))
    else:
        ok, why = bind(staged, SUDOERS_D)
        (applied if ok else problems).append(
            SUDOERS_D if ok else "%s: %s" % (SUDOERS_D, why))

    return {"ok": not problems, "applied": applied, "problems": problems}


def check_revocation():
    """Is the revocation in effect right now?"""
    state = {
        "sudoers_bound": is_mountpoint(SUDOERS_D),
        "group_bound": is_mountpoint(GROUP_FILE),
        "user_in_privileged_groups": [],
        "sudo_works": None,
    }
    try:
        groups = os.getgrouplist(WORKSPACE_USER,
                                 pwd.getpwnam(WORKSPACE_USER).pw_gid)
        names = {grp.getgrgid(g).gr_name for g in groups
                 if _group_exists(g)}
        state["user_in_privileged_groups"] = sorted(
            names & set(PRIVILEGED_GROUPS))
    except (KeyError, OSError):
        pass
    return state


def _group_exists(gid):
    try:
        grp.getgrgid(gid)
        return True
    except KeyError:
        return False


def verify_disk_untouched(baseline):
    """Compare the UNDERLYING files against a baseline taken before `apply`.

    Reading through the bind mounts would compare the replacements with
    themselves and always pass, so this reads the real inodes by temporarily
    looking at them through /proc/1/root -- which is the same filesystem but
    not, for these paths, the same mounts... except that bind mounts are in the
    same namespace. So instead: the caller takes the baseline BEFORE apply and
    passes it in, and this is run AFTER the mounts are dropped. That is what the
    test does, and it is the only comparison that means anything.
    """
    current = {}
    for path in (GROUP_FILE, GSHADOW_FILE):
        if os.path.exists(path):
            current[path] = _digest(path)
    listing = sorted(os.listdir(SUDOERS_D)) if os.path.isdir(SUDOERS_D) else []
    current[SUDOERS_D] = listing
    differences = [key for key in baseline if baseline[key] != current.get(key)]
    return {"ok": not differences, "changed": differences,
            "baseline": baseline, "current": current}


def _digest(path):
    """A content hash, or a stable marker when it cannot be read.

    `/etc/gshadow` is 0640 root:shadow, so a non-root caller cannot hash it. It
    must still produce the SAME value on both sides of the comparison, or
    `verify` reports a change that is only a permission — which is how the first
    run of the test reported drift that was not there. Run baseline and verify as
    the same user (root, to cover gshadow properly).
    """
    import hashlib
    try:
        with open(path, "rb") as handle:
            return hashlib.sha256(handle.read()).hexdigest()
    except OSError as exc:
        return "unreadable:%s" % exc.errno


def baseline():
    snapshot = {}
    for path in (GROUP_FILE, GSHADOW_FILE):
        if os.path.exists(path):
            snapshot[path] = _digest(path)
    snapshot[SUDOERS_D] = (sorted(os.listdir(SUDOERS_D))
                           if os.path.isdir(SUDOERS_D) else [])
    return snapshot


def write_result(result):
    """Publish the outcome where attestd will pick it up.

    Best effort by design: a failure to write this must not turn a successful
    revocation into a failed boot. But a silent partial revocation must not be
    possible either, so `applied` is only true when every mount landed.
    """
    try:
        os.makedirs(os.path.dirname(RESULT_PATH), mode=0o755, exist_ok=True)
        tmp = RESULT_PATH + ".tmp"
        with open(tmp, "w") as handle:
            json.dump({"applied": bool(result.get("ok")),
                       "mounts": result.get("applied", []),
                       "problems": result.get("problems", [])},
                      handle, sort_keys=True)
        os.chmod(tmp, 0o644)
        os.rename(tmp, RESULT_PATH)
    except OSError as exc:
        log("could not publish the result: %s" % exc)


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "apply"
    if command == "check":
        print(json.dumps(check_revocation(), sort_keys=True))
        return 0
    if command == "baseline":
        print(json.dumps(baseline(), sort_keys=True))
        return 0
    if command == "verify":
        snapshot = json.loads(sys.argv[2])
        result = verify_disk_untouched(snapshot)
        print(json.dumps(result, sort_keys=True))
        return 0 if result["ok"] else 1
    if command != "apply":
        log("unknown command: %s" % command)
        return 2
    if os.geteuid() != 0:
        log("must run as root")
        return 2
    result = apply_revocation()
    write_result(result)
    print(json.dumps(result, sort_keys=True))
    for problem in result["problems"]:
        log("PROBLEM: %s" % problem)
    log("applied: %s" % ", ".join(result["applied"]) if result["applied"]
        else "nothing applied")
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
