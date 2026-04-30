#!/usr/bin/env python3
"""
Bromure AC — Claude subscription token agent.

Connects to the host over vsock and answers two RPCs:

  read           → returns {"ok":true, "access":..., "refresh":...} or
                    {"ok":true, "access":null, "refresh":null} if the file
                    is missing / has no oauth block.
  write          → overwrites accessToken + refreshToken in
                    ~/.claude/.credentials.json atomically. Refuses any
                    value that doesn't carry the brm- shape so a buggy
                    or malicious host can't pollute the file.

There is NO "fetch real token from host" RPC. The host only ever sends
fakes back; the agent never asks for cleartext from the host. That is
the whole security invariant of this channel: real → host, fake → VM.

Wire format: line-delimited JSON. The host sends one request per line,
the agent sends one response per line. The connection is persistent;
the host pushes more requests as needed.

Lives in /mnt/bromure-meta and is started by xinitrc — host-managed,
no base-image changes required.
"""
import errno
import json
import os
import socket
import sys
import tempfile
import time

HOST_CID = 2
TOKEN_PORT = 8446

LOG_PATH = "/tmp/bromure-claude-token.log"
CREDS_PATH = os.path.expanduser("~/.claude/.credentials.json")

ACCESS_FAKE_PREFIX = "sk-ant-oat01-brm-"
REFRESH_FAKE_PREFIX = "sk-ant-ort01-brm-"


def log(msg):
    try:
        with open(LOG_PATH, "a") as f:
            f.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), msg))
    except Exception:
        pass


def read_credentials():
    """Pull (access, refresh) from the on-disk credentials JSON. Returns
    (None, None) if the file or oauth block is missing, which is what
    `claude login` not having run yet looks like.
    """
    try:
        with open(CREDS_PATH, "r") as f:
            data = json.load(f)
    except FileNotFoundError:
        return None, None
    except (OSError, json.JSONDecodeError) as e:
        log("read failed: %s" % e)
        return None, None
    oauth = data.get("claudeAiOauth")
    if not isinstance(oauth, dict):
        return None, None
    access = oauth.get("accessToken")
    refresh = oauth.get("refreshToken")
    if isinstance(access, str) and isinstance(refresh, str):
        return access, refresh
    return None, None


def write_credentials(access, refresh):
    """Replace accessToken + refreshToken in-place, preserving every
    other field the file carries (subscriptionType, expiresAt, etc.).
    Atomic via tempfile + rename.
    """
    if not (isinstance(access, str) and access.startswith(ACCESS_FAKE_PREFIX)):
        return False, "access token does not match fake prefix"
    if not (isinstance(refresh, str) and refresh.startswith(REFRESH_FAKE_PREFIX)):
        return False, "refresh token does not match fake prefix"

    try:
        os.makedirs(os.path.dirname(CREDS_PATH), exist_ok=True)
        try:
            with open(CREDS_PATH, "r") as f:
                doc = json.load(f)
        except FileNotFoundError:
            doc = {}
        except json.JSONDecodeError:
            return False, "existing credentials file is not valid JSON"
        oauth = doc.get("claudeAiOauth")
        if not isinstance(oauth, dict):
            oauth = {}
            doc["claudeAiOauth"] = oauth
        oauth["accessToken"] = access
        oauth["refreshToken"] = refresh

        target_dir = os.path.dirname(CREDS_PATH) or "."
        fd, tmp = tempfile.mkstemp(prefix=".credentials.", suffix=".tmp",
                                   dir=target_dir)
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(doc, f, indent=2)
                f.write("\n")
            os.chmod(tmp, 0o600)
            os.replace(tmp, CREDS_PATH)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        return True, None
    except Exception as e:
        log("write failed: %s" % e)
        return False, str(e)


def serve(conn):
    f = conn.makefile("rwb", buffering=0)
    while True:
        line = f.readline()
        if not line:
            return
        try:
            req = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            f.write(b'{"ok":false,"reason":"bad json"}\n')
            continue
        op = req.get("op")
        if op == "read":
            access, refresh = read_credentials()
            resp = {"ok": True, "access": access, "refresh": refresh}
        elif op == "write":
            access = req.get("access")
            refresh = req.get("refresh")
            ok, reason = write_credentials(access, refresh)
            resp = {"ok": ok}
            if not ok:
                resp["reason"] = reason
        else:
            resp = {"ok": False, "reason": "unknown op: %r" % op}
        f.write((json.dumps(resp) + "\n").encode("utf-8"))


def main():
    while True:
        try:
            s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            s.connect((HOST_CID, TOKEN_PORT))
            log("connected to host vsock %d" % TOKEN_PORT)
            serve(s)
            log("connection closed by host")
        except (OSError, socket.error) as e:
            # Host hasn't opened the listener yet (or VM rebooted faster
            # than the host bridge instantiated). Back off briefly.
            if e.errno not in (errno.ECONNREFUSED, errno.ENOTCONN, errno.ENETUNREACH):
                log("vsock error: %s" % e)
        finally:
            try:
                s.close()
            except Exception:
                pass
        time.sleep(2)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
