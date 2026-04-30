#!/usr/bin/env python3
"""
Bromure AC — OpenAI Codex / ChatGPT subscription-token agent.

Mirrors `claude-token-agent.py` but for Codex CLI's auth file at
~/.codex/auth.json. Listens on host vsock 8447. Two RPCs:

  read   → returns access/refresh/id_token from `tokens` block.
  write  → overwrites the same three fields atomically.

Shape on disk (Codex CLI 0.20+):

  {
    "OPENAI_API_KEY": null,
    "tokens": {
      "id_token":      "eyJ…",
      "access_token":  "eyJ…",
      "refresh_token": "eyJ…",
      "account_id":    "..."
    },
    "last_refresh": "..."
  }

Same security invariant as the Claude agent: real → host (one-way for
read), fake → VM (one-way for write). The agent NEVER asks the host
for anything; it only answers requests pushed in over the persistent
vsock connection.
"""
import errno
import json
import os
import socket
import sys
import tempfile
import time

HOST_CID = 2
TOKEN_PORT = 8447

LOG_PATH = "/tmp/bromure-codex-token.log"
CREDS_PATH = os.path.expanduser("~/.codex/auth.json")

# Codex tokens have structure that we deliberately preserve in the
# fake: id_token / access_token are JWTs whose third segment (the
# signature) starts with this marker; refresh_token has the literal
# `rt_<marker>-…` shape. The agent's write validator enforces these
# so a buggy host can't pollute the file with arbitrary bytes.
JWT_SIG_FAKE_MARKER = "brm-cdX-sig"
REFRESH_FAKE_MARKER = "brm-cdX-rfs"


def _is_jwt_fake(tok):
    if not isinstance(tok, str):
        return False
    parts = tok.split(".")
    if len(parts) != 3:
        return False
    return parts[2].startswith(JWT_SIG_FAKE_MARKER)


def _is_refresh_fake(tok):
    if not isinstance(tok, str):
        return False
    return tok.startswith("rt_" + REFRESH_FAKE_MARKER + "-")


def log(msg):
    try:
        with open(LOG_PATH, "a") as f:
            f.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), msg))
    except Exception:
        pass


def read_credentials():
    try:
        with open(CREDS_PATH, "r") as f:
            data = json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError) as e:
        log("read failed: %s" % e)
        return None
    tokens = data.get("tokens")
    if not isinstance(tokens, dict):
        return None
    out = {
        "access": tokens.get("access_token"),
        "refresh": tokens.get("refresh_token"),
        "id_token": tokens.get("id_token"),
    }
    if not all(isinstance(v, str) for v in out.values()):
        return None
    return out


def write_credentials(access, refresh, id_token):
    if not _is_jwt_fake(access):
        return False, "access token does not have brm-cdX-sig signature marker"
    if not _is_refresh_fake(refresh):
        return False, "refresh token does not have brm-cdX-rfs marker"
    if not _is_jwt_fake(id_token):
        return False, "id token does not have brm-cdX-sig signature marker"

    try:
        os.makedirs(os.path.dirname(CREDS_PATH), exist_ok=True)
        try:
            with open(CREDS_PATH, "r") as f:
                doc = json.load(f)
        except FileNotFoundError:
            doc = {}
        except json.JSONDecodeError:
            return False, "existing credentials file is not valid JSON"
        tokens = doc.get("tokens")
        if not isinstance(tokens, dict):
            tokens = {}
            doc["tokens"] = tokens
        tokens["access_token"] = access
        tokens["refresh_token"] = refresh
        tokens["id_token"] = id_token

        target_dir = os.path.dirname(CREDS_PATH) or "."
        fd, tmp = tempfile.mkstemp(prefix="auth.", suffix=".tmp", dir=target_dir)
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
            t = read_credentials()
            if t is None:
                resp = {"ok": True, "access": None, "refresh": None, "id_token": None}
            else:
                resp = {"ok": True, **t}
        elif op == "write":
            ok, reason = write_credentials(req.get("access"),
                                            req.get("refresh"),
                                            req.get("id_token"))
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
