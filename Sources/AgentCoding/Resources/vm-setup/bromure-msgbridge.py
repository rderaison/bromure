#!/usr/bin/env python3
"""Bromure AC — Signal / WhatsApp relay, INSIDE the connector VM.

`daemon` (the bromure-msgbridge systemd unit) collects incoming messages:
Signal's over signal-cli-rest-api's receive websocket (json-rpc mode), for
the account named in config.json; WhatsApp's from GOWA's webhook, which
posts to this process on 127.0.0.1:9000. Each becomes one normalized JSON
line in the inbox the host drains (`drain`).

Every other verb is one call the host makes over the shell channel; each
prints one JSON object. Standard library only — the base image's python3.
"""
import base64, fcntl, http.server, json, os, socket, struct, sys, threading, time
import urllib.error, urllib.parse, urllib.request

DATA = "/var/lib/bromure-msgbridge"
CONFIG = os.path.join(DATA, "config.json")
INBOX = os.path.join(DATA, "inbox.jsonl")
SIGNAL = "http://127.0.0.1:18080"   # 8080 is the base image's own
WHATSAPP = "http://127.0.0.1:3000"
WEBHOOK_PORT = 9000


def out(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")))
    sys.stdout.write("\n")


def config():
    try:
        with open(CONFIG) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def call(method, url, body=None, timeout=30, headers=None):
    """(status, parsed-json-or-text). Never raises for HTTP errors."""
    data = None
    headers = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            status = r.status
    except urllib.error.HTTPError as e:
        raw = e.read()
        status = e.code
    except Exception as e:
        return 0, str(e)
    try:
        return status, json.loads(raw.decode() or "null")
    except ValueError:
        return status, raw.decode(errors="replace")


def append_inbox(item):
    item.setdefault("at", time.time())
    line = json.dumps(item, separators=(",", ":")) + "\n"
    with open(INBOX, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(line)
        fcntl.flock(f, fcntl.LOCK_UN)


# ---------------------------------------------------------------- websocket
# A minimal RFC 6455 client (text frames, ping/pong, close) — enough for the
# receive stream, no dependency to install.

def ws_connect(url, timeout=None):
    u = urllib.parse.urlparse(url)
    sock = socket.create_connection((u.hostname, u.port or 80), timeout=10)
    sock.settimeout(timeout)
    key = base64.b64encode(os.urandom(16)).decode()
    path = u.path + ("?" + u.query if u.query else "")
    sock.sendall(("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
                  "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
                  "Sec-WebSocket-Version: 13\r\n\r\n" % (path, u.hostname, u.port or 80, key)).encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(1)
        if not chunk:
            raise ConnectionError("websocket handshake closed")
        head += chunk
    if b" 101 " not in head.split(b"\r\n", 1)[0]:
        raise ConnectionError("websocket refused: " + head.split(b"\r\n", 1)[0].decode(errors="replace"))
    return sock


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("websocket closed")
        buf += chunk
    return buf


def _send_frame(sock, opcode, payload=b""):
    mask = os.urandom(4)
    head = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        head += bytes([0x80 | n])
    elif n < 65536:
        head += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        head += bytes([0x80 | 127]) + struct.pack(">Q", n)
    sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))


def ws_messages(sock):
    parts = b""
    while True:
        b1, b2 = _recv_exact(sock, 2)
        opcode, n = b1 & 0x0F, b2 & 0x7F
        if n == 126:
            n = struct.unpack(">H", _recv_exact(sock, 2))[0]
        elif n == 127:
            n = struct.unpack(">Q", _recv_exact(sock, 8))[0]
        mask = _recv_exact(sock, 4) if b2 & 0x80 else None
        payload = _recv_exact(sock, n)
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        if opcode == 0x8:
            return
        if opcode == 0x9:
            _send_frame(sock, 0xA, payload)
            continue
        if opcode in (0x1, 0x0):
            parts += payload
            if b1 & 0x80:
                yield parts.decode(errors="replace")
                parts = b""


# ------------------------------------------------------------------- daemon

def signal_item(obj, account):
    """signal-cli's receive envelope → an inbox item, or None. A message the
    account's owner sent to themselves (Note to Self, from their phone)
    arrives as a sync message addressed to the account itself."""
    env = (obj or {}).get("envelope") or {}
    ts = env.get("timestamp")
    data = env.get("dataMessage") or {}
    if data.get("message"):
        return {"channel": "signal", "from": env.get("sourceNumber") or env.get("source") or "",
                "name": env.get("sourceName") or "", "text": data["message"], "ts": ts}
    sent = (env.get("syncMessage") or {}).get("sentMessage") or {}
    dest = sent.get("destinationNumber") or sent.get("destination") or ""
    if sent.get("message") and account and dest == account:
        return {"channel": "signal", "from": account, "text": sent["message"], "ts": ts,
                "noteToSelf": True}
    return None


def signal_loop():
    while True:
        account = (config().get("signal") or {}).get("number")
        if not account:
            time.sleep(3)
            continue
        try:
            url = "ws://127.0.0.1:18080/v1/receive/" + urllib.parse.quote(account)
            sock = ws_connect(url)
            for text in ws_messages(sock):
                try:
                    item = signal_item(json.loads(text), account)
                except ValueError:
                    item = None
                if item:
                    append_inbox(item)
                if (config().get("signal") or {}).get("number") != account:
                    break
            sock.close()
        except Exception as e:
            sys.stderr.write("signal receive: %s\n" % e)
        time.sleep(3)


class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        self.send_response(200)
        self.end_headers()
        try:
            obj = json.loads(body.decode() or "{}")
        except ValueError:
            return
        if obj.get("event") != "message":
            return
        p = obj.get("payload") or {}
        text = p.get("body")
        if not text and isinstance(p.get("message"), dict):
            text = p["message"].get("text")
        if not text:
            return
        # Newer WhatsApp addresses chats — the self-chat included — by LID
        # (an opaque id) rather than phone JID; keep both so the host can
        # recognize "Message yourself".
        append_inbox({"channel": "whatsapp", "from": p.get("from") or "", "chat": p.get("chat_id") or "",
                      "fromLid": p.get("from_lid") or "", "chatLid": p.get("chat_lid") or "",
                      "name": p.get("sender_display_name") or p.get("from_name") or "",
                      "fromMe": bool(p.get("is_from_me")), "text": text, "ts": p.get("timestamp")})

    def log_message(self, *a):
        pass


def daemon():
    os.makedirs(DATA, exist_ok=True)
    threading.Thread(target=signal_loop, daemon=True).start()
    http.server.ThreadingHTTPServer(("127.0.0.1", WEBHOOK_PORT), WebhookHandler).serve_forever()


# -------------------------------------------------------------------- verbs

def drain():
    items = []
    if os.path.exists(INBOX):
        with open(INBOX, "r+") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            for line in f:
                try:
                    items.append(json.loads(line))
                except ValueError:
                    pass
            f.seek(0)
            f.truncate()
            fcntl.flock(f, fcntl.LOCK_UN)
    out({"messages": items})


def configure(b64):
    cfg = json.loads(base64.b64decode(b64).decode())
    tmp = CONFIG + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f)
    os.replace(tmp, CONFIG)
    out({"ok": True})


def probe():
    s_status, s_about = call("GET", SIGNAL + "/v1/about", timeout=5)
    a_status, accounts = call("GET", SIGNAL + "/v1/accounts", timeout=10) if s_status == 200 else (0, [])
    w_status, w = call("GET", WHATSAPP + "/app/status", timeout=5, headers=WA_HEADERS)
    # Any answer means the service is up (it errors until a device links).
    wr = (w or {}).get("results") or {} if isinstance(w, dict) else {}
    pending = 0
    try:
        with open(INBOX) as f:
            pending = sum(1 for _ in f)
    except OSError:
        pass
    out({"signalUp": s_status == 200,
         "signalAccounts": accounts if isinstance(accounts, list) else [],
         "whatsappUp": w_status != 0,
         "whatsappLoggedIn": bool(wr.get("is_logged_in")),
         "whatsappConnected": bool(wr.get("is_connected")),
         "inboxPending": pending,
         "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})


def signal_register(number, voice, captcha_b64=""):
    body = {"use_voice": voice == "1"}
    if captcha_b64:
        body["captcha"] = base64.b64decode(captcha_b64).decode().strip()
    status, res = call("POST", SIGNAL + "/v1/register/" + urllib.parse.quote(number), body, timeout=60)
    out({"status": status, "result": res})


def signal_verify(number, code, pin_b64=""):
    body = {}
    if pin_b64:
        body["pin"] = base64.b64decode(pin_b64).decode().strip()
    code = "".join(c for c in code if c.isdigit())
    status, res = call("POST", SIGNAL + "/v1/register/%s/verify/%s" % (urllib.parse.quote(number), code),
                       body, timeout=60)
    out({"status": status, "result": res})


def signal_link():
    status, res = call("GET", SIGNAL + "/v1/qrcodelink/raw?device_name=" + urllib.parse.quote("Bromure Switchboard"),
                       timeout=60)
    out({"status": status, "result": res})


def signal_accounts():
    status, res = call("GET", SIGNAL + "/v1/accounts", timeout=20)
    out({"status": status, "result": res})


def signal_send(number, to, b64):
    body = {"number": number, "recipients": [to], "message": base64.b64decode(b64).decode()}
    status, res = call("POST", SIGNAL + "/v2/send", body, timeout=60)
    out({"status": status, "result": res})


WA_DEVICE = "bromure"
WA_HEADERS = {"X-Device-Id": WA_DEVICE}


def wa(method, path, body=None, timeout=30):
    """A call to GOWA for the connector's device slot — created on first
    use (GOWA v3 is multi-device: no slot, no login)."""
    status, res = call(method, WHATSAPP + path, body, timeout, WA_HEADERS)
    if status in (400, 404) and "device" in json.dumps(res).lower():
        call("POST", WHATSAPP + "/devices", {"device_id": WA_DEVICE}, 30)
        status, res = call(method, WHATSAPP + path, body, timeout, WA_HEADERS)
    return status, res


def wa_login_qr():
    status, res = wa("GET", "/app/login", timeout=30)
    link = ((res or {}).get("results") or {}).get("qr_link") if isinstance(res, dict) else None
    png = ""
    if link:
        # The link names the service's own host; fetch it locally.
        path = urllib.parse.urlparse(link).path
        try:
            with urllib.request.urlopen(WHATSAPP + path, timeout=20) as r:
                png = base64.b64encode(r.read()).decode()
        except Exception:
            pass
    out({"status": status, "result": res, "png": png})


def wa_pair(phone):
    status, res = wa("GET", "/app/login-with-code?phone=" + urllib.parse.quote(phone), timeout=30)
    out({"status": status, "result": res})


def wa_status():
    status, res = wa("GET", "/app/status", timeout=10)
    info = {}
    if isinstance(res, dict):
        info = res.get("results") or {}
    # The logged-in account's JID, when the service can say.
    d_status, devices = call("GET", WHATSAPP + "/devices", timeout=10)
    out({"status": status, "result": info, "devices": devices if d_status == 200 else None})


def wa_send(to, b64):
    body = {"phone": to, "message": base64.b64decode(b64).decode()}
    status, res = wa("POST", "/send/message", body, timeout=60)
    out({"status": status, "result": res})


def wa_logout():
    status, res = wa("GET", "/app/logout", timeout=30)
    out({"status": status, "result": res})


def signal_unregister(number):
    status, res = call("POST", SIGNAL + "/v1/unregister/" + urllib.parse.quote(number),
                       {"delete_account": False, "delete_local_data": True}, timeout=60)
    out({"status": status, "result": res})


VERBS = {
    "daemon": daemon, "drain": drain, "configure": configure, "probe": probe,
    "signal-register": signal_register, "signal-verify": signal_verify,
    "signal-link": signal_link, "signal-accounts": signal_accounts,
    "signal-send": signal_send, "signal-unregister": signal_unregister,
    "wa-login-qr": wa_login_qr, "wa-pair": wa_pair, "wa-status": wa_status,
    "wa-send": wa_send, "wa-logout": wa_logout,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in VERBS:
        sys.stderr.write("usage: %s %s\n" % (sys.argv[0], "|".join(sorted(VERBS))))
        sys.exit(2)
    VERBS[sys.argv[1]](*sys.argv[2:])
