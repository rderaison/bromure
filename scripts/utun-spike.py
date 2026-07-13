#!/usr/bin/env python3
"""Phase-4 networking spike (run with sudo) — REMOTE_FAT_CLIENT_PLAN.md spike #1.

Validates the one unproven assumption behind the system-wide `utun` path BEFORE
building the privileged helper + forwarder: does a host `utun` interface with a
route for a /24 actually receive packets sent to that subnet?

    sudo python3 scripts/utun-spike.py

It opens a utun, assigns it 10.99.99.1/24, routes 192.168.222.0/24 → the utun,
then connects to 192.168.222.5:9999 and confirms the SYN packet arrives on the
utun fd (printing the raw IP header). If it prints "GOT PACKET ... dst=192.168.222.5"
the utun+route mechanism works and the forwarder can be built on it; if nothing
arrives, the vmnet-NAT→host-route→utun path is a dead end and the SOCKS/PAC
approach (already implemented) stays the only browser path.

Pure stdlib; creates/tears down the utun + route itself. utun creation needs
root (SYSPROTO_CONTROL), hence sudo.
"""
import ctypes, os, socket, struct, subprocess, sys, threading, time

AF_SYS_CONTROL = 2
SYSPROTO_CONTROL = 2
UTUN_CONTROL_NAME = b"com.apple.net.utun_control"
CTLIOCGINFO = 0xC0644E03            # _IOWR('N', 3, struct ctl_info)
UTUN_OPT_IFNAME = 2
SYSPROTO_CONTROL_LEVEL = SYSPROTO_CONTROL

TEST_SUBNET = "192.168.222.0/24"
TEST_DST = "192.168.222.5"
UTUN_ADDR = "10.99.99.1"
UTUN_PEER = "10.99.99.2"


def open_utun():
    s = socket.socket(socket.PF_SYSTEM, socket.SOCK_DGRAM, SYSPROTO_CONTROL)
    # struct ctl_info { u_int32_t ctl_id; char ctl_name[96]; }
    info = struct.pack("I96s", 0, UTUN_CONTROL_NAME)
    buf = ctypes.create_string_buffer(info, 100)
    import fcntl
    fcntl.ioctl(s, CTLIOCGINFO, buf)
    ctl_id = struct.unpack("I96s", buf.raw)[0]
    # Python's PF_SYSTEM socket takes a (ctl_id, unit) pair; unit 0 = pick a free
    # utun. (It does the sockaddr_ctl packing internally.)
    s.connect((ctl_id, 0))
    ifname = s.getsockopt(SYSPROTO_CONTROL_LEVEL, UTUN_OPT_IFNAME, 256).split(b"\x00")[0].decode()
    return s, ifname


def main():
    if os.geteuid() != 0:
        sys.exit("must run as root:  sudo python3 scripts/utun-spike.py")
    s, ifname = open_utun()
    print(f"[spike] opened {ifname}")
    try:
        subprocess.run(["ifconfig", ifname, UTUN_ADDR, UTUN_PEER, "up"], check=True)
        subprocess.run(["route", "-n", "add", "-net", TEST_SUBNET, "-interface", ifname], check=True)
        print(f"[spike] {ifname} = {UTUN_ADDR}, route {TEST_SUBNET} → {ifname}")

        got = threading.Event()

        def reader():
            while not got.is_set():
                try:
                    pkt = s.recv(2048)
                except OSError:
                    return
                # utun frames are prefixed with a 4-byte AF header
                ip = pkt[4:]
                if len(ip) >= 20 and (ip[0] >> 4) == 4:
                    dst = ".".join(str(b) for b in ip[16:20])
                    proto = ip[9]
                    print(f"[spike] GOT PACKET on {ifname}: proto={proto} dst={dst} ({len(ip)}B)")
                    if dst == TEST_DST:
                        got.set()
                        return

        t = threading.Thread(target=reader, daemon=True)
        t.start()

        # Fire a connection at the routed subnet; the SYN should land on the utun.
        c = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        c.settimeout(2)
        try:
            c.connect((TEST_DST, 9999))
        except OSError:
            pass
        c.close()

        if got.wait(timeout=3):
            print("\n[spike] RESULT: PASS — host utun route catches the subnet. "
                  "The utun forwarder is viable.")
        else:
            print("\n[spike] RESULT: FAIL — no packet reached the utun. "
                  "Keep the SOCKS/PAC browser path (already implemented); "
                  "system-wide utun needs a different approach.")
    finally:
        subprocess.run(["route", "-n", "delete", "-net", TEST_SUBNET], capture_output=True)
        s.close()
        print(f"[spike] cleaned up {ifname}")


if __name__ == "__main__":
    main()
