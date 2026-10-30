#!/usr/bin/python3
"""Minimal QMP client: qmp.py <sock> '<json cmd>' [...]; prints each reply."""
import socket, sys, json
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile("rw")
json.loads(f.readline()); f.write('{"execute":"qmp_capabilities"}\n'); f.flush(); f.readline()
for cmd in sys.argv[2:]:
    f.write(cmd + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "event" not in r: print(json.dumps(r)); break
