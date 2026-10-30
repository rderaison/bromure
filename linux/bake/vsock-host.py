#!/usr/bin/python3
"""Host side of bromure-agentd's shell pool: vsock-host.py [port] [timeout]. Listens on
vsock 5800 (the guest dials the host, ShellBridge.swift), prints "ready", then the
connecting CID on the first connection, and exits."""
import socket, sys
port = int(sys.argv[1]) if len(sys.argv) > 1 else 5800
s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((socket.VMADDR_CID_ANY, port)); s.listen(16); s.settimeout(float(sys.argv[2]) if len(sys.argv) > 2 else 180)
print("ready", flush=True)
c, (cid, p) = s.accept()
print(f"connected cid={cid}", flush=True)
