#!/usr/bin/env python3
"""
AWS SDK `credential_process` helper.

Configured in ~/.aws/config as:

    [default]
    credential_process = /mnt/bromure-meta/bromure-aws-creds.py

The SDK invokes this on demand, expects one JSON document on stdout, and
caches the result for the consumer-process lifetime (since we do not
emit Expiration). The real access key + secret never touch the guest's
disk: we connect to the bromure-vm-bridge's Unix socket, which forwards
over vsock to the host's MITM engine, which writes the SDK payload back.
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
