#!/usr/bin/env python3
"""Bromure AWS credential_process helper.

Invoked by the AWS SDK (`credential_process` directive in
~/.aws/config) whenever a tool inside the VM needs AWS credentials.
Dials AF_VSOCK CID_HOST:8445 — the host-side AwsCredentialServer's
hvsocket listener — and writes the credential_process JSON payload
back to stdout.

Wire:
  aws / boto3 / terraform → /usr/local/bin/bromure-aws-credentials
                          → AF_VSOCK CID_HOST:8445
                          → host AwsCredentialServerHvSocketListener
                          → AwsCredentialServer.WriteCredentialProcessPayloadAsync

The first line we send to the host is the profile UUID; the rest is
the host's JSON document. This way one Bromure host instance can
multiplex multiple guest VMs each scoped to a different profile.

The host vends a FAKE secret_access_key — signed requests fail at
AWS unless the proxy intercepts and re-signs with the real material
(which never reaches this VM). Fail-closed by design.
"""
import os
import socket
import sys


HOST_VSOCK_PORT = 8445
# Per-session home overlay writes this; SessionHomeBuilder lays it
# at /home/ubuntu/.bromure-profile-id. Override via env if the
# helper is invoked outside the standard ubuntu shell.
PROFILE_ID_FILE = os.environ.get(
    "BROMURE_PROFILE_ID_FILE",
    os.path.expanduser("~/.bromure-profile-id"))


def main() -> int:
    try:
        with open(PROFILE_ID_FILE) as f:
            profile_id = f.read().strip()
    except OSError as e:
        # AWS SDK wants this exact shape to surface the error.
        print(
            '{"Version":1,"Error":"bromure-aws-credentials: cannot read '
            + PROFILE_ID_FILE
            + ": "
            + str(e).replace('"', "")
            + '"}'
        )
        return 1

    if not profile_id:
        print(
            '{"Version":1,"Error":"bromure-aws-credentials: empty profile id"}'
        )
        return 1

    try:
        sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    except (OSError, AttributeError) as e:
        # AF_VSOCK is python 3.7+ and requires kernel support.
        print(
            '{"Version":1,"Error":"bromure-aws-credentials: AF_VSOCK unavailable: '
            + str(e).replace('"', "")
            + '"}'
        )
        return 1

    try:
        # CID 2 = the Hyper-V host.
        sock.connect((2, HOST_VSOCK_PORT))
        sock.sendall((profile_id + "\n").encode("ascii"))
        # The host writes a JSON document and closes.
        with sock.makefile("rb") as rd:
            data = rd.read()
    except OSError as e:
        print(
            '{"Version":1,"Error":"bromure-aws-credentials: vsock IO: '
            + str(e).replace('"', "")
            + '"}'
        )
        return 1
    finally:
        try:
            sock.close()
        except OSError:
            pass

    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
