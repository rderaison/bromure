# fake_daemon.py <socket>: answers what `workspaces ls` / `describe` read, as
# the Linux daemon does: /profiles ids in UPPERCASE, /vms ids in lowercase,
# one running VM with uptime and two tmux tabs. Exits when the socket file goes.
import json, os, socket, sys, threading
path = sys.argv[1]
WID = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"
profile = {"id": WID, "shortId": "0a1b2c3d4e5f", "name": "fake-ws", "tool": "claude",
           "authMode": "token", "state": "running", "running": True}
vm = {"id": WID.lower(), "shortId": "0a1b2c3d4e5f", "name": "fake-ws", "state": "running",
      "uptimeSeconds": 3725, "attached": False, "ip": "10.0.0.7",
      "tabs": [{"index": 0, "title": "claude", "active": True}, {"index": 1, "title": "shell"}]}
def answer(method, target):
    p = target.split("?")[0]
    if p == "/health": return 200, {"ok": True}
    if p == "/profiles": return 200, {"profiles": [profile]}
    if p.startswith("/profiles/"): return 200, profile
    if p == "/vms": return 200, {"vms": [vm]}
    if p.endswith("/exec"): return 200, {"exitCode": 0, "stdout": "", "stderr": ""}
    return 404, {"error": "not found"}
def serve(c):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = c.recv(65536)
        if not chunk: c.close(); return
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    lines = head.decode().split("\r\n")
    method, target, _ = lines[0].split(" ", 2)
    n = next((int(l.split(":")[1]) for l in lines[1:] if l.lower().startswith("content-length:")), 0)
    while len(rest) < n:
        chunk = c.recv(65536)
        if not chunk: break
        rest += chunk
    status, body = answer(method, target)
    b = json.dumps(body).encode()
    c.sendall(b"HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % (status, len(b)) + b)
    c.close()
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path); s.listen(16); s.settimeout(0.5)
while os.path.exists(path):
    try: c, _ = s.accept()
    except socket.timeout: continue
    threading.Thread(target=serve, args=(c,), daemon=True).start()
