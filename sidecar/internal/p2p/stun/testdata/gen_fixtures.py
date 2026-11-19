#!/usr/bin/env python3
"""Regenerates the STUN/TURN golden fixtures (*.hex) next to this script.

Each message is laid out BY HAND here, following the Swift encoder in
Sources/AgentCoding/P2P/STUN.swift (STUNMessage.encoded / sign / addXorAddress)
and the request builders in TurnTCP.swift (allocateTCP, createPermission,
refresh, bindDataConnection, transact's USERNAME, REALM, NONCE, then
MESSAGE-INTEGRITY order). It deliberately shares no code with the Go
encoder: MD5 / HMAC-SHA1 / CRC-32 come from Python's hashlib/hmac/zlib.

    header  = type(2) | length(2, body bytes, unpadded attr lengths) | 2112A442 | txid(12)
    attr    = type(2) | len(2, unpadded) | value | zero padding to 4
    MI      = HMAC-SHA1(key, msg up to MI with header length counting MI's 24 bytes)
    key     = MD5("user:realm:password")
    FP      = CRC32(msg up to FP, length counting FP's 8 bytes) ^ 0x5354554E
    XOR-ADDR= 00 | family | port^0x2112 | addr ^ (cookie [|| txid for v6])

Run:  python3 gen_fixtures.py   (writes the .hex files; the Go test reads them)
"""
import hashlib, hmac, ipaddress, os, struct, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
COOKIE = bytes.fromhex("2112A442")
TXID = bytes(range(1, 13))           # 01 02 .. 0c
USER, REALM, NONCE, PASS = "1700000000:conn-1", "bromure.io", "abcdef0123456789", "s3cret-pass"

def attr(t, v):
    a = struct.pack(">HH", t, len(v)) + v
    return a + b"\0" * (-len(a) % 4)

def msg(t, attrs, txid=TXID):
    body = b"".join(attr(a, v) for a, v in attrs)
    return struct.pack(">HH", t, len(body)) + COOKIE + txid + body

def key():
    return hashlib.md5(f"{USER}:{REALM}:{PASS}".encode()).digest()

def signed(t, attrs, txid=TXID):
    attrs = attrs + [(0x0006, USER.encode()), (0x0014, REALM.encode()), (0x0015, NONCE.encode())]
    pre = bytearray(msg(t, attrs, txid))
    struct.pack_into(">H", pre, 2, len(pre) - 20 + 24)
    mac = hmac.new(key(), bytes(pre), hashlib.sha1).digest()
    return msg(t, attrs + [(0x0008, mac)], txid)

def with_fp(raw):
    pre = bytearray(raw)
    struct.pack_into(">H", pre, 2, len(pre) - 20 + 8)
    fp = zlib.crc32(bytes(pre)) ^ 0x5354554E
    out = bytearray(raw + attr(0x8028, struct.pack(">I", fp)))
    struct.pack_into(">H", out, 2, len(out) - 20)
    return bytes(out)

def xaddr(ip, port, txid=TXID):
    a = ipaddress.ip_address(ip)
    xp = port ^ 0x2112
    if a.version == 4:
        return bytes([0, 1]) + struct.pack(">H", xp) + bytes(x ^ y for x, y in zip(a.packed, COOKIE))
    return bytes([0, 2]) + struct.pack(">H", xp) + bytes(x ^ y for x, y in zip(a.packed, COOKIE + txid))

def err(code, reason):
    return bytes([0, 0, code // 100, code % 100]) + reason.encode()

FIXTURES = {
    "binding_request": ("Binding request, no attributes (STUNMessage(type: .bindingRequest))",
                        msg(0x0001, [])),
    "binding_success_v4": ("Binding success, XOR-MAPPED-ADDRESS 203.0.113.7:54321",
                           msg(0x0101, [(0x0020, xaddr("203.0.113.7", 54321))])),
    "binding_success_v6": ("Binding success, XOR-MAPPED-ADDRESS [2001:db8::1]:443 (v6 XORs cookie||txid)",
                           msg(0x0101, [(0x0020, xaddr("2001:db8::1", 443))])),
    "allocate_noauth": ("Allocate, REQUESTED-TRANSPORT TCP (6,0,0,0), unauthenticated first try",
                        msg(0x0003, [(0x0019, bytes([6, 0, 0, 0]))])),
    "allocate_401": ("Allocate error 401 Unauthorized with REALM bromure.io + NONCE (server -> client)",
                     msg(0x0113, [(0x0009, err(401, "Unauthorized")), (0x0014, REALM.encode()), (0x0015, NONCE.encode())])),
    "allocate_438": ("Allocate error 438 Stale Nonce with a new NONCE (server -> client)",
                     msg(0x0113, [(0x0009, err(438, "Stale Nonce")), (0x0015, b"fedcba9876543210")])),
    "allocate_auth": ("Allocate retried with USERNAME, REALM, NONCE, MESSAGE-INTEGRITY (long-term key)",
                      signed(0x0003, [(0x0019, bytes([6, 0, 0, 0]))])),
    "allocate_success": ("Allocate success: XOR-RELAYED 203.0.113.50:49152, XOR-MAPPED 198.51.100.20:61000, LIFETIME 600",
                         msg(0x0103, [(0x0016, xaddr("203.0.113.50", 49152)), (0x0020, xaddr("198.51.100.20", 61000)),
                                      (0x000D, struct.pack(">I", 600))])),
    "create_permission_auth": ("CreatePermission XOR-PEER-ADDRESS 198.51.100.20 port 0, authenticated",
                               signed(0x0008, [(0x0012, xaddr("198.51.100.20", 0))])),
    "refresh_auth": ("Refresh (no LIFETIME), authenticated", signed(0x0004, [])),
    "connection_bind_auth": ("ConnectionBind CONNECTION-ID 0x12345678, authenticated (on the data connection)",
                             signed(0x000B, [(0x002A, struct.pack(">I", 0x12345678))])),
    "connect_auth": ("RFC 6062 Connect XOR-PEER-ADDRESS 198.51.100.20:2223, authenticated (Swift never sends it)",
                     signed(0x000A, [(0x0012, xaddr("198.51.100.20", 2223))])),
    "connection_attempt": ("ConnectionAttempt indication: CONNECTION-ID 0x12345678, XOR-PEER 198.51.100.20:61001",
                           msg(0x001C, [(0x002A, struct.pack(">I", 0x12345678)), (0x0012, xaddr("198.51.100.20", 61001))])),
    "binding_request_fingerprint": ("Binding request + FINGERPRINT (helper only; Swift emits none)",
                                    with_fp(msg(0x0001, []))),
    "refresh_auth_fingerprint": ("Authenticated Refresh + FINGERPRINT after MESSAGE-INTEGRITY",
                                 with_fp(signed(0x0004, []))),
}

for name, (comment, raw) in FIXTURES.items():
    with open(os.path.join(HERE, name + ".hex"), "w", newline="\n") as f:
        f.write(f"# {comment}\n# generated by gen_fixtures.py (txid 01..0c; user {USER}, realm {REALM}, nonce {NONCE})\n")
        h = raw.hex()
        for i in range(0, len(h), 40):
            f.write(h[i:i+40] + "\n")
with open(os.path.join(HERE, "longterm_key.hex"), "w", newline="\n") as f:
    f.write(f"# MD5(\"{USER}:{REALM}:{PASS}\")\n{key().hex()}\n")
