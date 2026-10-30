#!/usr/bin/python3
"""Drives the bake VM's serial console (a QEMU unix-socket chardev) the way
UbuntuImageManager.runProvisioner drives VZ's hvc0: wait for a marker, type a line.
Usage: serial-driver.py <serial.sock> <log> <script.json>
script.json: [["wait", text, timeout_s, [failure texts]], ["send", line], ...]"""
import json, socket, sys, time
sock_path, log_path, script = sys.argv[1], sys.argv[2], json.load(open(sys.argv[3]))
s = socket.socket(socket.AF_UNIX)
for _ in range(200):
    try: s.connect(sock_path); break
    except OSError: time.sleep(0.05)
log = open(log_path, "ab", buffering=0)
buf = b""
def wait(text, timeout, failures):
    global buf
    deadline = time.monotonic() + timeout
    while True:
        i = buf.find(text.encode())
        if i >= 0: buf = buf[i + len(text):]; return
        for f in failures:
            j = buf.find(f.encode())
            if j >= 0:
                line = buf[j:].split(b"\n")[0].decode(errors="replace")
                sys.exit(f"bake failed: {line}")
        left = deadline - time.monotonic()
        if left <= 0: sys.exit(f"bake timed out waiting for {text!r}")
        s.settimeout(min(left, 5))
        try: chunk = s.recv(65536)
        except socket.timeout: continue
        if not chunk: sys.exit("serial closed (VM died?)")
        log.write(chunk); buf = buf[-65536:] + chunk
for step in script:
    if step[0] == "wait":
        t0 = time.monotonic(); wait(step[1], step[2], step[3] if len(step) > 3 else [])
        print(f"[bake] got {step[1]!r} after {time.monotonic()-t0:.1f}s", flush=True)
    elif step[0] == "send":
        time.sleep(0.2); s.sendall(step[1].encode() + b"\n")
