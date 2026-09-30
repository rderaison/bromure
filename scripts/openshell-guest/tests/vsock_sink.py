#!/usr/bin/env python3
"""A stand-in for the host's 5841 listener, for testing inside the guest.

The real host listens on CID 2, which only the macOS side can bind. This binds
VMADDR_CID_ANY so the guest can point the module at VMADDR_CID_LOCAL (1) and
exercise the identical code path — same `sock_create_kern`, same framing, same
hello — without a host.

It also does the checks the host does, so a framing or sequencing bug shows up
here rather than on the other side of the delegation:
  * u32 big-endian length prefix, then that many bytes of JSON;
  * the first frame is a hello with a 64-hex secret;
  * `seq` is one counter shared by heartbeats and events, strictly increasing
    with no gaps;
  * heartbeats arrive at least every 5s and carry the drop counters.

Usage: vsock_sink.py [--port N] [--seconds N] [--json-out PATH]
"""
import argparse
import json
import socket
import struct
import sys
import time

VMADDR_CID_ANY = 0xFFFFFFFF


def read_exactly(conn, count):
    buf = b""
    while len(buf) < count:
        chunk = conn.recv(count - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=5841)
    parser.add_argument("--seconds", type=float, default=10.0)
    parser.add_argument("--json-out")
    args = parser.parse_args()

    listener = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((VMADDR_CID_ANY, args.port))
    listener.listen(4)
    listener.settimeout(args.seconds)
    print("listening on vsock port %d" % args.port, flush=True)

    try:
        conn, peer = listener.accept()
    except socket.timeout:
        print("FAIL: nothing connected within %.1fs" % args.seconds)
        return 1
    print("connection from cid %s port %s" % peer, flush=True)

    frames = []
    problems = []
    deadline = time.time() + args.seconds
    expected_seq = None
    last_heartbeat = None

    while time.time() < deadline:
        conn.settimeout(max(0.1, deadline - time.time()))
        try:
            header = read_exactly(conn, 4)
        except socket.timeout:
            break
        if header is None:
            problems.append("peer closed the channel")
            break
        (length,) = struct.unpack(">I", header)
        if length == 0 or length > 1 << 20:
            problems.append("implausible frame length %d" % length)
            break
        body = read_exactly(conn, length)
        if body is None:
            problems.append("truncated frame body")
            break
        try:
            frame = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            problems.append("frame %d is not valid UTF-8 JSON: %s" % (len(frames), exc))
            break
        frames.append(frame)

        kind = frame.get("type")
        if len(frames) == 1:
            if kind != "hello":
                problems.append("first frame is %r, not hello" % kind)
            secret = frame.get("secret", "")
            if len(secret) != 64 or any(c not in "0123456789abcdef" for c in secret):
                problems.append("hello secret is not 64 lowercase hex: %r" % secret)
            if frame.get("conn") != 0:
                problems.append("the first hello is conn %r, expected 0"
                                % frame.get("conn"))
            for key in ("v", "boot_id", "kernel", "module"):
                if key not in frame:
                    problems.append("hello is missing %r" % key)
        else:
            seq = frame.get("seq")
            if seq is None:
                problems.append("frame %d has no seq" % len(frames))
            elif expected_seq is not None and seq != expected_seq:
                problems.append("seq gap: expected %d, got %d" % (expected_seq, seq))
            if seq is not None:
                expected_seq = seq + 1
        if kind == "heartbeat":
            now = time.time()
            if last_heartbeat is not None and now - last_heartbeat > 5.0:
                problems.append("heartbeat gap of %.1fs" % (now - last_heartbeat))
            last_heartbeat = now
            for key in ("dropped", "rate_limited"):
                if key not in frame:
                    problems.append("heartbeat is missing %r" % key)

    conn.close()
    listener.close()

    kinds = {}
    for frame in frames:
        key = frame.get("kind") if frame.get("type") == "event" else frame.get("type")
        kinds[key] = kinds.get(key, 0) + 1

    print("\n%d frames: %s" % (len(frames), json.dumps(kinds, sort_keys=True)))
    if frames:
        print("hello: %s" % json.dumps(frames[0]))
        for frame in frames[1:]:
            if frame.get("type") == "event":
                print("first event: %s" % json.dumps(frame))
                break
        for frame in reversed(frames):
            if frame.get("type") == "heartbeat":
                print("last heartbeat: %s" % json.dumps(frame))
                break
    if args.json_out:
        with open(args.json_out, "w") as handle:
            json.dump(frames, handle)

    if problems:
        print("\nPROBLEMS:")
        for problem in problems:
            print("  " + problem)
        return 1
    print("\nOK: framing, hello, seq continuity and heartbeats all check out")
    return 0


if __name__ == "__main__":
    sys.exit(main())
