#!/usr/bin/python3
"""Network test services, the far end for the bridge tests' guests (tap and passt alike).
usage: net-test-services.py <bind-ip> <base-port> [ready-file]
  base+0  sink:  reads to EOF, answers the byte count, closes      (throughput)
  base+1  echo:  echoes everything back                            (latency)
  base+2  hello: writes b"hello from <bind-ip>\\n", closes          (reachability)
  base+3  source: reads a decimal byte count + newline, sends that many bytes, closes (downloads)"""
import os, socket, sys, threading
ip, base = sys.argv[1], int(sys.argv[2])

def serve(port, handler):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((ip, port)); s.listen(64)
    def loop():
        while True:
            c, _ = s.accept()
            threading.Thread(target=handler, args=(c,), daemon=True).start()
    threading.Thread(target=loop, daemon=True).start()

def sink(c):
    n = 0
    while (d := c.recv(1 << 20)): n += len(d)
    c.sendall(b"%d\n" % n); c.close()

def echo(c):
    c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    while (d := c.recv(65536)): c.sendall(d)
    c.close()

def hello(c):
    c.sendall(b"hello from %s\n" % ip.encode()); c.close()

def source(c):
    n = int(c.makefile().readline().strip() or 0)
    buf = bytes(1 << 20)
    try:
        while n > 0:
            k = min(n, len(buf)); c.sendall(buf[:k]); n -= k
    except OSError:
        pass
    c.close()

serve(base, sink); serve(base + 1, echo); serve(base + 2, hello); serve(base + 3, source)
if len(sys.argv) > 3: open(sys.argv[3], "w").write("ready\n")
threading.Event().wait()
