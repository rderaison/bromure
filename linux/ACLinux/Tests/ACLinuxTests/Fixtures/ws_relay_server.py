#!/usr/bin/env python3
"""A stand-in for bromure.io's connection relay and for the server's own SSH
port (stdlib only).

ws_relay_server.py <port-file> <event-log>

Two listeners on 127.0.0.1, on free ports written to <port-file> as
"<relay> <sshd>":

- the relay, a WebSocket server. The upgrade must carry `Authorization:
  Bearer …` and ask for /v1/connections/<id>/relay. What it then sends, as
  the dialer's bytes, depends on how <id> starts:
    banner-         "SSH-2.0-test\\r\\n", then stays open
    bulk-           1 MiB of pattern(), in frames of every length encoding
    relay-closes-   "x", and once "echo:x" came back, a close frame (1000)
    sshd-closes-    "bye": the sshd echoes it and closes its connection
    text-           a text frame (the relay is binary only)
    idle-<s>-       "a", nothing for <s> seconds, then "b"
- the "sshd", a TCP server that answers "echo:" and then every byte it
  receives, and closes after echoing a chunk that ends in "bye".

Events go to <event-log>, one a line:
  open <id> <path> <authorization>     reject <why>
  head <id> <the first bytes received, up to 8, as text>
  recv <id> <total bytes> <sha256 of all received so far>
  close <id> <code>                    eof <id>      (no close frame)
  sshd-open    sshd-eof (its peer closed)    sshd-closed (it closed, "bye")
"""
import base64, hashlib, os, socket, struct, sys, threading, time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
port_file, log_file = sys.argv[1], sys.argv[2]
lock = threading.Lock()


def log(line):
    with lock, open(log_file, "a") as f:
        f.write(line + "\n")


def pattern(n):
    return bytes((i * 31 + 7) & 0xFF for i in range(n))


def frame(opcode, payload=b""):
    n = len(payload)
    head = bytes([0x80 | opcode])
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + struct.pack("!H", n)
    else:
        head += bytes([127]) + struct.pack("!Q", n)
    return head + payload


def read_exact(c, n):
    b = b""
    while len(b) < n:
        chunk = c.recv(n - len(b))
        if not chunk:
            raise EOFError
        b += chunk
    return b


def unmask(data, mask):
    if not data:
        return data
    key = (mask * (len(data) // 4 + 1))[:len(data)]
    return (int.from_bytes(data, "big") ^ int.from_bytes(key, "big")).to_bytes(len(data), "big")


def dialer(c, cid, state):
    """The dialer's side of the script for this connection id."""
    try:
        if cid.startswith("banner-"):
            c.sendall(frame(0x2, b"SSH-2.0-test\r\n"))
        elif cid.startswith("bulk-"):
            data, at = pattern(1 << 20), 0
            for size in (1, 125, 126, 65535, 65536, 300000):
                c.sendall(frame(0x2, data[at:at + size]))
                at += size
            c.sendall(frame(0x2, data[at:]))
        elif cid.startswith("relay-closes-"):
            c.sendall(frame(0x2, b"x"))
            deadline = time.time() + 10
            while state["total"] < 6 and time.time() < deadline:
                time.sleep(0.02)
            c.sendall(frame(0x8, struct.pack("!H", 1000)))
            c.shutdown(socket.SHUT_WR)
        elif cid.startswith("sshd-closes-"):
            c.sendall(frame(0x2, b"bye"))
        elif cid.startswith("text-"):
            c.sendall(frame(0x1, b"not binary"))
        elif cid.startswith("idle-"):
            c.sendall(frame(0x2, b"a"))
            time.sleep(float(cid.split("-")[1]))
            c.sendall(frame(0x2, b"b"))
    except OSError:
        pass


def relay(c):
    req = b""
    while b"\r\n\r\n" not in req:
        chunk = c.recv(4096)
        if not chunk:
            return
        req += chunk
    lines = req.split(b"\r\n\r\n")[0].decode().split("\r\n")
    path = lines[0].split(" ")[1]
    headers = {k.strip().lower(): v.strip() for k, v in (l.split(":", 1) for l in lines[1:] if ":" in l)}
    auth = headers.get("authorization", "")
    parts = path.split("/")
    if not auth.startswith("Bearer ") or len(parts) < 3 or parts[-1] != "relay":
        c.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n")
        log("reject %s %s" % (path, auth or "no-bearer"))
        return
    cid = parts[-2]
    accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + GUID).encode()).digest()).decode()
    c.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
    log("open %s %s %s" % (cid, path, auth))
    state = {"total": 0}
    threading.Thread(target=dialer, args=(c, cid, state), daemon=True).start()
    seen = hashlib.sha256()
    try:
        while True:
            b0, b1 = read_exact(c, 2)
            op, masked, n = b0 & 0x0F, b1 & 0x80, b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", read_exact(c, 2))[0]
            elif n == 127:
                n = struct.unpack("!Q", read_exact(c, 8))[0]
            mask = read_exact(c, 4) if masked else b"\0\0\0\0"
            data = unmask(read_exact(c, n), mask)
            if op in (0x2, 0x0):
                if state["total"] == 0 and data:
                    log("head %s %s" % (cid, data[:8].decode("latin-1")))
                seen.update(data)
                state["total"] += len(data)
                log("recv %s %d %s" % (cid, state["total"], seen.hexdigest()))
            elif op == 0x9:
                c.sendall(frame(0xA, data))
            elif op == 0x8:
                code = struct.unpack("!H", data[:2])[0] if len(data) >= 2 else 0
                log("close %s %d" % (cid, code))
                break
    except (EOFError, OSError):
        log("eof %s" % cid)
    c.close()


def sshd(c):
    log("sshd-open")
    first = True
    try:
        while True:
            data = c.recv(65536)
            if not data:
                log("sshd-eof")
                break
            c.sendall((b"echo:" if first else b"") + data)
            first = False
            if data.endswith(b"bye"):
                log("sshd-closed")
                break
    except OSError:
        log("sshd-eof")
    c.close()


def listen(handler):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    s.listen(16)

    def loop():
        while True:
            conn, _ = s.accept()
            threading.Thread(target=handler, args=(conn,), daemon=True).start()

    threading.Thread(target=loop, daemon=True).start()
    return s.getsockname()[1]


ports = "%d %d" % (listen(relay), listen(sshd))
with open(port_file + ".tmp", "w") as f:
    f.write(ports)
os.rename(port_file + ".tmp", port_file)
while True:
    time.sleep(3600)
