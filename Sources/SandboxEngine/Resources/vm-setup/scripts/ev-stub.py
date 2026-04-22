#!/usr/bin/env python3
"""Bromure stub for Google Endpoint Verification's native messaging helper.

The EV Chrome extension (`callobklhcbilhphinckomhgkigmfocg`) collects
device state by spawning a helper binary over Chromium's Native
Messaging channel and asking questions: OS, disk encryption, screen
lock, client certificates in the trust store, etc. The extension
then relays those answers to Google's Context-Aware Access evaluator,
which is how CEL expressions like `device.certificates.exists(...)`
get populated in the Admin console.

Stock Google ships a helper binary inside a Debian package that's
glibc-linked and depends on systemd. Bromure runs Alpine/musl with
OpenRC, so instead of wrestling that binary onto the guest we just
fake the helper: Bromure IS the managed device, by construction —
there's no per-user attestation to measure, and any "compliance
check" will always succeed for sessions that got this far (the
managed profile was authenticated to the control plane, the mTLS
leaf was issued by our CA, the cert is on disk at a known path).

What this stub reports to the extension:
  * OS / version / manufacturer / model: canonical Bromure values
  * disk encryption: ENCRYPTED (the ephemeral disk is effectively so —
    it's a CoW clone that dies with the VM)
  * screen lock: secured
  * certificates: a single entry carrying the leaf cert Bromure just
    installed in the guest NSS db, with its SHA-256 fingerprint and
    the issuing CA fingerprint so admins can gate CAA rules on the
    specific CA.

## Protocol notes

Chromium's Native Messaging framing:
  4-byte little-endian length prefix, then that many bytes of UTF-8
  JSON. The browser pipes messages on stdin/stdout, keeping the
  process alive as long as the extension holds a Port open.

Google's *specific* request/response shapes are not public. This
stub logs every incoming message to `/tmp/bromure/ev-stub.log` so
we can post-mortem what the extension asks for in practice and
refine responses. The initial responses below are best-effort
guesses based on field names visible in EV / BeyondCorp docs. If
the extension rejects a message or refuses to register the device
with Google, iterate on the log.
"""

import hashlib
import json
import os
import struct
import subprocess
import sys
import time

LOG_PATH = "/tmp/bromure/ev-stub.log"
CERT_PATH = "/tmp/bromure/mtls/cert.pem"
CA_PATH = "/tmp/bromure/mtls/ca.pem"


def log(*parts):
    """Append a timestamped line to the post-mortem log. Best-effort:
    we never let logging crash the helper or it'll take the extension
    down with it."""
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, "a") as f:
            f.write(f"{time.time():.3f} " + " ".join(str(p) for p in parts) + "\n")
    except Exception:
        pass


def read_message():
    """Read one framed Native Messaging message. Returns None on EOF."""
    hdr = sys.stdin.buffer.read(4)
    if len(hdr) < 4:
        return None
    length = struct.unpack("<I", hdr)[0]
    body = sys.stdin.buffer.read(length)
    if len(body) < length:
        return None
    try:
        return json.loads(body.decode("utf-8"))
    except Exception as e:
        log("decode error:", e, "body=", body[:200])
        return {}


def write_message(obj):
    data = json.dumps(obj).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("<I", len(data)))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def sha256_hex_of_pem(path):
    """SHA-256 fingerprint (upper-case hex, colon-less) of a PEM cert's
    DER bytes. Returns None if the file is missing or unparseable."""
    try:
        der = subprocess.check_output(
            ["openssl", "x509", "-in", path, "-outform", "DER"],
            stderr=subprocess.DEVNULL,
        )
        return hashlib.sha256(der).hexdigest().upper()
    except Exception as e:
        log("fingerprint fail:", path, e)
        return None


def cert_subject_issuer(path):
    """(subject, issuer) as short strings; ('?','?') on error."""
    def _line(flag):
        try:
            return subprocess.check_output(
                ["openssl", "x509", "-in", path, "-noout", flag],
                stderr=subprocess.DEVNULL,
            ).decode().strip().split("=", 1)[-1].strip()
        except Exception:
            return "?"
    return _line("-subject"), _line("-issuer")


def build_device_state():
    """Canonical 'fully compliant + cert present' snapshot."""
    state = {
        "os": "linux",
        "os_type": "linux",
        "os_version": "Alpine Linux (Bromure)",
        "disk_encryption": "ENCRYPTED",
        "screen_lock_secured": True,
        "manufacturer": "Bromure",
        "model": "Managed Browser",
        "serial_number": os.uname().nodename,
        "hostname": os.uname().nodename,
        "certificates": [],
    }
    if os.path.exists(CERT_PATH) and os.path.exists(CA_PATH):
        leaf_fp = sha256_hex_of_pem(CERT_PATH)
        ca_fp = sha256_hex_of_pem(CA_PATH)
        subj, issuer = cert_subject_issuer(CERT_PATH)
        if leaf_fp and ca_fp:
            state["certificates"].append({
                "is_valid": True,
                "fingerprint": leaf_fp,
                "root_ca_fingerprint": ca_fp,
                "issuer": issuer,
                "subject": subj,
            })
    return state


def handle(msg):
    """Every request gets the same 'all good' answer. We echo back any
    request id the extension sent so it can correlate."""
    state = build_device_state()
    resp = {
        "status": "ok",
        "success": True,
        "device_state": state,
    }
    if isinstance(msg, dict) and "id" in msg:
        resp["id"] = msg["id"]
    return resp


def main():
    log("ev-stub up pid=%d argv=%s" % (os.getpid(), sys.argv))
    while True:
        msg = read_message()
        if msg is None:
            log("stdin EOF, exit")
            return
        log("REQ", json.dumps(msg)[:800])
        try:
            resp = handle(msg)
        except Exception as e:
            log("handler threw:", e)
            resp = {"status": "error", "error": str(e)}
        log("RESP", json.dumps(resp)[:800])
        try:
            write_message(resp)
        except BrokenPipeError:
            log("stdout closed, exit")
            return


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log("fatal:", e)
