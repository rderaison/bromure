
import socket

HOST = "host.openshell.internal"
PORT = @@PORT@@
PAYLOAD = bytes([0x00, 0xff, 0x13, 0x37, 0x80, 0x0a]) + b"not-http-or-tls" + bytes(range(64))

with socket.create_connection((HOST, PORT), timeout=10) as sock:
    sock.sendall(PAYLOAD)
    echoed = b""
    while len(echoed) < len(PAYLOAD):
        chunk = sock.recv(len(PAYLOAD) - len(echoed))
        if not chunk:
            break
        echoed += chunk
    if echoed != PAYLOAD:
        raise RuntimeError("opaque payload changed in transit")
print("RAW_RELAY_OK")
