#!/usr/bin/env python3
"""
AWS SDK `credential_process` helper.

Configured in ~/.aws/config as:

    [default]
    credential_process = /mnt/bromure-meta/bromure-aws-creds.py

The SDK invokes this on demand, expects one JSON document on stdout, and
caches the result for the consumer-process lifetime (since we do not
emit Expiration). The host returns the real `AccessKeyId` paired with
a *fake* `SecretAccessKey`: that's enough for the SDK to compose a
SigV4-shaped request, but the signature is doomed. The host's MITM
proxy (AWSResigner) strips that signature and replaces it with one
computed from the real material before the request leaves the Mac.

Net effect: neither the real secret nor the STS session token ever
reach this VM's disk OR the SDK's process memory. If anything bypasses
the proxy (transparent CLI tools, stray HTTPS, …) AWS rejects with
InvalidSignatureException — fail-closed.
"""
import socket
import sys

SOCK_PATH = "/tmp/bromure-aws-creds.sock"


def main() -> int:
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(SOCK_PATH)
    except OSError as e:
        sys.stderr.write(f"bromure-aws-creds: connect {SOCK_PATH}: {e}\n")
        return 1

    try:
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            sys.stdout.buffer.write(chunk)
    finally:
        s.close()
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
