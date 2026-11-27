#!/usr/bin/env python3
"""A stand-in for two HTTP services the daemon calls out to (stdlib only).

http_stub_server.py <port-file> <event-log>

Listens on 127.0.0.1 (a free port, written to <port-file>).

- bromure.io's device sign-out, POST /api/v1/devices/self-revoke. What it
  answers goes by how the bearer starts:
    ok-      200 {"ok": true}
    gone-    401 {"error": "unauthorized"}   (revoked or expired: one answer)
    late2-   401 twice, then 200             (a credential still propagating)
    boom-    500 {"error": "internal"}
- a custom inference server's model list, GET /v1/models:
    200 {"object": "list", "data": [{"id": "zeta"}, {"id": "alpha"}]},
    or 401 when the bearer is "wrong".

Each request goes to <event-log> as a line:
  <method> <path> auth=<authorization, or -> agent=<user-agent, or ->
"""
import json, os, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port_file, log_file = sys.argv[1], sys.argv[2]
lock = threading.Lock()
seen = {}


def log(line):
    with lock, open(log_file, "a") as f:
        f.write(line + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def answer(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def note(self):
        auth = self.headers.get("Authorization") or "-"
        log("%s %s auth=%s agent=%s" % (self.command, self.path, auth, self.headers.get("User-Agent") or "-"))
        return auth[len("Bearer "):] if auth.startswith("Bearer ") else ""

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        bearer = self.note()
        if self.path != "/api/v1/devices/self-revoke":
            return self.answer(404, {"error": "not_found"})
        with lock:
            seen[bearer] = seen.get(bearer, 0) + 1
            count = seen[bearer]
        if bearer.startswith("ok-") or (bearer.startswith("late2-") and count > 2):
            return self.answer(200, {"ok": True})
        if bearer.startswith("boom-"):
            return self.answer(500, {"error": "internal"})
        return self.answer(401, {"error": "unauthorized"})

    def do_GET(self):
        bearer = self.note()
        if self.path != "/v1/models":
            return self.answer(404, {"error": "not_found"})
        if bearer == "wrong":
            return self.answer(401, {"error": {"message": "bad key"}})
        return self.answer(200, {"object": "list", "data": [{"id": "zeta"}, {"id": "alpha"}]})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file + ".tmp", "w") as f:
    f.write(str(server.server_address[1]))
os.rename(port_file + ".tmp", port_file)
server.serve_forever()
