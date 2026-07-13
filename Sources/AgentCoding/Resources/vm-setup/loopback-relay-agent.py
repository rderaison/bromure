#!/usr/bin/python3 -u
"""Bromure AC loopback-callback relay — runs inside the guest VM.

Lets the macOS host reach a loopback server the guest opened on
127.0.0.1:<port> — e.g. the redirect listener an OAuth CLI (grok-cli, gh,
gcloud, …) starts for its `redirect_uri=http://127.0.0.1:<port>/callback`.

The host can't reach the guest's loopback directly, so when it detects such a
login URL (relayed out via bromure-open) it opens the URL in the *host*
browser and, for the callback, connects to this agent over vsock and asks us
to splice the connection to 127.0.0.1:<port> inside the guest. The OAuth code
then lands in the CLI's own listener and token exchange succeeds — the
redirect_uri never changed, so x.ai's validation and PKCE still match.

Protocol (vsock port 5010 — guest listens, host connects):
    host -> guest:  "<target-port>\n"   (ASCII, newline-terminated)
    then raw bytes spliced bidirectionally with 127.0.0.1:<target-port>.
One vsock connection == one forwarded TCP connection.

Shipped via the per-launch meta share and started from xinitrc, so it needs
no base-image change.
"""

import os
import socket
import sys
import threading
import time
import traceback

VSOCK_PORT = 5010
MAX_PORT_HEADER = 16
# Host-readable status log (virtiofs outbox). Lets the host see why a callback
# forward succeeded/failed without needing guest shell access. Named .log so
# the host's outbox poller (which only acts on *.txt) ignores it.
STATUS_LOG = "/mnt/bromure-outbox/loopback-relay.log"


def log(*parts):
    msg = " ".join(str(p) for p in parts)
    print("loopback-relay:", msg, file=sys.stderr, flush=True)
    try:
        with open(STATUS_LOG, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
    except OSError:
        pass


def connect_loopback(port):
    """Connect to the CLI's callback listener. Try IPv4 127.0.0.1 first (what
    the redirect_uri advertises), then IPv6 ::1 — some runtimes bind only the
    v6 loopback for `localhost`."""
    last = None
    for family, host in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        sock = None
        try:
            sock = socket.socket(family, socket.SOCK_STREAM)
            sock.settimeout(5)
            sock.connect((host, port))
            sock.settimeout(None)
            return sock, host
        except OSError as exc:
            last = exc
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
    raise last if last else OSError("no loopback family")


def _pipe(src, dst, label=None):
    total = 0
    first = True
    try:
        while True:
            chunk = src.recv(65536)
            if not chunk:
                break
            if first and label:
                head = chunk.split(b"\r\n", 1)[0][:160].decode("latin1", "replace")
                log(f"{label} first line: {head!r}")
                first = False
            total += len(chunk)
            dst.sendall(chunk)
    except OSError as exc:
        if label:
            log(f"{label} pipe error after {total}B: {exc}")
    finally:
        if label:
            log(f"{label} done, {total}B")
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle_udp(vs, rest):
    """UDP tunnel mode (fat-client system-wide utun): all UDP to this guest is
    multiplexed over one vsock connection, each datagram framed
        [u16 bodyLen][u32 srcIP][u16 srcPort][u16 dstPort][payload]
    One UDP socket per (srcIP, srcPort, dstPort) → 127.0.0.1:<dstPort>; replies
    framed back the same way."""
    import struct
    socks = {}
    socks_lock = threading.Lock()
    vs_lock = threading.Lock()

    def reader(key, us):
        srcip, srcport, dstport = key
        try:
            while True:
                try:
                    data = us.recv(65535)   # b'' is a zero-length datagram, NOT EOF
                except OSError:
                    break                    # idle timeout or socket error → reap
                body = struct.pack("!IHH", srcip, srcport, dstport) + data
                with vs_lock:
                    try:
                        vs.sendall(struct.pack("!H", len(body)) + body)
                    except OSError:
                        break
        finally:
            with socks_lock:
                if socks.get(key) is us:
                    del socks[key]       # so a recurring flow re-dials cleanly
            try:
                us.close()
            except OSError:
                pass

    buf = rest
    try:
        while True:
            while len(buf) < 2:
                chunk = vs.recv(65536)
                if not chunk:
                    return
                buf += chunk
            (bodylen,) = struct.unpack("!H", buf[:2])
            while len(buf) < 2 + bodylen:
                chunk = vs.recv(65536)
                if not chunk:
                    return
                buf += chunk
            body, buf = buf[2:2 + bodylen], buf[2 + bodylen:]
            if len(body) < 8:
                continue
            srcip, srcport, dstport = struct.unpack("!IHH", body[:8])
            payload = body[8:]
            key = (srcip, srcport, dstport)
            with socks_lock:
                us = socks.get(key)
            if us is None:
                ns = None
                try:
                    ns = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    ns.settimeout(120)
                    ns.connect(("127.0.0.1", dstport))
                except OSError as exc:
                    log("udp socket 127.0.0.1:%d failed: %s" % (dstport, exc))
                    if ns is not None:
                        try:
                            ns.close()
                        except OSError:
                            pass
                    continue     # never tears down the whole tunnel
                us = ns
                with socks_lock:
                    socks[key] = us
                threading.Thread(target=reader, args=(key, us), daemon=True).start()
            try:
                us.send(payload)
            except OSError:
                pass
    finally:
        with socks_lock:
            remaining = list(socks.values())
            socks.clear()
        for us in remaining:
            try:
                us.close()
            except OSError:
                pass
        try:
            vs.close()
        except OSError:
            pass


def handle(vs):
    # Read the newline-terminated target port that prefixes the stream.
    buf = b""
    try:
        while b"\n" not in buf:
            chunk = vs.recv(64)
            if not chunk:
                vs.close()
                return
            buf += chunk
            # Cap only applies while we still haven't seen the newline — the
            # host may (and does) coalesce the "<port>\n" header with the start
            # of the request in one segment, so buf legitimately exceeds the
            # cap once the newline has arrived. Bailing here was the bug that
            # produced "Empty reply from server".
            if b"\n" not in buf and len(buf) > MAX_PORT_HEADER:
                vs.close()
                return
    except OSError:
        vs.close()
        return

    line, _, rest = buf.partition(b"\n")
    if line.strip() == b"UDP":
        handle_udp(vs, rest)
        return
    try:
        port = int(line.strip())
    except ValueError:
        vs.close()
        return
    if not (1 <= port <= 65535):
        vs.close()
        return

    try:
        tcp, host = connect_loopback(port)
    except OSError as exc:
        # grok's loopback callback server is single-shot: once it receives the
        # code it authenticates and shuts down. The browser often opens several
        # parallel/retry connections (and an HTTPS-upgrade attempt), so the
        # late ones find nothing listening. Rather than drop them — which Safari
        # shows as "the server unexpectedly dropped the connection" — return a
        # clean 200 so the tab lands on a tidy "you can close this" page. The
        # real code was already delivered on the connection that succeeded.
        log(f"callback for port {port}: listener gone ({exc}); returning synthetic 200")
        body = ("<!doctype html><html><body style=\"font-family:-apple-system,sans-serif;"
                "text-align:center;margin-top:4em\"><h2>Login complete</h2>"
                "<p>You can close this tab and return to the terminal.</p>"
                "</body></html>").encode("utf-8")
        resp = (b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: text/html; charset=utf-8\r\n"
                b"Connection: close\r\n"
                b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
        try:
            vs.sendall(resp)
        except OSError:
            pass
        vs.close()
        return

    # Any bytes that arrived after the port header belong to the TCP side.
    if rest:
        try:
            tcp.sendall(rest)
        except OSError:
            vs.close()
            tcp.close()
            return

    req_line = rest.split(b"\r\n", 1)[0][:160].decode("latin1", "replace") if rest else "(none yet)"
    log(f"callback for port {port}: forwarding via {host}; request: {req_line!r}")
    # Browser→grok (request body, if any) on a thread; grok→browser (response)
    # in the foreground with logging so we capture grok's status line.
    t = threading.Thread(target=_pipe, args=(vs, tcp), kwargs={"label": f"req[{port}]"}, daemon=True)
    t.start()
    _pipe(tcp, vs, label=f"resp[{port}]")
    t.join(timeout=1)
    try:
        vs.close()
    except OSError:
        pass
    try:
        tcp.close()
    except OSError:
        pass


def main():
    log(f"starting (pid {os.getpid()}, python {sys.version.split()[0]})")
    srv = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((socket.VMADDR_CID_ANY, VSOCK_PORT))
    srv.listen(8)
    log(f"listening on vsock port {VSOCK_PORT}")
    while True:
        try:
            conn, _ = srv.accept()
        except OSError:
            continue
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        # Surface why the relay died (e.g. missing AF_VSOCK / VMADDR_CID_ANY,
        # bind failure) to the host-readable status log instead of vanishing.
        log(f"FATAL: {exc!r}")
        log(traceback.format_exc())
        raise
