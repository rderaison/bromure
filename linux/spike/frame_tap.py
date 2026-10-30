#!/usr/bin/python3
"""Userspace L2 endpoint for QEMU `-netdev stream,server=off,addr.type=unix`.
Listens on a unix socket; QEMU connects. Each frame = 4-byte big-endian length + Ethernet frame.
Logs every frame; flags DHCP and cross-checks the length prefix against the IPv4 total-length."""
import socket, struct, sys, os, time
path = sys.argv[1]
if os.path.exists(path): os.unlink(path)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); srv.bind(path); srv.listen(1)
log = open(sys.argv[2] if len(sys.argv) > 2 else "/dev/stdout", "a", buffering=1)
def rd(c, n):
    b = b""
    while len(b) < n:
        x = c.recv(n - len(b))
        if not x: raise EOFError
        b += x
    return b
while True:
    c, _ = srv.accept(); log.write(f"{time.time():.3f} qemu connected\n")
    try:
        while True:
            hdr = rd(c, 4); (n,) = struct.unpack("!I", hdr); f = rd(c, n)
            dst, src, et = f[0:6].hex(":"), f[6:12].hex(":"), struct.unpack("!H", f[12:14])[0]
            info = f"len={n} hdr={hdr.hex()} {src}->{dst} type=0x{et:04x}"
            if et == 0x0800:
                tot = struct.unpack("!H", f[16:18])[0]; proto = f[23]; ihl = (f[14] & 0xF) * 4
                info += f" ipv4 proto={proto} 14+ip_total={14+tot}{' (pad)' if 14+tot!=n else ' MATCH'}"
                if proto == 17:
                    sp, dp = struct.unpack("!HH", f[14+ihl:18+ihl])
                    info += f" udp {sp}->{dp}"
                    if (sp, dp) == (68, 67):
                        opts = f[14+ihl+8+240:]; mt = None; i = 0
                        while i < len(opts) and opts[i] != 255:
                            if opts[i] == 0: i += 1; continue
                            if opts[i] == 53: mt = opts[i+2]
                            i += 2 + opts[i+1]
                        info += f" DHCP msgtype={ {1:'DISCOVER',3:'REQUEST'}.get(mt, mt) } chaddr={f[14+ihl+8+28:14+ihl+8+34].hex(':')}"
            elif et == 0x86dd:
                info += f" ipv6 payload+54={54+struct.unpack('!H', f[18:20])[0]}"
            log.write(f"{time.time():.3f} {info}\n")
    except EOFError:
        log.write(f"{time.time():.3f} qemu disconnected\n")
