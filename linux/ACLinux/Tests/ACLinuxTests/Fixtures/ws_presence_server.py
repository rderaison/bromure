#!/usr/bin/env python3
"""A stand-in for bromure.io's /v1/device-channel presence rules (stdlib only).

ws_presence_server.py <port-file> <event-log> [ping-seconds]

Accepts one WebSocket client at a time on 127.0.0.1 (a free port, written
to <port-file>), requires `Authorization: Bearer …` on the upgrade, then,
as bromure.io's gateway does (shorter): sends a protocol ping every
PING_EVERY seconds and terminates (no close frame) a client that didn't
answer the previous ping with a pong. Each event goes to <event-log> as a
line: open <auth>, ping, pong, text <payload>, terminate, close <code>.
"""
import base64, hashlib, os, socket, struct, sys, threading, time

PING_EVERY = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

port_file, log_file = sys.argv[1], sys.argv[2]
lock = threading.Lock()


def log(line):
    with lock, open(log_file, "a") as f:
        f.write(line + "\n")


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


def serve(c):
    req = b""
    while b"\r\n\r\n" not in req:
        chunk = c.recv(4096)
        if not chunk:
            return
        req += chunk
    lines = req.split(b"\r\n\r\n")[0].decode().split("\r\n")
    headers = {k.strip().lower(): v.strip() for k, v in (l.split(":", 1) for l in lines[1:] if ":" in l)}
    auth = headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        c.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n")
        log("reject no-bearer")
        return
    accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + GUID).encode()).digest()).decode()
    c.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
    log("open " + auth)
    state = {"answered": True, "alive": True}

    def pinger():
        while state["alive"]:
            time.sleep(PING_EVERY)
            if not state["alive"]:
                return
            if not state["answered"]:
                log("terminate")
                state["alive"] = False
                try:
                    c.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                return
            state["answered"] = False
            try:
                c.sendall(frame(0x9, b"hb"))
                log("ping")
            except OSError:
                return

    threading.Thread(target=pinger, daemon=True).start()
    try:
        while state["alive"]:
            b0, b1 = read_exact(c, 2)
            op, masked, n = b0 & 0x0F, b1 & 0x80, b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", read_exact(c, 2))[0]
            elif n == 127:
                n = struct.unpack("!Q", read_exact(c, 8))[0]
            mask = read_exact(c, 4) if masked else b"\0\0\0\0"
            data = bytes(x ^ mask[i % 4] for i, x in enumerate(read_exact(c, n)))
            if op == 0xA:
                state["answered"] = True
                log("pong")
            elif op == 0x9:
                c.sendall(frame(0xA, data))
                log("client-ping")
            elif op == 0x1:
                log("text " + data.decode(errors="replace"))
            elif op == 0x8:
                code = struct.unpack("!H", data[:2])[0] if len(data) >= 2 else 0
                log("close %d" % code)
                break
    except (EOFError, OSError):
        pass
    state["alive"] = False
    c.close()


s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(4)
with open(port_file + ".tmp", "w") as f:
    f.write(str(s.getsockname()[1]))
os.rename(port_file + ".tmp", port_file)
while True:
    conn, _ = s.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
