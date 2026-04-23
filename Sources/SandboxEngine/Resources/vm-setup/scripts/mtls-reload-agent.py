#!/usr/bin/python3 -u
"""Bromure mTLS reload agent — runs inside the guest VM.

Holds a long-lived vsock connection to the host (port 5320). The host
sends a newline-delimited JSON line every time it reissues a leaf cert
for the managed profile attached to this session; we rewrite
/tmp/bromure/mtls/{cert,key,ca}.pem and re-run install-mtls.sh, which
reimports into Chromium's NSS db. New TLS handshakes after that point
pick up the new cert automatically; open connections keep using the old
one until they close.

Started from config-agent.py after install_managed_mtls succeeds, so
it's only running in managed sessions that have mTLS material on disk.

Message shape:
    {"type": "mtls_update",
     "certPem": "-----BEGIN CERTIFICATE-----...",
     "keyPem":  "-----BEGIN PRIVATE KEY-----...",
     "caPem":   "-----BEGIN CERTIFICATE-----..."}
"""

import json
import os
import signal
import socket
import subprocess
import sys
import time

VSOCK_PORT = 5320
HOST_CID = 2

MTLS_DIR = "/tmp/bromure/mtls"
CERT_PATH = f"{MTLS_DIR}/cert.pem"
KEY_PATH = f"{MTLS_DIR}/key.pem"
CA_PATH = f"{MTLS_DIR}/ca.pem"
INSTALL_SCRIPT = "/usr/local/bin/install-mtls.sh"


def log(*parts):
    print("mtls-reload:", *parts, file=sys.stderr, flush=True)


def apply_update(msg):
    cert = msg.get("certPem") or ""
    key = msg.get("keyPem") or ""
    ca = msg.get("caPem") or ""
    if not (cert and key and ca):
        log("incomplete update, ignoring")
        return
    os.makedirs(MTLS_DIR, exist_ok=True)
    # Write atomically via rename so install-mtls.sh never sees a
    # partially-written file.
    for path, data in ((CERT_PATH, cert), (KEY_PATH, key), (CA_PATH, ca)):
        tmp = path + ".new"
        with open(tmp, "w") as f:
            f.write(data)
        os.chmod(tmp, 0o600 if path == KEY_PATH else 0o644)
        os.replace(tmp, path)

    rc = subprocess.call([INSTALL_SCRIPT], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    if rc != 0:
        log(f"install-mtls.sh failed (rc={rc})")
    else:
        log("leaf rotated")


def run(sock):
    buf = b""
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            return
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.strip():
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError as e:
                log("bad json:", e)
                continue
            if msg.get("type") == "mtls_update":
                apply_update(msg)


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

    # Mirror the link-agent / corporate-guard-agent pattern: keep
    # retrying on connection loss so the agent survives brief host-side
    # flaps (e.g. VM pool warmup churn).
    while True:
        sock = None
        try:
            sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            sock.connect((HOST_CID, VSOCK_PORT))
            run(sock)
        except (ConnectionError, OSError):
            pass
        finally:
            if sock is not None:
                try:
                    sock.close()
                except Exception:
                    pass
        time.sleep(3)


if __name__ == "__main__":
    main()
