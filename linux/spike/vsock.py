#!/usr/bin/python3
"""Host side of the vsock checks.
  vsock.py call <cid> <port> [cmd]   host->guest: connect(cid,port), send cmd line, print reply
  vsock.py wait <cid> <port> <t>     poll connect until success; print seconds waited
  vsock.py listen <port> <logfile>   guest->host: accept on host CID, log lines"""
import socket, sys, time
m = sys.argv[1]
if m == "call":
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM); s.settimeout(30)
    s.connect((int(sys.argv[2]), int(sys.argv[3])))
    s.sendall(((sys.argv[4] if len(sys.argv) > 4 else "") + "\n").encode())
    out = b""
    while (x := s.recv(65536)): out += x
    sys.stdout.write(out.decode(errors="replace"))
elif m == "wait":
    t0 = time.monotonic(); lim = float(sys.argv[4])
    while time.monotonic() - t0 < lim:
        try:
            s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM); s.settimeout(1)
            s.connect((int(sys.argv[2]), int(sys.argv[3]))); s.sendall(b"echo ready\n"); s.recv(64); s.close()
            print(f"{time.monotonic()-t0:.3f}"); sys.exit(0)
        except OSError:
            s.close(); time.sleep(0.05)
    print("timeout"); sys.exit(1)
elif m == "listen":
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((socket.VMADDR_CID_ANY, int(sys.argv[2]))); s.listen(8)
    log = open(sys.argv[3], "a", buffering=1)
    while True:
        c, (cid, port) = s.accept()
        log.write(f"{time.time():.3f} from cid={cid} port={port}: {c.recv(4096).decode().strip()}\n"); c.close()
