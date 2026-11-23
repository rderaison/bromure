"""fake_bromure_io.py <port-file> <log> [grants|no-grants]: a stand-in for
bromure.io's device-grant and enroll endpoints on 127.0.0.1 (tests only).
The grant is pending on the first poll, approved on the second; enroll
refuses every code (400) after logging it."""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_file, log, mode = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "grants")
polls = {"n": 0}

def note(line):
    with open(log, "a") as f:
        f.write(line + "\n")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, status, obj):
        b = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        note("%s %s" % (self.path, json.dumps(body, sort_keys=True)))
        if self.path == "/api/v1/device-grants":
            if mode == "no-grants":
                return self.reply(404, {"error": "Not found"})
            return self.reply(201, {"deviceCode": "dc-" + "x" * 40, "userCode": "BCDF-GHJK",
                                    "verificationUri": "http://127.0.0.1/app/enroll/approve",
                                    "verificationUriComplete": "http://127.0.0.1/app/enroll/approve?user_code=BCDF-GHJK",
                                    "interval": 1, "expiresIn": 60})
        if self.path == "/api/v1/device-grants/token":
            polls["n"] += 1
            if polls["n"] < 2:
                return self.reply(200, {"status": "pending", "interval": 1})
            return self.reply(200, {"status": "approved", "code": "e2e-approved-code-0123", "codeExpiresIn": 600})
        if self.path == "/api/v1/devices/enroll":
            return self.reply(400, {"error": "invalid-code"})
        self.reply(404, {"error": "Not found"})

srv = HTTPServer(("127.0.0.1", 0), H)
with open(port_file, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
