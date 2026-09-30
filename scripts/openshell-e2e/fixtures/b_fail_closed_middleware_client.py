
import socket

HOST = "host.openshell.internal"
PORT = @@PORT@@
PAYLOAD = bytes([0x00, 0xff, 0x13, 0x37]) + b"not-http-or-tls"

with socket.create_connection((HOST, PORT), timeout=10) as sock:
    sock.sendall(PAYLOAD)
    denial = b""
    while True:
        try:
            chunk = sock.recv(4096)
        except ConnectionResetError:
            break
        if not chunk:
            break
        denial += chunk
    if denial and (
        b"HTTP/1.1 403 Forbidden" not in denial
        or b"unsupported_l7_protocol" not in denial
    ):
        raise RuntimeError(f"missing fail-closed middleware denial: {denial!r}")
print("UNINSPECTABLE_MIDDLEWARE_BLOCKED")
