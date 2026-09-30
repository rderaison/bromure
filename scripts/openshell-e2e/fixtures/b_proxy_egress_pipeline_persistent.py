
import json
import os
import socket
import time

HOST = @@HOST_PY@@
PORT = @@PORT@@
READY = "/tmp/proxy-reload-ready"
GO = "/tmp/proxy-reload-go"
RESULT = "/tmp/proxy-reload-result"

def read_response(sock):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            return 0
        data += chunk
    headers, body = data.split(b"\r\n\r\n", 1)
    length = 0
    for line in headers.split(b"\r\n")[1:]:
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1].strip())
    while len(body) < length:
        chunk = sock.recv(4096)
        if not chunk:
            return 0
        body += chunk
    return int(headers.split(None, 2)[1])

target = f"{HOST}:{PORT}"
failed_closed = False
second_status = 0
try:
    with socket.create_connection((HOST, PORT), timeout=10) as sock:
        sock.sendall(
            f"GET /before-reload HTTP/1.1\r\nHost: {target}\r\nConnection: keep-alive\r\n\r\n".encode()
        )
        if read_response(sock) != 200:
            raise RuntimeError("initial tunneled request was denied")
        open(READY, "w").close()
        deadline = time.monotonic() + 120
        while not os.path.exists(GO) and time.monotonic() < deadline:
            time.sleep(0.1)
        if not os.path.exists(GO):
            raise RuntimeError("timed out waiting for policy reload signal")
        try:
            sock.sendall(
                f"GET /after-reload HTTP/1.1\r\nHost: {target}\r\nConnection: close\r\n\r\n".encode()
            )
            second_status = read_response(sock)
        except OSError:
            second_status = 0
        failed_closed = second_status != 200
finally:
    with open(RESULT, "w") as result:
        json.dump({"failed_closed": failed_closed, "second_status": second_status}, result, sort_keys=True)
