#!/usr/bin/env python3
"""bromure_openshell — OpenShell's Linux sandbox semantics, in pure Python.

This is a line-for-line reimplementation of the enforcement half of NVIDIA
OpenShell's `sandbox-linux` crate (`landlock.rs`, `seccomp.rs`), its
`process.rs::drop_privileges`, and `isolation-interface-linux/child_seccomp.rs`,
against the commit recorded in `openshell/COMMIT`.

Why Python and not the Rust crate: the code has to run inside the workspace VM,
from `bromure-agentd.py`'s world, with no build step, no toolchain in the image
and no cargo at boot. Everything below is ctypes against the same syscalls the
`landlock` and `seccompiler` crates issue, so the kernel sees byte-identical
requests. `differential/` holds a Rust harness that builds OpenShell's actual
crates and compares outcomes path-by-path and syscall-by-syscall.

Deliberate differences from OpenShell, each argued in DESIGN.md:

  * the architecture-mismatch branch of a compiled filter returns
    SECCOMP_RET_KILL_PROCESS where seccompiler returns SECCOMP_RET_KILL_THREAD.
    Unreachable on a single-arch aarch64 guest; strictly safer if ever reached.
  * the child self-protection filter's blanket denial of `kill(0, ...)` and
    `kill(<negative>, ...)` is narrowed to `kill(-1, ...)`, the supervisor's TGID
    and the supervisor's PGID. OpenShell's blanket rule exists so a workload
    cannot rejoin a trusted process group; Bromure gets that property from
    `setsid()` instead, and keeping the blanket rule would break POSIX job
    control (`kill %1` is `killpg`) in every interactive pane.
  * `allow_inet` is pinned true. OpenShell derives it from `network_policies`,
    which is not one of the three sections this work covers, and Bromure's
    egress control is the host MITM proxy plus attestd, not a socket-domain ban.

Nothing else diverges. Where OpenShell is surprising (an absent
`filesystem_policy` still enables Landlock, because `include_workdir` defaults
to true) this code is surprising in exactly the same way, and says so in the
status it reports to the host.
"""

import ctypes
import ctypes.util
import errno
import grp
import json
import os
import pwd
import resource
import stat
import struct
import sys

# ---------------------------------------------------------------------------
# libc
# ---------------------------------------------------------------------------

_libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
_libc.syscall.restype = ctypes.c_long


def _syscall(number, *args):
    """Raw syscall returning (retval, errno)."""
    ctypes.set_errno(0)
    argv = [ctypes.c_long(a) if isinstance(a, int) else a for a in args]
    ret = _libc.syscall(ctypes.c_long(number), *argv)
    return ret, ctypes.get_errno()


# aarch64 and x86_64 agree on all three Landlock syscall numbers.
SYS_landlock_create_ruleset = 444
SYS_landlock_add_rule = 445
SYS_landlock_restrict_self = 446

PR_SET_NO_NEW_PRIVS = 38
SECCOMP_SET_MODE_FILTER = 1
SECCOMP_FILTER_FLAG_TSYNC = 1
# The kernel calls `audit_seccomp` for a refused syscall only when the filter
# asked for it AND the action is in /proc/sys/kernel/seccomp/actions_logged.
# Without this flag a seccomp denial is invisible to everything -- there is no
# other signal a refused syscall leaves behind.
#
# **A divergence from OpenShell**, and a deliberate one: it changes nothing about
# what the filter ALLOWS or DENIES, only whether the kernel says so. The whole
# point of the sandbox is to be able to tell when an agent tries to leave it, and
# a denial nobody can observe is a denial nobody acts on. The differential suite
# compares probe OUTCOMES, which this cannot move.
SECCOMP_FILTER_FLAG_LOG = 2


# ---------------------------------------------------------------------------
# Policy model — openshell/core-policy.rs
# ---------------------------------------------------------------------------

BEST_EFFORT = "best_effort"
HARD_REQUIREMENT = "hard_requirement"


class PolicyError(Exception):
    """A hard_requirement failure. Fail closed."""


class FilesystemPolicy(object):
    """core-policy.rs::FilesystemPolicy.

    `present` is Bromure's, not OpenShell's. OpenShell's drivers always ship an
    explicit policy document, so `Default::default()` — `include_workdir: true`
    with empty lists — is never what a real workload runs under. Bromure ships
    none, and an absent section there would mean "Landlock on, workdir only, no
    /usr", i.e. a workspace where nothing can exec. So an absent section is a
    *skip* here, and `present` is what records the difference. When the section
    IS present, every field below follows OpenShell exactly, including
    `include_workdir` defaulting to true.
    """

    def __init__(self, read_only=None, read_write=None, include_workdir=True,
                 present=True):
        self.read_only = list(read_only or [])
        self.read_write = list(read_write or [])
        self.include_workdir = bool(include_workdir)
        self.present = present

    @classmethod
    def from_json(cls, obj):
        if obj is None:
            return cls(present=False)
        return cls(
            read_only=obj.get("read_only") or [],
            read_write=obj.get("read_write") or [],
            # An explicit section that omits the key still defaults to true.
            include_workdir=obj.get("include_workdir", True),
            present=True,
        )


class LandlockPolicy(object):
    """core-policy.rs::LandlockPolicy."""

    def __init__(self, compatibility=BEST_EFFORT):
        self.compatibility = compatibility

    @classmethod
    def from_json(cls, obj):
        if obj is None:
            return cls()
        value = obj.get("compatibility") or ""
        # is_valid_landlock_compatibility: the empty string means best_effort.
        if value == "":
            value = BEST_EFFORT
        if value not in (BEST_EFFORT, HARD_REQUIREMENT):
            raise PolicyError("invalid landlock.compatibility: %r" % (value,))
        return cls(compatibility=value)


class ProcessPolicy(object):
    """core-policy.rs::ProcessPolicy."""

    def __init__(self, run_as_user=None, run_as_group=None, present=True):
        self.run_as_user = run_as_user
        self.run_as_group = run_as_group
        self.present = present

    @classmethod
    def from_json(cls, obj):
        if obj is None:
            return cls(present=False)
        return cls(run_as_user=obj.get("run_as_user"),
                   run_as_group=obj.get("run_as_group"), present=True)


class SandboxPolicy(object):
    def __init__(self, filesystem=None, landlock=None, process=None, version=1):
        self.version = version
        self.filesystem = filesystem or FilesystemPolicy()
        self.landlock = landlock or LandlockPolicy()
        self.process = process or ProcessPolicy()

    @classmethod
    def from_json(cls, obj):
        return cls(
            version=obj.get("version", 1),
            filesystem=FilesystemPolicy.from_json(obj.get("filesystem_policy")),
            landlock=LandlockPolicy.from_json(obj.get("landlock")),
            process=ProcessPolicy.from_json(obj.get("process")),
        )


# ---------------------------------------------------------------------------
# Landlock — openshell/sandbox-linux/landlock.rs
# ---------------------------------------------------------------------------

# linux/landlock.h access bits.
LANDLOCK_ACCESS_FS_EXECUTE = 1 << 0
LANDLOCK_ACCESS_FS_WRITE_FILE = 1 << 1
LANDLOCK_ACCESS_FS_READ_FILE = 1 << 2
LANDLOCK_ACCESS_FS_READ_DIR = 1 << 3
LANDLOCK_ACCESS_FS_REMOVE_DIR = 1 << 4
LANDLOCK_ACCESS_FS_REMOVE_FILE = 1 << 5
LANDLOCK_ACCESS_FS_MAKE_CHAR = 1 << 6
LANDLOCK_ACCESS_FS_MAKE_DIR = 1 << 7
LANDLOCK_ACCESS_FS_MAKE_REG = 1 << 8
LANDLOCK_ACCESS_FS_MAKE_SOCK = 1 << 9
LANDLOCK_ACCESS_FS_MAKE_FIFO = 1 << 10
LANDLOCK_ACCESS_FS_MAKE_BLOCK = 1 << 11
LANDLOCK_ACCESS_FS_MAKE_SYM = 1 << 12
LANDLOCK_ACCESS_FS_REFER = 1 << 13
LANDLOCK_ACCESS_FS_TRUNCATE = 1 << 14
LANDLOCK_ACCESS_FS_IOCTL_DEV = 1 << 15

LANDLOCK_RULE_PATH_BENEATH = 1
LANDLOCK_CREATE_RULESET_VERSION = 1 << 0

# The landlock crate's ABI ladder (`AccessFs::from_read` / `from_write`), which
# is what decides the bits OpenShell actually asks the kernel for.
_ACCESS_READ = (LANDLOCK_ACCESS_FS_EXECUTE
                | LANDLOCK_ACCESS_FS_READ_FILE
                | LANDLOCK_ACCESS_FS_READ_DIR)

_WRITE_V1 = (LANDLOCK_ACCESS_FS_WRITE_FILE
             | LANDLOCK_ACCESS_FS_REMOVE_DIR
             | LANDLOCK_ACCESS_FS_REMOVE_FILE
             | LANDLOCK_ACCESS_FS_MAKE_CHAR
             | LANDLOCK_ACCESS_FS_MAKE_DIR
             | LANDLOCK_ACCESS_FS_MAKE_REG
             | LANDLOCK_ACCESS_FS_MAKE_SOCK
             | LANDLOCK_ACCESS_FS_MAKE_FIFO
             | LANDLOCK_ACCESS_FS_MAKE_BLOCK
             | LANDLOCK_ACCESS_FS_MAKE_SYM)

_WRITE_BY_ABI = {
    1: _WRITE_V1,
    2: _WRITE_V1 | LANDLOCK_ACCESS_FS_REFER,
    3: _WRITE_V1 | LANDLOCK_ACCESS_FS_REFER | LANDLOCK_ACCESS_FS_TRUNCATE,
    4: _WRITE_V1 | LANDLOCK_ACCESS_FS_REFER | LANDLOCK_ACCESS_FS_TRUNCATE,
    5: (_WRITE_V1 | LANDLOCK_ACCESS_FS_REFER | LANDLOCK_ACCESS_FS_TRUNCATE
        | LANDLOCK_ACCESS_FS_IOCTL_DEV),
}

# `ACCESS_FILE` in the landlock crate: the rights meaningful on a non-directory.
_ACCESS_FILE = (LANDLOCK_ACCESS_FS_EXECUTE
                | LANDLOCK_ACCESS_FS_WRITE_FILE
                | LANDLOCK_ACCESS_FS_READ_FILE
                | LANDLOCK_ACCESS_FS_TRUNCATE
                | LANDLOCK_ACCESS_FS_IOCTL_DEV)

# OpenShell pins ABI::V3 for both the optional filesystem policy and the
# mandatory capability-free baseline ("Read-only policy must also deny pathname
# truncation"). It never asks for V4/V5 filesystem rights.
OPENSHELL_ABI = 3


def access_from_read(abi=OPENSHELL_ABI):
    return 0 if abi < 1 else _ACCESS_READ


def access_from_write(abi=OPENSHELL_ABI):
    return _WRITE_BY_ABI.get(abi, 0) if abi >= 1 else 0


def access_from_all(abi=OPENSHELL_ABI):
    return access_from_read(abi) | access_from_write(abi)


def access_from_file(abi=OPENSHELL_ABI):
    return access_from_all(abi) & _ACCESS_FILE


class LandlockAvailability(object):
    """landlock.rs::LandlockAvailability."""

    AVAILABLE = "available"
    NOT_IMPLEMENTED = "not_implemented"
    NOT_ENABLED = "not_enabled"
    BLOCKED = "blocked"
    UNKNOWN = "unknown"

    def __init__(self, kind, abi=None, raw_errno=None):
        self.kind = kind
        self.abi = abi
        self.raw_errno = raw_errno

    @property
    def is_available(self):
        return self.kind == self.AVAILABLE

    def __str__(self):
        if self.kind == self.AVAILABLE:
            return "available (ABI v%d)" % self.abi
        if self.kind == self.NOT_IMPLEMENTED:
            return "not implemented (kernel lacks CONFIG_SECURITY_LANDLOCK)"
        if self.kind == self.NOT_ENABLED:
            return ("not enabled (Landlock built into kernel but not in active "
                    "LSM list)")
        if self.kind == self.BLOCKED:
            return "blocked (container seccomp profile denies Landlock syscalls)"
        return "unexpected probe error (errno %s)" % self.raw_errno


def probe_availability():
    """landlock.rs::probe_availability — read-only ABI probe."""
    ret, err = _syscall(SYS_landlock_create_ruleset, None, 0,
                        LANDLOCK_CREATE_RULESET_VERSION)
    if ret >= 0:
        return LandlockAvailability(LandlockAvailability.AVAILABLE, abi=int(ret))
    if err == errno.ENOSYS:
        return LandlockAvailability(LandlockAvailability.NOT_IMPLEMENTED)
    if err == errno.EOPNOTSUPP:
        return LandlockAvailability(LandlockAvailability.NOT_ENABLED)
    if err == errno.EPERM:
        return LandlockAvailability(LandlockAvailability.BLOCKED)
    return LandlockAvailability(LandlockAvailability.UNKNOWN, raw_errno=err)


def _classify_io_error(exc):
    """landlock.rs::classify_io_error."""
    code = getattr(exc, "errno", None)
    if code == errno.ENOENT:
        return "path does not exist"
    if code in (errno.EACCES, errno.EPERM):
        return "permission denied"
    if code == errno.ELOOP:
        return "too many symlink levels"
    if code == errno.ENAMETOOLONG:
        return "path name too long"
    if code == errno.ENOTDIR:
        return "path component is not a directory"
    return "unexpected error"


class PreparedRuleset(object):
    """A ruleset fd created but not yet enforced (landlock.rs::PreparedRuleset).

    The fd and the compatibility level travel together because `enforce()`
    degrades on `best_effort` exactly as `landlock.rs::enforce` does.
    """

    def __init__(self, fd, compatibility, rules_applied, skipped, handled_access):
        self.fd = fd
        self.compatibility = compatibility
        self.rules_applied = rules_applied
        self.skipped = skipped
        self.handled_access = handled_access

    def close(self):
        if self.fd is not None and self.fd >= 0:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None


PRIVILEGED = "privileged"
CURRENT_USER = "current_user"


def _create_ruleset(handled_access_fs):
    """landlock_create_ruleset with only `handled_access_fs` set.

    The attr struct is passed at its ABI-v1 size (8 bytes). The kernel's
    `copy_min_struct_from_user` accepts any size at or above the v1 size, so
    one call shape works on every Landlock ABI — including the ABI 1-3 kernels
    where a 16-byte v4 struct would be rejected with E2BIG.
    """
    attr = struct.pack("=Q", handled_access_fs)
    buf = ctypes.create_string_buffer(attr, len(attr))
    ret, err = _syscall(SYS_landlock_create_ruleset, buf, len(attr), 0)
    if ret < 0:
        raise OSError(err, os.strerror(err), "landlock_create_ruleset")
    return int(ret)


def _add_path_beneath(ruleset_fd, parent_fd, allowed_access):
    """landlock_add_rule(LANDLOCK_RULE_PATH_BENEATH).

    `struct landlock_path_beneath_attr` is __packed__: u64 then s32, 12 bytes.
    """
    attr = struct.pack("=Qi", allowed_access, parent_fd)
    buf = ctypes.create_string_buffer(attr, len(attr))
    ret, err = _syscall(SYS_landlock_add_rule, ruleset_fd,
                        LANDLOCK_RULE_PATH_BENEATH, buf, 0)
    if ret < 0:
        raise OSError(err, os.strerror(err), "landlock_add_rule")


def _restrict_self(ruleset_fd):
    ret, err = _syscall(SYS_landlock_restrict_self, ruleset_fd, 0)
    if ret < 0:
        raise OSError(err, os.strerror(err), "landlock_restrict_self")


def _access_for_path_fd(path_fd, requested_access, abi=OPENSHELL_ABI):
    """landlock.rs::access_for_path_fd.

    Directory-only rights are invalid on a regular file or device node in
    hard-requirement mode, so the mask is narrowed through the very fd the rule
    will use — no pathname TOCTOU window.
    """
    st = os.fstat(path_fd)
    if stat.S_ISDIR(st.st_mode):
        return requested_access
    return requested_access & access_from_file(abi)


class LandlockOutcome(object):
    """What actually happened, for the status line the host is shown."""

    ENFORCED = "enforced"
    DEGRADED = "degraded"
    FAILED = "failed"
    OFF = "off"

    def __init__(self, state, reason=None, abi=None, rules_applied=0, skipped=0):
        self.state = state
        self.reason = reason
        self.abi = abi
        self.rules_applied = rules_applied
        self.skipped = skipped


def _try_open_path(path, compatibility, path_open_mode, notes):
    """landlock.rs::try_open_path — O_PATH|O_CLOEXEC, with OpenShell's
    per-mode and per-compatibility treatment of every failure."""
    try:
        return os.open(path, os.O_PATH | os.O_CLOEXEC)
    except OSError as exc:
        reason = _classify_io_error(exc)
        is_not_found = exc.errno == errno.ENOENT
        if path_open_mode == CURRENT_USER:
            # Already unreachable for this uid: omitting it from the allowlist
            # is the same restriction, so never fail on it.
            if not is_not_found:
                notes.append("already-denied: %s (%s)" % (path, reason))
            return None
        if compatibility == BEST_EFFORT:
            if not is_not_found:
                notes.append("skipped inaccessible path: %s (%s)" % (path, reason))
            return None
        raise PolicyError(
            "Landlock path unavailable in hard_requirement mode: %s (%s): %s"
            % (path, reason, exc))


def prepare(policy, workdir=None, path_open_mode=PRIVILEGED, extra_read_only=(),
            extra_read_write=()):
    """landlock.rs::prepare_with_path_open_mode.

    `extra_read_only` / `extra_read_write` are Bromure's documented additions
    layer — the plumbing paths the VM cannot function without. They are kept in
    separate arguments, never merged into the policy object, so the status sent
    to the host can always show the user's policy and Bromure's additions apart.
    They are appended after the user's lists and are subject to exactly the same
    open/classify/compatibility rules.

    Returns (PreparedRuleset | None, LandlockOutcome). `None` means "run without
    Landlock", which is a skip (no paths) or a best-effort degradation.
    """
    notes = []
    if not policy.filesystem.present:
        # Bromure divergence (DESIGN.md §"Absent sections"): no section, no
        # Landlock. OpenShell would apply `include_workdir: true` here.
        return None, LandlockOutcome(LandlockOutcome.OFF,
                                     reason="filesystem_policy not configured")
    read_only = list(policy.filesystem.read_only)
    read_write = list(policy.filesystem.read_write)

    # include_workdir: the single implicit path OpenShell ever adds. Bromure
    # can be given several workdirs (one per project folder); each is appended
    # under the same de-duplication rule OpenShell applies to its one workdir.
    if policy.filesystem.include_workdir and workdir:
        dirs = [workdir] if isinstance(workdir, str) else list(workdir)
        for d in dirs:
            if d and d not in read_write:
                read_write.append(d)

    user_paths = len(read_only) + len(read_write)

    # "no paths configured" skip. Evaluated on the USER's policy alone: if the
    # user asked for no filesystem restriction, Bromure's additions must not
    # conjure a ruleset into existence and lock the workspace down.
    if user_paths == 0:
        return None, LandlockOutcome(LandlockOutcome.OFF,
                                     reason="no paths configured")

    compatibility = policy.landlock.compatibility
    availability = probe_availability()
    if not availability.is_available:
        if compatibility == BEST_EFFORT:
            return None, LandlockOutcome(
                LandlockOutcome.DEGRADED,
                reason="Landlock filesystem sandbox unavailable: %s" % availability)
        raise PolicyError(
            "Landlock unavailable in hard_requirement mode: %s" % availability)

    kernel_abi = availability.abi
    abi = OPENSHELL_ABI
    access_all = access_from_all(abi)
    access_read = access_from_read(abi)

    # CompatLevel: the landlock crate downgrades the handled set to what the
    # kernel supports under BestEffort, and refuses under HardRequirement.
    supported = access_from_all(min(kernel_abi, 5)) if kernel_abi >= 1 else 0
    handled = access_all & supported
    if handled != access_all:
        missing = access_all & ~supported
        if compatibility == HARD_REQUIREMENT:
            raise PolicyError(
                "Landlock kernel ABI v%d cannot handle the requested access "
                "rights (missing 0x%x) in hard_requirement mode"
                % (kernel_abi, missing))
        notes.append("downgraded handled access to kernel ABI v%d (dropped 0x%x)"
                     % (kernel_abi, missing))

    ruleset_fd = _create_ruleset(handled)
    prepared = PreparedRuleset(ruleset_fd, compatibility, 0, 0, handled)
    rules_applied = 0
    opened = []
    try:
        user_groups = ([(p, access_read) for p in read_only]
                       + [(p, access_all) for p in read_write])
        addition_groups = ([(p, access_read) for p in extra_read_only]
                           + [(p, access_all) for p in extra_read_write])
        groups = user_groups + addition_groups
        total_paths = len(groups)
        user_rules_applied = 0
        for index, (path, requested) in enumerate(groups):
            path_fd = _try_open_path(path, compatibility, path_open_mode, notes)
            if path_fd is None:
                continue
            opened.append(path_fd)
            allowed = _access_for_path_fd(path_fd, requested & handled, abi)
            if allowed == 0:
                # A non-directory with nothing but directory rights requested.
                # The kernel rejects allowed_access == 0 with EINVAL; OpenShell
                # never reaches this because from_read/from_all always retain a
                # file right. Treat it as a skipped path rather than a crash.
                notes.append("no applicable access rights for %s" % path)
                continue
            _add_path_beneath(ruleset_fd, path_fd, allowed)
            rules_applied += 1
            if index < len(user_groups):
                user_rules_applied += 1

        # OpenShell's zero-valid-paths refusal, evaluated on the USER's paths
        # alone. Bromure's additions always resolve (they are our own plumbing),
        # so counting them here would turn "none of the policy's paths exist"
        # into a ruleset that silently allows nothing but /dev/pts and the tmux
        # socket — an enforced-looking sandbox that denies the whole workspace.
        if user_rules_applied == 0:
            raise PolicyError(
                "Landlock ruleset has zero valid paths — all %d path(s) failed "
                "to open. Refusing to apply an empty ruleset that would block "
                "all filesystem access." % len(user_groups))
    except PolicyError as exc:
        prepared.close()
        if compatibility == BEST_EFFORT:
            return None, LandlockOutcome(LandlockOutcome.DEGRADED,
                                         reason=str(exc), abi=kernel_abi)
        raise
    except OSError as exc:
        prepared.close()
        if compatibility == BEST_EFFORT:
            return None, LandlockOutcome(LandlockOutcome.DEGRADED,
                                         reason=str(exc), abi=kernel_abi)
        raise PolicyError("Landlock ruleset construction failed: %s" % exc)
    finally:
        for fd in opened:
            try:
                os.close(fd)
            except OSError:
                pass

    prepared.rules_applied = rules_applied
    prepared.skipped = total_paths - rules_applied
    outcome = LandlockOutcome(LandlockOutcome.ENFORCED, abi=kernel_abi,
                              rules_applied=rules_applied,
                              skipped=total_paths - rules_applied,
                              reason="; ".join(notes) or None)
    return prepared, outcome


def enforce_landlock(prepared, outcome):
    """landlock.rs::enforce — restrict_self, degrading on best_effort."""
    if prepared is None:
        return outcome
    try:
        _restrict_self(prepared.fd)
    except OSError as exc:
        if prepared.compatibility == BEST_EFFORT:
            return LandlockOutcome(
                LandlockOutcome.DEGRADED,
                reason="restrict_self failed (best_effort): %s" % exc,
                abi=outcome.abi)
        raise PolicyError("Landlock restrict_self failed: %s" % exc)
    finally:
        prepared.close()
    return outcome


# ---------------------------------------------------------------------------
# cBPF assembler
# ---------------------------------------------------------------------------
#
# seccompiler emits classic BPF; so does this. The shapes differ (seccompiler
# builds a balanced jump table, this builds a linear chain) but the accepted
# language is identical, which is what `differential/` actually checks: the same
# syscall with the same arguments must get the same answer from both programs.

BPF_LD = 0x00
BPF_W = 0x00
BPF_ABS = 0x20
BPF_JMP = 0x05
BPF_JEQ = 0x10
BPF_JSET = 0x40
BPF_JA = 0x00
BPF_K = 0x00
BPF_RET = 0x06
BPF_ALU = 0x04
BPF_AND = 0x50

SECCOMP_RET_KILL_PROCESS = 0x80000000
SECCOMP_RET_KILL_THREAD = 0x00000000
SECCOMP_RET_ERRNO = 0x00050000
SECCOMP_RET_ALLOW = 0x7FFF0000

SECCOMP_DATA_NR_OFFSET = 0
SECCOMP_DATA_ARCH_OFFSET = 4
SECCOMP_DATA_ARGS_OFFSET = 16

AUDIT_ARCH_AARCH64 = 0xC00000B7
AUDIT_ARCH_X86_64 = 0xC000003E
X32_SYSCALL_BIT = 0x40000000

BPF_MAXINSNS = 4096


def _audit_arch():
    machine = os.uname().machine
    if machine == "aarch64":
        return AUDIT_ARCH_AARCH64
    if machine == "x86_64":
        return AUDIT_ARCH_X86_64
    raise PolicyError("unsupported architecture for seccomp: %s" % machine)


def _arg_low_offset(index):
    """Little-endian low dword of seccomp_data.args[index].

    Every condition OpenShell builds uses `SeccompCmpArgLen::Dword`, which
    compares this word only. Reproduced rather than widened: a 64-bit compare
    would reject calls OpenShell lets through.
    """
    return SECCOMP_DATA_ARGS_OFFSET + 8 * index


class _Asm(object):
    """Two-pass assembler. Instructions carry symbolic jump targets; labels
    resolve to indices; every jump that could exceed a u8 displacement is
    emitted as a `ja` so the filter never silently truncates."""

    def __init__(self):
        self.items = []      # (kind, ...)
        self.labels = {}

    def label(self, name):
        self.labels[name] = len(self.items)

    def stmt(self, code, k):
        self.items.append(("stmt", code, k))

    def ret(self, k):
        self.items.append(("stmt", BPF_RET | BPF_K, k))

    def jeq(self, k, jt_label, jf_label):
        self.items.append(("jmp", BPF_JMP | BPF_JEQ | BPF_K, k, jt_label, jf_label))

    def jset(self, k, jt_label, jf_label):
        self.items.append(("jmp", BPF_JMP | BPF_JSET | BPF_K, k, jt_label, jf_label))

    def ja(self, target):
        self.items.append(("ja", target))

    def assemble(self):
        # Pass 1 assigned indices as items were appended; every item is exactly
        # one instruction, so `self.labels` is already the instruction map.
        out = []
        for index, item in enumerate(self.items):
            if item[0] == "stmt":
                out.append(struct.pack("=HBBI", item[1], 0, 0, item[2] & 0xFFFFFFFF))
            elif item[0] == "ja":
                target = self.labels[item[1]]
                offset = target - index - 1
                if offset < 0:
                    raise PolicyError("backward jump in seccomp filter")
                out.append(struct.pack("=HBBI", BPF_JMP | BPF_JA | BPF_K, 0, 0, offset))
            else:
                _, code, k, jt_label, jf_label = item
                jt = self.labels[jt_label] - index - 1
                jf = self.labels[jf_label] - index - 1
                if not (0 <= jt <= 255 and 0 <= jf <= 255):
                    raise PolicyError(
                        "seccomp jump displacement out of range (jt=%d jf=%d); "
                        "the emitter must route this through `ja`" % (jt, jf))
                out.append(struct.pack("=HBBI", code, jt, jf, k & 0xFFFFFFFF))
        if len(out) > BPF_MAXINSNS:
            raise PolicyError("seccomp filter too large: %d instructions (max %d)"
                              % (len(out), BPF_MAXINSNS))
        return b"".join(out)


# A condition is (arg_index, op, value) where op is one of these.
OP_EQ = "eq"
OP_NE = "ne"
OP_MASKED_EQ = "masked_eq"   # value is (mask, expected)


def _emit_condition(asm, condition, match_label, next_label, uid):
    """Emit one condition: fall through to `match_label` when it holds,
    otherwise jump to `next_label`."""
    arg_index, op, value = condition
    asm.stmt(BPF_LD | BPF_W | BPF_ABS, _arg_low_offset(arg_index))
    if op == OP_EQ:
        asm.jeq(value, match_label, next_label)
    elif op == OP_NE:
        asm.jeq(value, next_label, match_label)
    elif op == OP_MASKED_EQ:
        mask, expected = value
        asm.stmt(BPF_ALU | BPF_AND | BPF_K, mask)
        asm.jeq(expected, match_label, next_label)
    else:
        raise PolicyError("unknown seccomp condition op: %r" % (op,))


def compile_filter(rules, blocked_action, arch_mismatch_action=SECCOMP_RET_KILL_PROCESS):
    """seccomp.rs::compile_filter.

    `rules` maps a syscall number to a list of rules. Each rule is a list of
    AND'd conditions; rules for the same syscall are OR'd. An EMPTY rule list
    means "block this syscall unconditionally" — the same convention
    seccompiler uses and OpenShell relies on throughout (`rules.entry(nr).or_default()`).

    Default action is Allow; `blocked_action` is what a matching rule returns.
    """
    asm = _Asm()
    uid = [0]

    def fresh(prefix):
        uid[0] += 1
        return "%s%d" % (prefix, uid[0])

    # Architecture validation, exactly seccompiler's VALIDATE_ARCHITECTURE
    # preamble (with KILL_PROCESS in place of KILL_THREAD — see module docstring).
    arch_ok = fresh("arch_ok")
    asm.stmt(BPF_LD | BPF_W | BPF_ABS, SECCOMP_DATA_ARCH_OFFSET)
    asm.jeq(_audit_arch(), arch_ok, "arch_bad")
    asm.label("arch_bad")
    asm.ret(arch_mismatch_action)
    asm.label(arch_ok)

    if os.uname().machine == "x86_64":
        # child_seccomp.rs rejects the x32 ABI, whose syscall numbers alias the
        # 64-bit ones. Harmless on aarch64, kept so the emitter is portable.
        x32_ok = fresh("x32_ok")
        asm.stmt(BPF_LD | BPF_W | BPF_ABS, SECCOMP_DATA_NR_OFFSET)
        asm.jset(X32_SYSCALL_BIT, "x32_bad", x32_ok)
        asm.label("x32_bad")
        asm.ret(SECCOMP_RET_KILL_PROCESS)
        asm.label(x32_ok)

    for syscall_nr in sorted(rules):
        rule_list = rules[syscall_nr]
        block_end = fresh("end")
        body = fresh("body")
        # Reload the syscall number for every dispatch. The accumulator holds
        # the arch word after the preamble, and each condition below clobbers
        # it with an argument word, so it is never live across a block.
        asm.stmt(BPF_LD | BPF_W | BPF_ABS, SECCOMP_DATA_NR_OFFSET)
        # `jeq nr → body, else → skip`, with the skip routed through `ja` so a
        # long block can never overflow the 8-bit displacement.
        skip = fresh("skip")
        asm.jeq(syscall_nr, body, skip)
        asm.label(skip)
        asm.ja(block_end)
        asm.label(body)

        if not rule_list:
            asm.ret(blocked_action)
        else:
            for rule in rule_list:
                next_rule = fresh("rule")
                for position, condition in enumerate(rule):
                    is_last = position == len(rule) - 1
                    match_label = fresh("cond")
                    _emit_condition(asm, condition, match_label, next_rule, uid)
                    asm.label(match_label)
                    if is_last:
                        asm.ret(blocked_action)
                asm.label(next_rule)
            asm.ja(block_end)
        asm.label(block_end)

    asm.ret(SECCOMP_RET_ALLOW)
    return asm.assemble()


def set_no_new_privs():
    """seccomp.rs::set_no_new_privs — prctl(PR_SET_NO_NEW_PRIVS, 1).

    Irreversible for this process and every descendant. It is also what makes
    `seccomp(SECCOMP_SET_MODE_FILTER)` legal without CAP_SYS_ADMIN, so it must
    precede every filter installation.
    """
    ctypes.set_errno(0)
    rc = _libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)
    if rc != 0:
        err = ctypes.get_errno()
        raise PolicyError("Failed to set no_new_privs: %s" % os.strerror(err))


def install_filter(program, tsync=False, log=True):
    """seccomp(SECCOMP_SET_MODE_FILTER, flags, &sock_fprog).

    `log` adds SECCOMP_FILTER_FLAG_LOG, which is what makes a refused syscall
    observable at all (see the constant). It is requested best-effort: a kernel
    that does not support the flag returns EINVAL for the whole call, and a
    sandbox that refuses to install because it could not also be *logged* would
    be trading enforcement for telemetry. So the flag is dropped and the filter
    goes on.
    """
    count = len(program) // 8
    buf = ctypes.create_string_buffer(program, len(program))
    fprog = struct.pack("@H6xP", count, ctypes.cast(buf, ctypes.c_void_p).value)
    fprog_buf = ctypes.create_string_buffer(fprog, len(fprog))
    base = SECCOMP_FILTER_FLAG_TSYNC if tsync else 0
    flags = base | (SECCOMP_FILTER_FLAG_LOG if log else 0)
    ret, err = _syscall(_SYS_seccomp, SECCOMP_SET_MODE_FILTER, flags, fprog_buf)
    if ret < 0 and flags != base:
        ret, err = _syscall(_SYS_seccomp, SECCOMP_SET_MODE_FILTER, base,
                            fprog_buf)
    if ret < 0:
        raise PolicyError("seccomp(SET_MODE_FILTER) failed: %s" % os.strerror(err))


# ---------------------------------------------------------------------------
# Syscall numbers
# ---------------------------------------------------------------------------
#
# Hardcoded rather than resolved through libc: a seccomp filter that silently
# loses a rule because a name didn't resolve is a filter that silently stops
# blocking something. `tests/test_syscall_table.py` compiles <asm/unistd.h> and
# asserts every number below matches the kernel headers for the running arch.

_SYSCALLS_AARCH64 = {
    "seccomp": 277, "socket": 198, "memfd_create": 279, "ptrace": 117, "bpf": 280,
    "process_vm_readv": 270, "process_vm_writev": 271, "pidfd_getfd": 438,
    "pidfd_send_signal": 424, "io_uring_setup": 425, "io_uring_enter": 426,
    "io_uring_register": 427, "mount": 40, "fsopen": 430, "fsconfig": 431,
    "fsmount": 432, "fspick": 433, "move_mount": 429, "open_tree": 428,
    "setns": 268, "umount2": 39, "pivot_root": 41, "userfaultfd": 282,
    "perf_event_open": 241, "execveat": 281, "unshare": 97, "clone": 220,
    "clone3": 435, "pidfd_open": 434, "kcmp": 272, "process_madvise": 440,
    "process_mrelease": 448, "chroot": 51, "capset": 91, "setuid": 146,
    "setgid": 144, "setreuid": 145, "setregid": 143, "setresuid": 147,
    "setresgid": 149, "setfsuid": 151, "setfsgid": 152, "setgroups": 159,
    "sethostname": 161, "setdomainname": 162, "setpriority": 140,
    "ioprio_set": 30, "kill": 129, "tkill": 130, "tgkill": 131,
    "rt_sigqueueinfo": 138, "rt_tgsigqueueinfo": 240, "prlimit64": 261,
    "sched_setaffinity": 122, "sched_setattr": 274, "sched_setparam": 118,
    "sched_setscheduler": 119, "close_range": 436, "fcntl": 25, "ioctl": 29,
    "init_module": 105, "finit_module": 273, "delete_module": 106,
    "kexec_load": 104, "kexec_file_load": 294,
}

_SYSCALLS_X86_64 = {
    "seccomp": 317, "socket": 41, "memfd_create": 319, "ptrace": 101, "bpf": 321,
    "process_vm_readv": 310, "process_vm_writev": 311, "pidfd_getfd": 438,
    "pidfd_send_signal": 424, "io_uring_setup": 425, "io_uring_enter": 426,
    "io_uring_register": 427, "mount": 165, "fsopen": 430, "fsconfig": 431,
    "fsmount": 432, "fspick": 433, "move_mount": 429, "open_tree": 428,
    "setns": 308, "umount2": 166, "pivot_root": 155, "userfaultfd": 323,
    "perf_event_open": 298, "execveat": 322, "unshare": 272, "clone": 56,
    "clone3": 435, "pidfd_open": 434, "kcmp": 312, "process_madvise": 440,
    "process_mrelease": 448, "chroot": 161, "capset": 126, "setuid": 105,
    "setgid": 106, "setreuid": 113, "setregid": 114, "setresuid": 117,
    "setresgid": 119, "setfsuid": 122, "setfsgid": 123, "setgroups": 116,
    "sethostname": 170, "setdomainname": 171, "setpriority": 141,
    "ioprio_set": 251, "kill": 62, "tkill": 200, "tgkill": 234,
    "rt_sigqueueinfo": 129, "rt_tgsigqueueinfo": 297, "prlimit64": 302,
    "sched_setaffinity": 203, "sched_setattr": 314, "sched_setparam": 142,
    "sched_setscheduler": 144, "close_range": 436, "fcntl": 72, "ioctl": 16,
    "init_module": 175, "finit_module": 313, "delete_module": 176,
    "kexec_load": 246, "kexec_file_load": 320,
}

SYS = (_SYSCALLS_AARCH64 if os.uname().machine == "aarch64"
       else _SYSCALLS_X86_64 if os.uname().machine == "x86_64" else None)
if SYS is None:
    raise PolicyError("unsupported architecture: %s" % os.uname().machine)

_SYS_seccomp = SYS["seccomp"]

# Socket domains and clone/exec flags the filters key off.
AF_INET, AF_INET6, AF_NETLINK, AF_PACKET, AF_BLUETOOTH, AF_VSOCK = 2, 10, 16, 17, 31, 40
AT_EMPTY_PATH = 0x1000
CLONE_NEWNS = 0x00020000
CLONE_NEWCGROUP = 0x02000000
CLONE_NEWUTS = 0x04000000
CLONE_NEWIPC = 0x08000000
CLONE_NEWUSER = 0x10000000
CLONE_NEWPID = 0x20000000
CLONE_NEWNET = 0x40000000
CLONE_NAMESPACE_FLAGS = (CLONE_NEWCGROUP | CLONE_NEWIPC | CLONE_NEWNET
                         | CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWUSER
                         | CLONE_NEWUTS)
CLOSE_RANGE_UNSHARE = 1 << 1
F_SETOWN, F_SETSIG, F_SETOWN_EX = 8, 10, 15
FIOSETOWN, SIOCSPGRP = 0x8901, 0x8902
NETLINK_ROUTE = 0


# ---------------------------------------------------------------------------
# The three filters — seccomp.rs and child_seccomp.rs
# ---------------------------------------------------------------------------

def build_main_filter_rules(allow_inet=True):
    """seccomp.rs::build_filter_rules.

    Default-allow with targeted blocks. `allow_inet` is pinned true by
    `apply_seccomp` (see module docstring); the parameter exists so the
    differential harness can exercise both arms.
    """
    rules = {}

    def entry(nr):
        return rules.setdefault(nr, [])

    # --- Socket domain blocks ---
    blocked_domains = [AF_PACKET, AF_BLUETOOTH, AF_VSOCK]
    if not allow_inet:
        blocked_domains += [AF_INET, AF_INET6]
    for domain in blocked_domains:
        entry(SYS["socket"]).append([(0, OP_EQ, domain)])

    # AF_NETLINK only for NETLINK_ROUTE (protocol 0): getifaddrs(3) needs it,
    # and every write through it still wants CAP_NET_ADMIN, which is gone.
    entry(SYS["socket"]).append([(0, OP_EQ, AF_NETLINK), (2, OP_NE, NETLINK_ROUTE)])

    # --- Unconditional blocks ---
    for name in ("memfd_create",        # fileless exec bypasses Landlock
                 "ptrace",              # cross-process inspection / injection
                 "bpf",
                 "process_vm_readv", "process_vm_writev",
                 "pidfd_getfd", "pidfd_send_signal",
                 "io_uring_setup",
                 "mount", "fsopen", "fsconfig", "fsmount", "fspick",
                 "move_mount", "open_tree",
                 "setns", "umount2", "pivot_root",
                 "userfaultfd", "perf_event_open"):
        entry(SYS[name])

    # --- Conditional blocks ---
    # execveat + AT_EMPTY_PATH is fileless execution from an anonymous fd.
    entry(SYS["execveat"]).append([(4, OP_MASKED_EQ, (AT_EMPTY_PATH, AT_EMPTY_PATH))])
    # A user namespace is a capability factory.
    entry(SYS["unshare"]).append([(0, OP_MASKED_EQ, (CLONE_NEWUSER, CLONE_NEWUSER))])
    entry(SYS["clone"]).append([(0, OP_MASKED_EQ, (CLONE_NEWUSER, CLONE_NEWUSER))])
    # Replacing the active filter.
    entry(SYS["seccomp"]).append([(0, OP_EQ, SECCOMP_SET_MODE_FILTER)])
    return rules


def build_compatibility_filter_rules():
    """seccomp.rs::build_compatibility_filter.

    clone3 takes a `struct clone_args *`, which cBPF cannot dereference, so
    CLONE_NEWUSER can't be filtered there — block it outright with ENOSYS so
    glibc falls back to `clone`, whose flags ARE a scalar register. EPERM would
    be read as a hard policy failure instead of triggering the fallback.
    """
    return {SYS["clone3"]: [], SYS["pidfd_open"]: []}


def build_child_hardening_rules(supervisor_tgid, supervisor_pgid=None):
    """child_seccomp.rs::prepare — same-uid workload self-protection.

    This is the filter that makes it safe for the sandboxed tree to share a uid
    with its supervisor. Without it, "sandboxed" would mean nothing: the
    workload could just ptrace agentd and run whatever it liked from outside
    the ruleset.

    See the module docstring for the one narrowed rule (`kill` targeting).
    """
    if not supervisor_tgid:
        raise PolicyError("supervisor TGID must be nonzero")
    rules = {}

    def entry(nr):
        return rules.setdefault(nr, [])

    for name in (
            # Reaching into another process.
            "ptrace", "process_vm_readv", "process_vm_writev",
            "pidfd_getfd", "pidfd_send_signal", "kcmp",
            "process_madvise", "process_mrelease",
            # Leaving the namespace / filesystem view the sandbox was built in.
            "unshare", "setns", "mount", "umount2", "pivot_root", "chroot",
            "fsopen", "fsconfig", "fsmount", "fspick", "move_mount", "open_tree",
            # Kernel-facing escape primitives.
            "bpf", "perf_event_open", "userfaultfd",
            "io_uring_setup", "io_uring_enter", "io_uring_register",
            # Credential changes. The privilege drop already happened; any
            # further change is an attempt to move sideways.
            "capset", "setuid", "setgid", "setreuid", "setregid",
            "setresuid", "setresgid", "setfsuid", "setfsgid", "setgroups",
            # Host-wide identity and scheduling knobs.
            "sethostname", "setdomainname", "setpriority", "ioprio_set",
            # `tkill` takes a TID, not a TGID, so the supervisor-TGID rule below
            # cannot see it -- and SIGKILL to any one of a process's threads
            # kills the whole thread group. agentd is multi-threaded, so
            # `tkill(<any agentd tid>, SIGKILL)` would have killed it straight
            # through the TGID check. OpenShell denies tkill only for the
            # sandbox TGID and closes the rest with its seccomp
            # user-notification listener, which is out of scope here; denying it
            # outright is the equivalent. Nothing in practice uses it --
            # `pthread_kill` and `raise` both compile to `tgkill`.
            "tkill"):
        entry(SYS[name])

    # ENOSYS, not EPERM: portable launchers fall back only on ENOSYS.
    compat = {SYS["clone3"]: [], SYS["pidfd_open"]: []}

    entry(SYS["clone"]).append(
        [(0, OP_MASKED_EQ, (CLONE_NAMESPACE_FLAGS, CLONE_NAMESPACE_FLAGS))])

    # Signal targeting. Linux accepts a non-leader TID for these, so a plain
    # TGID compare is necessary but not sufficient; OpenShell closes the rest
    # with its seccomp user-notification listener, which is out of scope here.
    for name in ("kill", "tgkill", "rt_sigqueueinfo", "rt_tgsigqueueinfo"):
        entry(SYS[name]).append([(0, OP_EQ, supervisor_tgid)])

    # Narrowed from OpenShell's blanket "pid <= 0" denial — see module docstring.
    # kill(-1) reaches every process this uid may signal, supervisor included.
    for name in ("kill", "rt_sigqueueinfo"):
        entry(SYS[name]).append([(0, OP_EQ, 0xFFFFFFFF)])
        if supervisor_pgid:
            # kill(-pgid) targets a process group by negation; deny the
            # supervisor's group specifically. setsid() puts the sandbox in its
            # own session, so no other group it can name is trusted.
            entry(SYS[name]).append(
                [(0, OP_EQ, (-supervisor_pgid) & 0xFFFFFFFF)])

    for name in ("prlimit64", "sched_setaffinity", "sched_setattr",
                 "sched_setparam", "sched_setscheduler"):
        entry(SYS[name]).append([(0, OP_NE, 0)])

    entry(SYS["close_range"]).append(
        [(2, OP_MASKED_EQ, (CLOSE_RANGE_UNSHARE, CLOSE_RANGE_UNSHARE))])

    # Directing SIGIO/SIGURG at another process via an inherited descriptor.
    for command in (F_SETOWN, F_SETSIG, F_SETOWN_EX):
        entry(SYS["fcntl"]).append([(1, OP_EQ, command)])
    for request in (FIOSETOWN, SIOCSPGRP):
        entry(SYS["ioctl"]).append([(1, OP_EQ, request)])

    return rules, compat


def build_supervisor_prelude_rules():
    """seccomp.rs::build_supervisor_prelude_rules.

    What the supervisor gives up once privileged bootstrap is done. Applied
    with TSYNC across every thread.
    """
    return {SYS[name]: [] for name in (
        "mount", "fsopen", "fsconfig", "fsmount", "fspick", "move_mount",
        "open_tree", "pivot_root", "umount2", "bpf", "perf_event_open",
        "userfaultfd", "init_module", "finit_module", "delete_module",
        "kexec_load", "kexec_file_load")}


EPERM_ACTION = SECCOMP_RET_ERRNO | errno.EPERM
ENOSYS_ACTION = SECCOMP_RET_ERRNO | errno.ENOSYS


def apply_seccomp(supervisor_tgid=None, supervisor_pgid=None, allow_inet=True,
                  child_hardening=True):
    """sandbox-linux/mod.rs::enforce_capability_free, filter half.

    Order is mandatory and is OpenShell's:

      1. no_new_privs (inside the child-hardening install, and again below)
      2. the child self-protection filter — it must precede the main filter,
         because the main filter bans further `seccomp(SET_MODE_FILTER)` calls
      3. the compatibility filter (clone3/pidfd_open → ENOSYS), which must
         precede the main filter for the same reason
      4. the main filter, last, so its ban on filter installation is final
    """
    set_no_new_privs()
    if child_hardening:
        child_rules, child_compat = build_child_hardening_rules(
            supervisor_tgid, supervisor_pgid)
        install_filter(compile_filter(child_compat, ENOSYS_ACTION))
        install_filter(compile_filter(child_rules, EPERM_ACTION))
    install_filter(compile_filter(build_compatibility_filter_rules(), ENOSYS_ACTION))
    install_filter(compile_filter(build_main_filter_rules(allow_inet), EPERM_ACTION))


# ---------------------------------------------------------------------------
# Privilege drop — openshell/process.rs::drop_privileges_with_identity
# ---------------------------------------------------------------------------

PR_SET_DUMPABLE = 4
PR_CAPBSET_READ = 23
PR_CAPBSET_DROP = 24
RLIMIT_CORE = 4
CAP_LAST_CAP_PATH = "/proc/sys/kernel/cap_last_cap"


def harden_child_process():
    """process.rs::harden_child_process — no core dumps, not ptrace-dumpable.

    `PR_SET_DUMPABLE=0` is reset by the kernel on the following `execve`, so it
    guards the fork→exec window only. OpenShell does the same; kept for parity
    and because that window is when the ruleset fds are still open.

    `resource` is imported at module scope, not here: this runs in a process
    forked from a multi-threaded supervisor, and an import in that child can
    deadlock on the import lock if another thread held it at fork time.
    """
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    ctypes.set_errno(0)
    if _libc.prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0:
        raise PolicyError("Failed to set PR_SET_DUMPABLE=0: %s"
                          % os.strerror(ctypes.get_errno()))


def drop_capability_bounding_set():
    """process.rs::drop_capability_bounding_set.

    Cleared, then verified empty. A capability left in the bounding set would
    survive into any future privileged exec the workload managed to arrange.
    """
    try:
        with open(CAP_LAST_CAP_PATH) as handle:
            last_cap = int(handle.read().strip())
    except (OSError, ValueError):
        last_cap = 40
    remaining = []
    for cap in range(last_cap + 1):
        ctypes.set_errno(0)
        if _libc.prctl(PR_CAPBSET_READ, cap, 0, 0, 0) != 1:
            continue
        if _libc.prctl(PR_CAPBSET_DROP, cap, 0, 0, 0) != 0:
            remaining.append(cap)
    if remaining:
        raise PolicyError(
            "Failed to clear child capability bounding set: capabilities "
            "remain raised: %s" % (remaining,))


def _resolve_user(name):
    """Numeric values are used directly; names resolve through passwd."""
    try:
        return pwd.getpwuid(int(name))
    except ValueError:
        pass
    except KeyError:
        # A numeric uid with no passwd entry is still a valid target; OpenShell
        # uses it directly and skips initgroups for it.
        return None
    try:
        return pwd.getpwnam(name)
    except KeyError:
        raise PolicyError("Sandbox user not found: %s" % name)


def _resolve_group(name):
    try:
        return grp.getgrgid(int(name))
    except ValueError:
        pass
    except KeyError:
        return None
    try:
        return grp.getgrnam(name)
    except KeyError:
        raise PolicyError("Sandbox group not found: %s" % name)


class ResolvedIdentity(object):
    def __init__(self, uid, gid, user=None, group=None, changed=False):
        self.uid = uid
        self.gid = gid
        self.user = user
        self.group = group
        self.changed = changed


def drop_privileges(policy, default_user=None, default_group=None,
                    extra_groups=()):
    """process.rs::drop_privileges_with_identity.

    One Bromure change, and it is the one @openshell decided: OpenShell falls
    back to the literal `sandbox:sandbox` when it is root and the policy names
    nobody. Bromure falls back to the workspace user instead (`default_user`),
    because an absent `process` section must mean "no uid switch" — the
    workspace has to come up exactly as it does today.

    `extra_groups` is the second, and it is additive: supplementary gids added
    after `initgroups` and before `setuid`. Bromure uses exactly one, the group
    that owns the tmux socket directory, which is how a sandboxed server is
    allowed to create the socket while agentd — same uid, no such group — is
    not. With an empty tuple this is byte-for-byte upstream's behavior, which is
    what `differential/` exercises.

    Everything else is OpenShell's, in OpenShell's order, including the two
    verifications it does after the fact and the re-acquisition check.
    """
    user_name = policy.process.run_as_user or None
    group_name = policy.process.run_as_group or None
    if not policy.process.present:
        user_name = group_name = None
    if user_name == "":
        user_name = None
    if group_name == "":
        group_name = None

    explicit = user_name is not None or group_name is not None
    if not explicit:
        if os.geteuid() != 0:
            # Already unprivileged: the no-op is safe, exactly as upstream.
            return ResolvedIdentity(os.geteuid(), os.getegid(), changed=False)
        user_name, group_name = default_user, default_group
        if user_name is None and group_name is None:
            raise PolicyError(
                "running as root with no run_as_user and no default user")

    # --- resolve uid ---
    if user_name is not None:
        record = _resolve_user(user_name)
        target_uid = record.pw_uid if record else int(user_name)
    else:
        target_uid = os.geteuid()
        record = None

    # --- resolve gid ---
    if group_name is not None:
        group_record = _resolve_group(group_name)
        target_gid = group_record.gr_gid if group_record else int(group_name)
    elif target_uid == 0:
        target_gid = os.getegid()
    else:
        owner = record or (pwd.getpwuid(target_uid) if _passwd_has(target_uid) else None)
        if owner is None:
            raise PolicyError("Failed to resolve user from UID %d" % target_uid)
        target_gid = owner.pw_gid

    # initgroups only for a non-numeric name, as upstream: a numeric uid must
    # not be reflected back through NSS.
    user_name_is_numeric = user_name is not None and _is_numeric(user_name)
    initgroups_name = None
    if user_name is not None and not user_name_is_numeric:
        owner = pwd.getpwuid(target_uid) if _passwd_has(target_uid) else None
        if owner is None:
            raise PolicyError("Failed to resolve user record for UID %d" % target_uid)
        initgroups_name = owner.pw_name

    if target_uid != os.geteuid() and initgroups_name is not None:
        os.initgroups(initgroups_name, target_gid)
    if extra_groups:
        # After initgroups, which replaces the list wholesale, and before
        # setuid, after which setgroups is no longer permitted.
        current = set(os.getgroups())
        current.update(int(gid) for gid in extra_groups)
        os.setgroups(sorted(current))

    if target_gid != os.getegid():
        os.setgid(target_gid)
    if os.getegid() != target_gid:
        raise PolicyError(
            "Privilege drop verification failed: expected effective GID %d, got %d"
            % (target_gid, os.getegid()))

    if os.geteuid() == 0:
        drop_capability_bounding_set()

    if user_name is not None:
        if target_uid != os.geteuid():
            os.setuid(target_uid)
        if os.geteuid() != target_uid:
            raise PolicyError(
                "Privilege drop verification failed: expected effective UID %d, got %d"
                % (target_uid, os.geteuid()))
        if target_uid != 0:
            # If root can still be re-acquired the drop did not take.
            try:
                os.setuid(0)
                raise PolicyError(
                    "Privilege drop verification failed: process can still "
                    "re-acquire root (UID 0) after switching to UID %d" % target_uid)
            except PermissionError:
                pass

    return ResolvedIdentity(
        os.geteuid(), os.getegid(),
        user=(pwd.getpwuid(os.geteuid()).pw_name if _passwd_has(os.geteuid()) else None),
        group=(grp.getgrgid(os.getegid()).gr_name if _group_has(os.getegid()) else None),
        changed=True)


def _is_numeric(value):
    try:
        int(value)
        return True
    except (TypeError, ValueError):
        return False


def _passwd_has(uid):
    try:
        pwd.getpwuid(uid)
        return True
    except KeyError:
        return False


def _group_has(gid):
    try:
        grp.getgrgid(gid)
        return True
    except KeyError:
        return False


# ---------------------------------------------------------------------------
# The whole enforcement, in order
# ---------------------------------------------------------------------------

def enforce_landlock_privileged(prepared, outcome):
    """`restrict_self` while still root, so `no_new_privs` is NOT needed.

    The kernel accepts `landlock_restrict_self` from a task that either has
    `no_new_privs` set or holds CAP_SYS_ADMIN. OpenShell always takes the first
    route because it drops privileges first, and for OpenShell that is free —
    nnp is something it wants anyway.

    Bromure has a mode where nnp is exactly what it must NOT set: a workspace
    with a `filesystem_policy` but no strict sandbox still grants the agent
    `sudo`, and nnp makes every setuid binary inert. Applying the ruleset from
    the still-root supervisor child, before the drop, gives the same confinement
    with none of that. The caller must therefore make sure any NSS lookup it
    needs (`initgroups` reads /etc/group) has already happened, because after
    this returns the policy is in force.
    """
    return enforce_landlock(prepared, outcome)


def drop_to_user(uid, gid, groups):
    """A privilege drop with no NSS lookups at all.

    `drop_privileges` resolves names through passwd/group, which is fine when it
    runs before the ruleset is in force. This one takes pre-resolved numeric ids
    so it can run *after* `restrict_self`, where a policy that does not grant
    /etc would make an NSS lookup fail.

    Deliberately does NOT clear the capability bounding set. In the mode that
    uses this there is no process policy, so panes must be indistinguishable
    from pre-sandbox ones — and clearing the bounding set would break `sudo` and
    every file-capability binary such as `ping`.
    """
    if groups:
        os.setgroups(sorted(set(int(g) for g in groups)))
    if gid != os.getegid():
        os.setgid(gid)
    if os.getegid() != gid:
        raise PolicyError("setgid verification failed: wanted %d, got %d"
                          % (gid, os.getegid()))
    if uid != os.geteuid():
        os.setuid(uid)
    if os.geteuid() != uid:
        raise PolicyError("setuid verification failed: wanted %d, got %d"
                          % (uid, os.geteuid()))
    if uid != 0:
        try:
            os.setuid(0)
            raise PolicyError(
                "privilege drop verification failed: root can still be "
                "re-acquired after switching to uid %d" % uid)
        except PermissionError:
            pass
    return ResolvedIdentity(os.geteuid(), os.getegid(), changed=True)


def enforce(prepared, outcome, supervisor_tgid, supervisor_pgid=None,
            child_hardening=True, allow_inet=True):
    """sandbox-linux/mod.rs::enforce_capability_free, with nnp made explicit.

    OpenShell reaches `restrict_self` with `no_new_privs` already set, because
    its workload launcher thread sets it when it installs the network
    notification listener, and the child inherits it across fork. There is no
    such thread here, so nnp is set explicitly first. Without it the kernel
    rejects `landlock_restrict_self` with EPERM for any caller that isn't
    CAP_SYS_ADMIN — which, after the privilege drop, is us.

    Everything after that is upstream's order, and it is load-bearing: the main
    filter bans further `seccomp(SET_MODE_FILTER)`, so it must be installed last.
    """
    set_no_new_privs()
    outcome = enforce_landlock(prepared, outcome)
    apply_seccomp(supervisor_tgid=supervisor_tgid,
                  supervisor_pgid=supervisor_pgid,
                  allow_inet=allow_inet,
                  child_hardening=child_hardening)
    return outcome
