#!/usr/bin/env python3
"""bromure-attestd — the guest's binary-identity attestor (strict sandbox).

Runs as ROOT, started by bromure-agentd before it revokes the agent user's
sudo / docker access, so nothing the agent can run afterwards is able to kill,
trace or impersonate it. It holds the ONE connection the host accepts on vsock
port 5840 for this VM; the host asks it, for each new outbound TCP connection,
which executable opened the socket:

  host  → {"id": 7, "op": "who", "sport": 51234, "dst": "140.82.112.6", "dport": 443}
  guest → {"id": 7, "ok": true, "exe": "/usr/bin/curl", "sha256": "…",
           "ancestors": [{"exe": "/usr/bin/bash", "sha256": "…"}, …], "pids": [1234]}

Identity comes from kernel state only (/proc/net/tcp → socket inode → the
processes holding it → /proc/<pid>/exe, hashed through the open exe link),
never from anything the workload says. Ambiguous or missing evidence is an
error, and the host denies binary-scoped access for it (fail closed).
"""
import hashlib
import json
import os
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# NOT imported at module scope, and the reason is a blocker that took two rounds
# to see.
#
# attestd's first job is to answer `who`: the host fails closed on every
# binary-scoped network rule until it can, so a workspace without an attestor is
# one where `curl` does not work and nothing says why. Building `sandbox_status`
# is a *second* job, and the module that does it lives in the meta share beside
# this file -- staged by the host, possibly later than this file, and not needed
# at all by a workspace with no sandbox spec.
#
# Importing it up here made that a startup dependency: an ImportError exited the
# process before it ever opened 5840, systemd restarted it a second later, and
# the workspace ran with NO attestor until the file turned up. Observed as
# "attestd connects ~80 s late on a spec-less strict boot", with twenty denied
# connections in between.
#
# So: connect first, answer identity immediately, and report status when -- and
# only when -- there is something to report it with.
_status_module = None


def sandbox_status_module():
    """The status builder, or None. Retried on every call; never fatal."""
    global _status_module
    if _status_module is None:
        try:
            import bromure_sandbox_status
            _status_module = bromure_sandbox_status
        except Exception as exc:  # noqa: BLE001 -- staying connectable is the job
            log("sandbox_status unavailable for now (%s); identity still served"
                % exc)
            return None
    return _status_module

VSOCK_PORT = 5840
# Overridable for the same reason agentd's is: nothing inside a guest can bind
# CID 2, so without this hook attestd's startup -- the one path that decides
# whether the host ever hears from this VM -- cannot be exercised by a test that
# boots the real thing. It went untested for sixteen rounds because of it.
# Unset in production.
HOST_CID = int(os.environ.get("BROMURE_HOST_CID", "2"))
READY_PATH = "/run/bromure-attestd.ready"
MAX_ANCESTORS = 16

_hash_cache = {}        # (dev, ino, mtime_ns, size) -> sha256
_inode_pids = {}        # socket inode -> [pids]  (refreshed on miss)


def log(msg):
    sys.stderr.write("[attestd] %s\n" % msg)
    sys.stderr.flush()


def hex_ipv4(addr):
    """/proc/net/tcp little-endian hex address → dotted quad."""
    b = bytes.fromhex(addr)
    return "%d.%d.%d.%d" % (b[3], b[2], b[1], b[0])


def hex_ipv6_as_v4(addr):
    """A v4-mapped ::ffff:a.b.c.d entry in /proc/net/tcp6, else None."""
    if len(addr) != 32:
        return None
    words = [addr[i:i + 8] for i in range(0, 32, 8)]
    if words[0] != "00000000" or words[1] != "00000000" or words[2].upper() != "FFFF0000":
        return None
    return hex_ipv4(words[3])


def find_socket_inode(sport, dst, dport, tables=None):
    """The inode of the TCP socket local:sport → dst:dport (any state)."""
    tables = tables or [("/proc/net/tcp", hex_ipv4), ("/proc/net/tcp6", hex_ipv6_as_v4)]
    for path, conv in tables:
        try:
            with open(path) as f:
                lines = f.read().splitlines()[1:]
        except OSError:
            continue
        for line in lines:
            parts = line.split()
            if len(parts) < 10:
                continue
            local, remote, inode = parts[1], parts[2], parts[9]
            try:
                laddr, lport = local.split(":")
                raddr, rport = remote.split(":")
                if int(lport, 16) != sport or int(rport, 16) != dport:
                    continue
                if conv(raddr) != dst:
                    continue
            except ValueError:
                continue
            if inode != "0":
                return inode
    return None


def pids_for_inode(inode):
    """Processes holding socket:[inode] (cache, refreshed on a miss)."""
    if inode in _inode_pids:
        alive = [p for p in _inode_pids[inode] if os.path.exists("/proc/%d" % p)]
        if alive:
            return alive
    target = "socket:[%s]" % inode
    found = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        fd_dir = "/proc/%s/fd" % name
        try:
            fds = os.listdir(fd_dir)
        except OSError:
            continue
        for fd in fds:
            try:
                link = os.readlink("%s/%s" % (fd_dir, fd))
            except OSError:
                continue
            if link.startswith("socket:["):
                found.setdefault(link[8:-1], []).append(int(name))
    _inode_pids.clear()
    _inode_pids.update(found)
    return found.get(inode, [])


# What the kernel appends to /proc/<pid>/exe once the path is unlinked.
_DELETED = " (deleted)"


def reported_path(read, nlink):
    """The path to report for an exe link; `read()` reads the link,
    `nlink()` the open exe's link count, each afresh.

    The kernel's " (deleted)" is only an annotation when the running image
    is unlinked: a LIVE file the workload named `curl (deleted)` reads
    exactly the same, and stripping it reported the sibling `curl` -- a path
    the guest user picks, in any directory it can write, matched by
    `binaries:` and pinned to the forged image's digest on first use
    (Finding CWE-807, "Attestor strips a real ' (deleted)' filename into an
    allowlisted binary path").

    Whether it is unlinked is asked of the open exe itself, never of the
    path text: a stat of the name can be fooled by renaming it aside and
    back around the stat, which the link reads before and after never see
    (Finding CWE-367, "Attestor strips a live '(deleted)' binary when its
    name is restored around the stat"). Link count 0 is an unlinked inode
    -- it can't get a name back (that takes linkat with AT_EMPTY_PATH, i.e.
    CAP_DAC_READ_SEARCH) -- so the one trailing suffix is the kernel's and
    is cut. Any other count is a file with a name, kept as read: a binary
    unlinked here but hard-linked elsewhere keeps its " (deleted)" and
    matches nothing, which fails closed. The count must be the same on both
    sides of the read, or the read raced an unlink; never steady: OSError,
    and the host fails closed.
    """
    for _ in range(4):
        before = nlink()
        raw = read()
        if nlink() != before:
            continue
        if before == 0 and raw.endswith(_DELETED):
            return raw[: -len(_DELETED)]
        return raw
    raise OSError("exe link count kept changing")


def exe_identity(pid):
    """(real path, sha256) of a process's executable, hashing the live object.

    A DELETED executable is still identified, by hashing the image through the
    still-open `/proc/<pid>/exe` link. Refusing it was the bug behind "strict
    workspaces lose every binary-gated flow": an agent that has updated itself
    is running a deleted image almost all the time -- npm unpacks the new
    Claude Code into a fresh directory and removes the old one, so
    `/proc/<pid>/exe` reads

        /home/…/@anthropic-ai/.claude-code-IVk0osNH/bin/claude.exe (deleted)

    for the rest of that process's life. It is an ANCESTOR of every shell and
    every `curl` the agent runs, so `who()` failed for all of them, the host
    got no identity, and `binaries:` rules could not match -- fail closed, on
    a condition that says nothing about the program that opened the socket.

    Hashing the open link is what this module already claims to do ("hashed
    through the open exe link") and is stronger evidence than re-reading the
    path: it is the image the process is ACTUALLY running, immune to a binary
    swapped after launch. Measured: a 291 MB deleted claude.exe hashes fine
    through its own /proc link.

    The path is reported without the kernel's " (deleted)" decoration (and
    only that: see `reported_path`, a real name can end the same way), because
    the path is the identity the policy matches on. The consequence, which is
    the host's to weigh: that path gets pinned (trust-on-first-use) to the
    OLD image's digest, so a new binary later appearing at the same path is
    refused as changed -- which is what TOFU is for, but it means an in-place
    upgrade needs the old processes gone before the new one is attested.
    """
    link = "/proc/%d/exe" % pid
    with open(link, "rb") as f:
        st = os.fstat(f.fileno())
        path = reported_path(lambda: os.readlink(link), lambda: os.fstat(f.fileno()).st_nlink)
        key = (st.st_dev, st.st_ino, st.st_mtime_ns, st.st_size)
        digest = _hash_cache.get(key)
        if digest is None:
            h = hashlib.sha256()
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
            digest = h.hexdigest()
            _hash_cache[key] = digest
    return path, digest


def ppid_of(pid):
    with open("/proc/%d/status" % pid) as f:
        for line in f:
            if line.startswith("PPid:"):
                return int(line.split()[1])
    return 0


def who(sport, dst, dport):
    inode = find_socket_inode(sport, dst, dport)
    if inode is None:
        # The SYN can race the table by a moment; one short retry.
        time.sleep(0.02)
        inode = find_socket_inode(sport, dst, dport)
    if inode is None:
        return {"ok": False, "reason": "no socket for %d → %s:%d" % (sport, dst, dport)}
    pids = pids_for_inode(inode)
    if not pids:
        return {"ok": False, "reason": "no process holds socket %s" % inode}
    idents = {}
    for p in pids:
        try:
            idents[p] = exe_identity(p)
        except OSError as e:
            return {"ok": False, "reason": "pid %d: %s" % (p, e)}
    distinct = set(idents.values())
    if len(distinct) != 1:
        return {"ok": False, "reason": "socket shared by different executables"}
    leaf = min(pids)
    exe, digest = idents[leaf]
    ancestors = []
    # An ancestor that cannot be identified TRUNCATES the chain; it does not
    # discard the answer. The leaf is what `binaries:` matches, and the chain
    # is context -- it is already cut short at MAX_ANCESTORS, so a shorter one
    # is a shape the host accepts. Discarding the whole identity because a
    # parent exited mid-walk (a shell that has finished) or cannot be read
    # fails closed on something that says nothing about the program that
    # opened the socket.
    #
    # Every link still carries a digest: the host refuses an identity with a
    # missing one anywhere in the chain (OpenShell's rule, BinaryPinStore
    # .verifyOrPin), so a link that cannot be hashed must be left OUT rather
    # than sent incomplete.
    try:
        cur = ppid_of(leaf)
    except OSError:
        cur = 0
    while cur > 1 and len(ancestors) < MAX_ANCESTORS:
        try:
            a_exe, a_digest = exe_identity(cur)
            nxt = ppid_of(cur)
        except OSError:
            break
        ancestors.append({"exe": a_exe, "sha256": a_digest})
        cur = nxt
    return {"ok": True, "exe": exe, "sha256": digest, "ancestors": ancestors, "pids": sorted(pids)}


# The channel now has two writers -- replies to host requests, and unsolicited
# sandbox_status lines -- so every write goes through one lock. Interleaved
# JSON on a line-delimited channel would be a parse error on the host, which
# would look exactly like a compromised guest.
_SEND_LOCK = threading.Lock()


def send_line(sock, obj):
    with _SEND_LOCK:
        sock.sendall((json.dumps(obj) + "\n").encode())


def status_watcher(sock, stop):
    """Push sandbox_status on connect, and again whenever it changes.

    attestd is the right place for this: it already runs as root before any
    agent code, and it already owns the one connection the host accepts, so
    nothing the agent can run can forge or suppress what it says.

    Polling rather than inotify, because the two status files are written by
    other processes at boot and may not exist yet when this starts -- watching
    a directory for creation, then the files for modification, is more moving
    parts than reading two small files on a tmpfs once a second is worth.
    """
    last = None
    while not stop.is_set():
        try:
            module = sandbox_status_module()
            if module is None:
                # No status to build yet. The connection is up and `who` is
                # being served, which is the part the host cannot do without.
                stop.wait(5.0)
                continue
            status = module.build()
            mark = module.fingerprint(status)
            if mark != last:
                send_line(sock, status)
                last = mark
                log("sandbox_status: filesystem=%s seccomp=%s sentry=%s"
                    % (status["filesystem"], status["seccomp"], status["sentry"]))
        except OSError:
            return          # the channel went away; the reconnect loop owns that
        except Exception as e:
            log("status watcher: %s" % e)
        stop.wait(1.0)


def serve(sock, secret):
    # The secret proves this is the attestor that connected first (before any
    # agent code ran): the host pins it and refuses a reconnect without it.
    sock.sendall((json.dumps({"hello": "attestd", "version": 1, "secret": secret}) + "\n").encode())
    stop = threading.Event()
    watcher = threading.Thread(target=status_watcher, args=(sock, stop), daemon=True)
    watcher.start()
    try:
        buf = b""
        while True:
            data = sock.recv(65536)
            if not data:
                return
            buf += data
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    req = json.loads(line)
                except ValueError:
                    continue
                reply = {"id": req.get("id")}
                try:
                    if req.get("op") == "who":
                        reply.update(who(int(req["sport"]), str(req["dst"]), int(req["dport"])))
                    elif req.get("op") == "ping":
                        reply.update({"ok": True})
                    elif req.get("op") == "sandbox_status":
                        # Explicit re-request, for a host that reconnected and
                        # wants the current picture without waiting for a change.
                        module = sandbox_status_module()
                        if module is None:
                            reply.update({"ok": False,
                                          "reason": "sandbox status unavailable"})
                        else:
                            reply.update({"ok": True,
                                          "status": module.build()})
                    else:
                        reply.update({"ok": False, "reason": "unknown op"})
                except Exception as e:  # never die on one bad request
                    reply.update({"ok": False, "reason": "error: %s" % e})
                send_line(sock, reply)
    finally:
        stop.set()


SECRET_PATH = "/run/bromure-attestd.secret"


def load_secret():
    """The attestor's pinned identity: root-only (0600 in /run), so a restart
    of this unit keeps it while nothing the agent runs can read it."""
    try:
        with open(SECRET_PATH) as f:
            s = f.read().strip()
            if len(s) == 64:
                return s
    except OSError:
        pass
    s = os.urandom(32).hex()
    fd = os.open(SECRET_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(s)
    return s


def main():
    """Connect, serve, reconnect. This loop must be impossible to fall out of.

    attestd is the only channel the host accepts on 5840, and without it the host
    fails closed on every binary-scoped network rule -- so a workspace whose
    attestor is not running is one where `curl` silently does not work, for the
    whole boot, with nothing saying why. That makes "never exits" a correctness
    property, not tidiness.

    Two ways it could exit, both now closed:

    * `load_secret()` was called OUTSIDE the loop, so any OSError from it --
      a full `/run`, a stale file with the wrong mode -- killed the process
      before the loop began;
    * the loop caught only `OSError`, so any other exception type escaped.

    Either exit is then multiplied by systemd: `Restart=always` with the default
    start limit means five exits in ten seconds leave the unit **failed and no
    longer restarted**, which turns a transient into a dead attestor for the rest
    of the boot. The unit now also carries `StartLimitIntervalSec=0` and is
    `reset-failed` before start, so neither half can do that on its own.
    """
    if os.geteuid() != 0:
        log("must run as root")
        sys.exit(1)
    announced = False
    secret = None
    while True:
        try:
            if secret is None:
                secret = load_secret()
            s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            s.connect((HOST_CID, VSOCK_PORT))
            log("connected to host")
            if not announced:
                with open(READY_PATH, "w") as f:
                    f.write(str(os.getpid()))
                announced = True
            serve(s, secret)
            log("host closed the channel")
        except OSError as e:
            log("connect: %s" % e)
        except Exception as e:  # noqa: BLE001 -- staying up IS the job
            log("unexpected (%s): %s -- retrying" % (type(e).__name__, e))
        # The host pins the first attestor's secret: reconnecting (after a
        # suspend / restore, say) works only for this process.
        time.sleep(1)


if __name__ == "__main__" and "--selftest" not in sys.argv:
    main()
