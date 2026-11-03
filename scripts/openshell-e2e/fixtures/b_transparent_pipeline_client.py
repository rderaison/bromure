
import socket

target = "host.openshell.internal:@@PORT@@"
first = (
    f"GET /allowed HTTP/1.1\r\n"
    f"Host: {target}\r\nConnection: keep-alive\r\n\r\n"
)
second = (
    f"POST /blocked HTTP/1.1\r\n"
    f"Host: {target}\r\nContent-Length: 0\r\n\r\n"
)
with socket.create_connection(("host.openshell.internal", @@PORT@@), timeout=10) as sock:
    sock.sendall((first + second).encode())
    response = b""
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        response += chunk
responses = response.count(b"HTTP/1.1 ")
first_status = response.split(b"\r\n", 1)[0]
if responses != 2 or b" 200 " not in first_status or b"HTTP/1.1 403 Forbidden" not in response:
    raise RuntimeError(f"unexpected pipelined response: {response!r}")
print("TRANSPARENT_PIPELINE_DENIED")
