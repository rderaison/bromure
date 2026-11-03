#!/usr/bin/env python3
"""Differential test: bromure_openshell.py vs OpenShell's own crates.

Both sides get byte-identical jobs — the same policy, the same workdirs, the
same probe list — apply their own enforcement in a fresh child process, and
report what each probe did. Any disagreement is a bug in the Python side, and
prints as one.

The Rust side (`differential/src/main.rs`) links the real `landlock` and
`seccompiler` crates and runs OpenShell's `prepare`/`enforce`/`build_filter_rules`
ported from the reference tree. So this is not "does my reading of the source
look right" — it is "does the kernel answer the same question the same way".

Usage: ./diff.py [--keep-going]
"""
import errno
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import bromure_openshell as bo  # noqa: E402

HARNESS = os.path.join(HERE, "target", "release", "openshell-diff")

# Cases are written against this placeholder and rebased onto each side's own
# fixture directory; see `make_job`.
ROOT_PLACEHOLDER = "@ROOT@"


# --- fixture ---------------------------------------------------------------

def build_fixture():
    """A directory tree the probes below walk. Recreated per run so a failed
    run can't leave state that changes the next one's answers."""
    root = tempfile.mkdtemp(prefix="osdiff-")
    layout = {
        "ro": ["file", "sub/nested"],
        "rw": ["file", "sub/nested"],
        "denied": ["file"],
        "workdir": ["file"],
    }
    for top, entries in layout.items():
        for entry in entries:
            path = os.path.join(root, top, entry)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as handle:
                handle.write("x" * 16)
    return root


def probes_for(root):
    """The probe battery. Every filesystem right Landlock distinguishes at
    ABI 3, on a directory and on a file, inside and outside the allowlist."""
    out = []
    for top in ("ro", "rw", "denied", "workdir"):
        base = os.path.join(root, top)
        out += [
            {"kind": "fs", "op": "read", "path": os.path.join(base, "file")},
            {"kind": "fs", "op": "write", "path": os.path.join(base, "file")},
            {"kind": "fs", "op": "create", "path": os.path.join(base, "created")},
            {"kind": "fs", "op": "truncate", "path": os.path.join(base, "file")},
            {"kind": "fs", "op": "listdir", "path": base},
            {"kind": "fs", "op": "mkdir", "path": os.path.join(base, "newdir")},
            {"kind": "fs", "op": "unlink", "path": os.path.join(base, "sub", "nested")},
            {"kind": "fs", "op": "symlink", "path": os.path.join(base, "link")},
            {"kind": "fs", "op": "read", "path": os.path.join(base, "sub")},
        ]
    # Device nodes and system paths: the non-directory access mask.
    out += [
        {"kind": "fs", "op": "read", "path": "/dev/null"},
        {"kind": "fs", "op": "write", "path": "/dev/null"},
        {"kind": "fs", "op": "read", "path": "/dev/urandom"},
        {"kind": "fs", "op": "read", "path": "/etc/hostname"},
        {"kind": "fs", "op": "read", "path": "/proc/self/status"},
        {"kind": "fs", "op": "exec", "path": "/bin/true"},
    ]
    return out


SYSCALL_PROBES = [
    # socket domains
    {"kind": "syscall", "nr": bo.SYS["socket"], "args": [bo.AF_VSOCK, 1, 0]},
    {"kind": "syscall", "nr": bo.SYS["socket"], "args": [bo.AF_INET, 1, 0]},
    {"kind": "syscall", "nr": bo.SYS["socket"], "args": [bo.AF_INET6, 1, 0]},
    {"kind": "syscall", "nr": bo.SYS["socket"], "args": [bo.AF_PACKET, 3, 0]},
    {"kind": "syscall", "nr": bo.SYS["socket"], "args": [bo.AF_NETLINK, 3, 0]},
    {"kind": "syscall", "nr": bo.SYS["socket"], "args": [bo.AF_NETLINK, 3, 9]},
    {"kind": "syscall", "nr": bo.SYS["socket"], "args": [bo.AF_NETLINK, 3, 16]},
    {"kind": "syscall", "nr": bo.SYS["socket"], "args": [bo.AF_BLUETOOTH, 1, 0]},
    # unconditional blocks (invalid args on purpose: the filter must answer
    # before the kernel ever looks at them)
    {"kind": "syscall", "nr": bo.SYS["ptrace"], "args": [0, 0, 0, 0]},
    {"kind": "syscall", "nr": bo.SYS["bpf"], "args": [0, 0, 0]},
    {"kind": "syscall", "nr": bo.SYS["process_vm_readv"], "args": [0, 0, 0, 0, 0, 0]},
    {"kind": "syscall", "nr": bo.SYS["process_vm_writev"], "args": [0, 0, 0, 0, 0, 0]},
    {"kind": "syscall", "nr": bo.SYS["pidfd_getfd"], "args": [0, 0, 0]},
    {"kind": "syscall", "nr": bo.SYS["pidfd_send_signal"], "args": [0, 0, 0, 0]},
    {"kind": "syscall", "nr": bo.SYS["io_uring_setup"], "args": [0, 0]},
    {"kind": "syscall", "nr": bo.SYS["mount"], "args": [0, 0, 0, 0, 0]},
    {"kind": "syscall", "nr": bo.SYS["fsopen"], "args": [0, 0]},
    {"kind": "syscall", "nr": bo.SYS["fsconfig"], "args": [0, 0, 0, 0, 0]},
    {"kind": "syscall", "nr": bo.SYS["fsmount"], "args": [0, 0, 0]},
    {"kind": "syscall", "nr": bo.SYS["fspick"], "args": [0, 0, 0]},
    {"kind": "syscall", "nr": bo.SYS["move_mount"], "args": [0, 0, 0, 0, 0]},
    {"kind": "syscall", "nr": bo.SYS["open_tree"], "args": [0, 0, 0]},
    {"kind": "syscall", "nr": bo.SYS["setns"], "args": [0, 0]},
    {"kind": "syscall", "nr": bo.SYS["umount2"], "args": [0, 0]},
    {"kind": "syscall", "nr": bo.SYS["pivot_root"], "args": [0, 0]},
    {"kind": "syscall", "nr": bo.SYS["userfaultfd"], "args": [0]},
    {"kind": "syscall", "nr": bo.SYS["perf_event_open"], "args": [0, 0, 0, 0, 0]},
    {"kind": "syscall", "nr": bo.SYS["memfd_create"], "args": [0, 0]},
    # conditional blocks: the blocked flag and a neighbouring allowed one
    {"kind": "syscall", "nr": bo.SYS["unshare"], "args": [bo.CLONE_NEWUSER]},
    {"kind": "syscall", "nr": bo.SYS["unshare"], "args": [bo.CLONE_NEWUSER | 0x400]},
    {"kind": "syscall", "nr": bo.SYS["unshare"], "args": [0x400]},
    {"kind": "syscall", "nr": bo.SYS["unshare"], "args": [bo.CLONE_NEWNS]},
    {"kind": "syscall", "nr": bo.SYS["execveat"], "args": [-1, 0, 0, 0, 0x1000]},
    {"kind": "syscall", "nr": bo.SYS["execveat"], "args": [-1, 0, 0, 0, 0]},
    {"kind": "syscall", "nr": bo.SYS["seccomp"], "args": [1, 0, 0]},
    {"kind": "syscall", "nr": bo.SYS["seccomp"], "args": [0, 0, 0]},
    # compatibility filter: ENOSYS, not EPERM
    {"kind": "syscall", "nr": bo.SYS["clone3"], "args": [0, 0]},
    {"kind": "syscall", "nr": bo.SYS["pidfd_open"], "args": [0, 0]},
    # never filtered: proof the default really is allow
    {"kind": "syscall", "nr": bo.SYS["socket"], "args": [1, 1, 0]},   # AF_UNIX
]


def cases(root):
    ro = os.path.join(root, "ro")
    rw = os.path.join(root, "rw")
    wd = os.path.join(root, "workdir")
    return [
        ("ro+rw best_effort", {
            "filesystem_policy": {"read_only": [ro], "read_write": [rw],
                                  "include_workdir": False},
            "landlock": {"compatibility": "best_effort"}}, []),
        ("ro+rw hard_requirement", {
            "filesystem_policy": {"read_only": [ro], "read_write": [rw],
                                  "include_workdir": False},
            "landlock": {"compatibility": "hard_requirement"}}, []),
        ("read_only only", {
            "filesystem_policy": {"read_only": [ro], "include_workdir": False}}, []),
        ("read_write only", {
            "filesystem_policy": {"read_write": [rw], "include_workdir": False}}, []),
        ("include_workdir", {
            "filesystem_policy": {"read_only": [ro], "include_workdir": True}}, [wd]),
        ("include_workdir, workdir already in rw", {
            "filesystem_policy": {"read_only": [ro], "read_write": [wd],
                                  "include_workdir": True}}, [wd]),
        ("include_workdir false ignores workdir", {
            "filesystem_policy": {"read_only": [ro], "include_workdir": False}}, [wd]),
        ("no paths configured", {
            "filesystem_policy": {"include_workdir": False}}, []),
        ("missing path, best_effort", {
            "filesystem_policy": {"read_only": ["/no/such/path", ro],
                                  "include_workdir": False}}, []),
        ("all paths missing, best_effort", {
            "filesystem_policy": {"read_only": ["/no/such/path"],
                                  "include_workdir": False}}, []),
        ("device nodes and files", {
            "filesystem_policy": {"read_only": ["/dev/urandom", "/usr", "/etc", "/proc"],
                                  "read_write": ["/dev/null", rw],
                                  "include_workdir": False},
            "landlock": {"compatibility": "hard_requirement"}}, []),
        ("empty compatibility string defaults to best_effort", {
            "filesystem_policy": {"read_only": [ro], "include_workdir": False},
            "landlock": {"compatibility": ""}}, []),
        # A narrower rule INSIDE a wider one. Landlock resolves an access by
        # walking up from the object to the first matching rule, so which of the
        # two wins is a real semantic question and not an obvious one -- exactly
        # the kind of thing worth asking the kernel rather than reasoning about.
        ("read_only nested inside a read_write parent", {
            "filesystem_policy": {"read_only": [ro],
                                  "read_write": [root],
                                  "include_workdir": False},
            "landlock": {"compatibility": "hard_requirement"}}, []),
        ("read_write nested inside a read_only parent", {
            "filesystem_policy": {"read_only": [root],
                                  "read_write": [rw],
                                  "include_workdir": False},
            "landlock": {"compatibility": "hard_requirement"}}, []),
        ("nested path narrower than parent", {
            "filesystem_policy": {"read_only": [root],
                                  "read_write": [rw],
                                  "include_workdir": False}}, []),
    ]


# --- the two sides ---------------------------------------------------------

def run_rust(job):
    proc = subprocess.run([HARNESS], input=json.dumps(job), capture_output=True,
                          text=True, timeout=60)
    if proc.returncode != 0:
        raise RuntimeError("rust harness failed (%d): %s"
                           % (proc.returncode, proc.stderr.strip()))
    return json.loads(proc.stdout)


_ERRNO_NAMES = {
    errno.EACCES: "EACCES", errno.EPERM: "EPERM", errno.ENOENT: "ENOENT",
    errno.ENOSYS: "ENOSYS", errno.EINVAL: "EINVAL", errno.EISDIR: "EISDIR",
    errno.ENOTDIR: "ENOTDIR", errno.EBADF: "EBADF", errno.EFAULT: "EFAULT",
    errno.ESRCH: "ESRCH",
}


def _name(code):
    if code == 0:
        return "ok"
    return _ERRNO_NAMES.get(code, "errno%d" % code)


def _run_fs_probe(probe):
    path = probe["path"]
    op = probe["op"]
    try:
        if op == "read":
            os.close(os.open(path, os.O_RDONLY))
        elif op == "write":
            os.close(os.open(path, os.O_WRONLY))
        elif op == "create":
            os.close(os.open(path, os.O_WRONLY | os.O_CREAT, 0o644))
        elif op == "listdir":
            os.close(os.open(path, os.O_RDONLY | os.O_DIRECTORY))
        elif op == "truncate":
            os.truncate(path, 0)
        elif op == "mkdir":
            os.mkdir(path, 0o755)
        elif op == "unlink":
            os.unlink(path)
        elif op == "symlink":
            os.symlink("target", path)
        elif op == "exec":
            if not os.access(path, os.X_OK):
                return "EACCES"
        else:
            return "unknown-op"
        return "ok"
    except OSError as exc:
        return _name(exc.errno)


def run_python(job):
    """Apply the Python enforcement in a child and report the same probes.

    The result travels back over a pipe rather than an exit code: the child is
    behind a seccomp filter by then, and its stdout may be anything.
    """
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(read_fd)
        try:
            policy = bo.SandboxPolicy.from_json(job)
            # The Rust side applies OpenShell's own defaults for an absent
            # section, so force `present` to match for an apples-to-apples run.
            policy.filesystem.present = True
            prepared, outcome = bo.prepare(policy, workdir=job.get("workdir") or None)
            if job.get("apply_seccomp"):
                outcome = bo.enforce(prepared, outcome,
                                     supervisor_tgid=os.getppid(),
                                     child_hardening=False,
                                     allow_inet=job.get("allow_inet", True))
            else:
                bo.set_no_new_privs()
                outcome = bo.enforce_landlock(prepared, outcome)
            state, reason = outcome.state, outcome.reason
            applied, skipped = outcome.rules_applied, outcome.skipped
        except bo.PolicyError as exc:
            state, reason, applied, skipped = "failed", str(exc), 0, 0
        results = []
        for probe in job.get("probes", []):
            if probe["kind"] == "fs":
                results.append(_run_fs_probe(probe))
            else:
                ret, code = bo._syscall(probe["nr"], *probe["args"])
                results.append("ok" if ret >= 0 else _name(code))
        payload = json.dumps({
            "prepare": {"state": state, "reason": reason,
                        "rules_applied": applied, "skipped": skipped},
            "probes": results,
        }).encode()
        with os.fdopen(write_fd, "wb") as handle:
            handle.write(payload)
        os._exit(0)
    os.close(write_fd)
    with os.fdopen(read_fd, "rb") as handle:
        payload = handle.read()
    os.waitpid(pid, 0)
    if not payload:
        raise RuntimeError("python child produced nothing")
    return json.loads(payload)


def describe(probe):
    if probe["kind"] == "fs":
        return "%s(%s)" % (probe["op"], probe["path"])
    return "syscall(%d, %s)" % (probe["nr"], probe["args"])


STATE_EQUIVALENT = {
    # The Rust harness reports the hard_requirement failure as "failed";
    # bromure_openshell raises PolicyError, which the driver above renders the
    # same way. `off` vs `degraded` genuinely differ and are NOT equated.
}


def make_job(root, policy, workdir, apply_seccomp):
    """Build the job for one side against ITS OWN fixture tree.

    Several probes mutate the tree (mkdir, symlink, unlink), so the two sides
    must never share one: whichever ran second would see EEXIST/ENOENT from the
    other's writes and every run would report a difference that isn't one. The
    probe LISTS stay structurally identical, so index-by-index comparison still
    lines up.
    """
    job = dict(policy)
    job["workdir"] = workdir
    job["probes"] = probes_for(root) + (SYSCALL_PROBES if apply_seccomp else [])
    job["apply_seccomp"] = apply_seccomp
    return job


def _rebase(value, root):
    """Point a case's paths at `root`. Cases are written against a placeholder
    root; only paths under it move."""
    if isinstance(value, str):
        return value.replace(ROOT_PLACEHOLDER, root)
    if isinstance(value, list):
        return [_rebase(item, root) for item in value]
    if isinstance(value, dict):
        return {key: _rebase(item, root) for key, item in value.items()}
    return value


def main():
    keep_going = "--keep-going" in sys.argv
    if not os.path.exists(HARNESS):
        sys.exit("build the harness first: (cd %s && cargo build --release)" % HERE)

    failures = 0
    checked = 0
    for apply_seccomp in (False, True):
        rust_root = build_fixture()
        python_root = build_fixture()
        for name, policy, workdir in cases(ROOT_PLACEHOLDER):
            label = "%s%s" % (name, " +seccomp" if apply_seccomp else "")
            rust_job = make_job(rust_root, _rebase(policy, rust_root),
                                _rebase(workdir, rust_root), apply_seccomp)
            python_job = make_job(python_root, _rebase(policy, python_root),
                                  _rebase(workdir, python_root), apply_seccomp)
            probes = rust_job["probes"]

            rust = run_rust(rust_job)
            python = run_python(python_job)

            problems = []
            if rust["prepare"]["state"] != python["prepare"]["state"]:
                problems.append("  state: openshell=%s bromure=%s"
                                % (rust["prepare"]["state"], python["prepare"]["state"]))
            if rust["prepare"]["rules_applied"] != python["prepare"]["rules_applied"]:
                problems.append("  rules_applied: openshell=%d bromure=%d"
                                % (rust["prepare"]["rules_applied"],
                                   python["prepare"]["rules_applied"]))
            for index, probe in enumerate(probes):
                checked += 1
                left = rust["probes"][index]
                right = python["probes"][index]
                if left != right:
                    problems.append("  %s: openshell=%s bromure=%s"
                                    % (describe(probe), left, right))
            if problems:
                failures += 1
                print("FAIL %s" % label)
                for line in problems[:20]:
                    print(line)
                if len(problems) > 20:
                    print("  … %d more" % (len(problems) - 20))
                if not keep_going:
                    return 1
            else:
                print("ok   %s (%d probes)" % (label, len(probes)))

    print("\n%d probe comparisons, %d case(s) failed" % (checked, failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
