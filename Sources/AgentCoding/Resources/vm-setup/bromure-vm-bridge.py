#!/usr/bin/env python3
"""
Bromure AC in-VM bridge daemon.

Listens for several kinds of clients inside the VM and bridges each to
the host's MITM engine over vsock:

  • HTTP proxy:  127.0.0.1:8080 (TCP)              →  vsock CID 2 port 8443
  • ssh-agent:   /tmp/bromure-agent.sock (Unix)    →  vsock CID 2 port 8444
  • AWS creds:   /tmp/bromure-aws-creds.sock (Unix) →  vsock CID 2 port 8445

Bytes are pumped both directions per connection. No TLS, no inspection,
no buffering — just a raw pipe.

Why a Python script and not socat? socat doesn't support AF_VSOCK on
mainline Linux without out-of-tree patches. Python's socket module has
AF_VSOCK natively (Linux ≥ 4.8 + glibc/musl support, both present on
Ubuntu 24.04).

Lives in /mnt/bromure-meta and is executed by xinitrc — host-managed,
no base-image changes required.
"""
import os
import select
import signal
import socket
import sys
import threading
import traceback

HOST_CID = 2  # well-known CID for the macOS host in VZ
HTTP_PROXY_TCP_PORT = 8080
HTTP_PROXY_VSOCK_PORT = 8443
SSH_AGENT_VSOCK_PORT = 8444
SSH_AGENT_UNIX_PATH = "/tmp/bromure-agent.sock"
AWS_CREDS_VSOCK_PORT = 8445
AWS_CREDS_UNIX_PATH = "/tmp/bromure-aws-creds.sock"

LOG_PATH = "/tmp/bromure-vm-bridge.log"


def log(msg: str) -> None:
    try:
        with open(LOG_PATH, "a") as f:
            f.write(msg + "\n")
    except Exception:
        pass


def pump(src: socket.socket, dst: socket.socket) -> None:
    """Copy bytes from src to dst until either side closes."""
    try:
        while True:
            chunk = src.recv(64 * 1024)
            if not chunk:
                break
            dst.sendall(chunk)
    except (OSError, ConnectionError):
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def bridge(client: socket.socket, vsock_port: int, label: str) -> None:
    """Open a vsock connection to the host, then pump both directions."""
    try:
        host = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        host.connect((HOST_CID, vsock_port))
    except OSError as e:
        log(f"[{label}] vsock connect to host:{vsock_port} failed: {e}")
        client.close()
        return

    log(f"[{label}] bridging client → host:{vsock_port}")
    t1 = threading.Thread(target=pump, args=(client, host), daemon=True)
    t2 = threading.Thread(target=pump, args=(host, client), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    client.close()
    host.close()


def serve_http_proxy() -> None:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", HTTP_PROXY_TCP_PORT))
    s.listen(64)
    log(f"[http] listening on 127.0.0.1:{HTTP_PROXY_TCP_PORT}")
    while True:
        conn, _addr = s.accept()
        threading.Thread(
            target=bridge,
            args=(conn, HTTP_PROXY_VSOCK_PORT, "http"),
            daemon=True,
        ).start()


def serve_ssh_agent() -> None:
    try:
        os.unlink(SSH_AGENT_UNIX_PATH)
    except FileNotFoundError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(SSH_AGENT_UNIX_PATH)
    os.chmod(SSH_AGENT_UNIX_PATH, 0o600)
    s.listen(8)
    log(f"[ssh] listening on {SSH_AGENT_UNIX_PATH}")
    while True:
        conn, _addr = s.accept()
        threading.Thread(
            target=bridge,
            args=(conn, SSH_AGENT_VSOCK_PORT, "ssh"),
            daemon=True,
        ).start()


def serve_aws_creds() -> None:
    try:
        os.unlink(AWS_CREDS_UNIX_PATH)
    except FileNotFoundError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(AWS_CREDS_UNIX_PATH)
    os.chmod(AWS_CREDS_UNIX_PATH, 0o600)
    s.listen(8)
    log(f"[aws] listening on {AWS_CREDS_UNIX_PATH}")
    while True:
        conn, _addr = s.accept()
        threading.Thread(
            target=bridge,
            args=(conn, AWS_CREDS_VSOCK_PORT, "aws"),
            daemon=True,
        ).start()


def main() -> None:
    # Truncate log on each run.
    try:
        open(LOG_PATH, "w").close()
    except OSError:
        pass

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

    threading.Thread(target=serve_http_proxy, daemon=True).start()
    threading.Thread(target=serve_ssh_agent, daemon=True).start()
    threading.Thread(target=serve_aws_creds, daemon=True).start()

    # Park the main thread.
    signal.pause()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        log("fatal: " + traceback.format_exc())
        raise
