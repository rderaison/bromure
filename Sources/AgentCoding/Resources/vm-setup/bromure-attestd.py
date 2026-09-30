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


def exe_identity(pid):
    """(real path, sha256) of a process's executable, hashing the live object."""
    path = os.readlink("/proc/%d/exe" % pid)
    if path.endswith(" (deleted)"):
        raise OSError("executable was deleted")
    with open("/proc/%d/exe" % pid, "rb") as f:
        st = os.fstat(f.fileno())
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
    cur = ppid_of(leaf)
    while cur > 1 and len(ancestors) < MAX_ANCESTORS:
        try:
            a_exe, a_digest = exe_identity(cur)
        except OSError as e:
            return {"ok": False, "reason": "ancestor %d: %s" % (cur, e)}
        ancestors.append({"exe": a_exe, "sha256": a_digest})
        cur = ppid_of(cur)
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
