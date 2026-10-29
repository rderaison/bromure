#!/usr/bin/env python3
"""bromure-attestd's binary identity: what `who()` answers, and when it refuses.

The bug this exists for: a strict workspace lost EVERY binary-gated flow once
the agent had updated itself. `exe_identity` refused any executable the kernel
marks " (deleted)", and `who()` turned one unreadable ANCESTOR into
`ok: false` for the whole answer. npm replaces Claude Code by unpacking a new
tree and removing the old one, so the running agent's image is deleted for the
rest of its life -- and it is an ancestor of every shell and every `curl` it
runs. The host reads no identity as "fail closed", so `binaries:` rules could
never match and the flow was held, then denied with no rule to name.

The host-side tests could not catch it: they drive BinaryIdentityService
through `queryOverride`, so attestd's own answer is never computed.

Needs no root: every process it inspects is its own.

Run: tests/test_attestd_identity.py
"""
import importlib.machinery
import importlib.util
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ATTESTD = os.path.normpath(os.path.join(
    HERE, "..", "..", "..", "Sources", "AgentCoding", "Resources",
    "vm-setup", "bromure-attestd.py"))

fails = 0


def ok(msg):
    print("  ok   %s" % msg)


def bad(msg):
    global fails
    fails += 1
    print("  FAIL %s" % msg)


def load_attestd():
    if not os.access(ATTESTD, os.R_OK):
        print("  SKIP bromure-attestd.py not found at %s" % ATTESTD)
        sys.exit(77)
    loader = importlib.machinery.SourceFileLoader("attestd_under_test", ATTESTD)
    spec = importlib.util.spec_from_loader("attestd_under_test", loader)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Stall:
    """A listener that accepts and never answers, so a client's socket stays
    open long enough to be looked up in /proc/net/tcp."""

    def __enter__(self):
        self.srv = socket.socket()
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(8)
        self.port = self.srv.getsockname()[1]
        self.held = []
        self.t = threading.Thread(target=self._accept, daemon=True)
        self.t.start()
        return self

    def _accept(self):
        while True:
            try:
                self.held.append(self.srv.accept())
            except OSError:
                return

    def __exit__(self, *_):
        try:
            self.srv.close()
        except OSError:
            pass


def sport_to(port):
    """The local port of a socket connected to 127.0.0.1:<port>."""
    with open("/proc/net/tcp") as f:
        for line in f.readlines()[1:]:
            parts = line.split()
            if int(parts[2].split(":")[1], 16) == port:
                return int(parts[1].split(":")[1], 16)
    return None


def main():
    att = load_attestd()

    # --- a deleted executable is still identified -------------------------
    # The regression itself, at the lowest level: a copy of /bin/sleep that is
    # removed while it runs. The kernel appends " (deleted)" to
    # /proc/<pid>/exe, and the image is still readable through that link.
    tmp = tempfile.mkdtemp()
    copy = os.path.join(tmp, "sleeper")
    shutil.copy2("/bin/sleep", copy)
    p = subprocess.Popen([copy, "30"])
    time.sleep(0.3)
    os.unlink(copy)
    raw_link = os.readlink("/proc/%d/exe" % p.pid)
    if not raw_link.endswith(" (deleted)"):
        bad("the kernel did not mark the unlinked exe as deleted: %r" % raw_link)
    try:
        path, digest = att.exe_identity(p.pid)
        if path == copy and len(digest) == 64:
            ok("a deleted executable is identified by its real path and hashed")
        else:
            bad("deleted exe gave path=%r digest=%r" % (path, digest))
        # The digest must be of the real image, not of nothing.
        if digest == att.hashlib.sha256(open("/bin/sleep", "rb").read()).hexdigest():
            ok("and the digest is the running image's, byte for byte")
        else:
            bad("the digest does not match the image that was copied")
    except OSError as e:
        bad("a deleted executable was refused: %s" % e)
    p.kill()

    # --- a DELETED ANCESTOR does not sink the leaf's identity -------------
    # The shape that broke strict workspaces: the program that opened the
    # socket is fine, its parent's binary is gone.
    tmp2 = tempfile.mkdtemp()
    shell = os.path.join(tmp2, "sh-copy")
    shutil.copy2("/bin/bash", shell)
    with Stall() as st:
        child = subprocess.Popen(
            [shell, "-c",
             "/bin/bash -c 'exec 3<>/dev/tcp/127.0.0.1/%d; sleep 20'; true"
             % st.port])
        time.sleep(1.0)
        os.unlink(shell)                      # the ANCESTOR's exe disappears
        sport = sport_to(st.port)
        if sport is None:
            bad("no socket row for the child's connection; cannot test the chain")
        else:
            ans = att.who(sport, "127.0.0.1", st.port)
            chain = [a.get("exe") for a in ans.get("ancestors") or []]
            if not ans.get("ok"):
                bad("a deleted ancestor still sinks the answer: %s" % ans.get("reason"))
            elif ans.get("exe") == shell:
                bad("the deleted copy is the LEAF here (%r), so this is not "
                    "testing an ancestor at all" % ans.get("exe"))
            elif shell not in chain:
                bad("the deleted ancestor is missing from the chain %s: it can "
                    "be hashed through its /proc link, so it should be named"
                    % chain[:4])
            else:
                ok("a deleted ANCESTOR leaves the leaf's identity intact")
                ok("and the deleted ancestor is named in the chain, with a digest")
        child.kill()

    # --- an unreadable ancestor truncates, it does not refuse -------------
    # Deterministic where a real exiting parent is a race: make the second
    # link unreadable and assert the leaf still answers.
    with Stall() as st:
        holder = subprocess.Popen(["/bin/bash", "-c",
                                   "exec 3<>/dev/tcp/127.0.0.1/%d; sleep 20" % st.port])
        time.sleep(0.8)
        sport = sport_to(st.port)
        real = att.exe_identity
        leaf_pid = None
        if sport is not None:
            inode = att.find_socket_inode(sport, "127.0.0.1", st.port)
            leaf_pid = min(att.pids_for_inode(inode)) if inode else None

        def flaky(pid):
            if leaf_pid is not None and pid != leaf_pid:
                raise OSError("simulated: ancestor unreadable")
            return real(pid)

        if sport is None or leaf_pid is None:
            bad("could not set up the truncation case")
        else:
            att.exe_identity = flaky
            try:
                ans = att.who(sport, "127.0.0.1", st.port)
            finally:
                att.exe_identity = real
            if ans.get("ok") and not (ans.get("ancestors") or []):
                ok("an unreadable ancestor truncates the chain, answer still ok")
            elif ans.get("ok"):
                bad("expected an empty chain, got %s" % (ans.get("ancestors"),))
            else:
                bad("an unreadable ancestor still refuses: %s" % ans.get("reason"))

            # --- but the LEAF must still fail closed ---------------------
            # The security property: no identity when the program that opened
            # the socket cannot be named.
            att.exe_identity = lambda pid: (_ for _ in ()).throw(
                OSError("simulated: leaf unreadable"))
            try:
                ans = att.who(sport, "127.0.0.1", st.port)
            finally:
                att.exe_identity = real
            if not ans.get("ok"):
                ok("an unidentifiable LEAF still fails closed: %s" % ans.get("reason"))
            else:
                bad("the leaf was unreadable and who() answered anyway: %r" % ans)
        holder.kill()

    # --- a socket nobody holds is refused ---------------------------------
    ans = att.who(1, "127.0.0.1", 9)
    if not ans.get("ok"):
        ok("an unknown flow is refused, not guessed")
    else:
        bad("who() invented an identity for a flow with no socket: %r" % ans)

    print()
    print("ATTESTD IDENTITY: %s" % ("all checks passed" if not fails
                                    else "%d CHECK(S) FAILED" % fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
