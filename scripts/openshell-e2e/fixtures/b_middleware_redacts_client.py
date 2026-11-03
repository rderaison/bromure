
import json
import socket

HOST = "host.openshell.internal"
PORT = @@PORT@@
SECRET = "sk-1234567890abcdef"

def read_response(sock):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("incomplete response headers")
        data += chunk
    headers, body = data.split(b"\r\n\r\n", 1)
    length = 0
    for line in headers.split(b"\r\n")[1:]:
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1].strip())
    while len(body) < length:
        chunk = sock.recv(4096)
        if not chunk:
            break
        body += chunk
    status = int(headers.split(None, 2)[1])
    if status != 200:
        raise RuntimeError(f"request failed with HTTP {status}: {body!r}")
    return json.loads(body[:length])

def request_bytes(target):
    body = json.dumps({"api_key": SECRET}, separators=(",", ":")).encode()
    return (
        f"POST {target} HTTP/1.1\r\n"
        f"Host: {HOST}:{PORT}\r\n"
        "Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n\r\n"
    ).encode() + body

def request_once():
    with socket.create_connection((HOST, PORT), timeout=10) as sock:
        sock.sendall(request_bytes("/middleware"))
        return read_response(sock)

print(json.dumps({"first": request_once(), "second": request_once()}, sort_keys=True))
