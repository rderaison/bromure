#!/usr/bin/python3 -u
"""Bromure file transfer agent — runs inside the guest VM.

Connects to the host over vsock and transfers files bidirectionally.
Watches ~/Downloads for new/changed files and sends them to the host.
Receives files from the host and writes them to ~/Downloads.

Binary protocol (length-prefixed frames):

  Each frame: [type: u8] [reserved: 7 bytes] [length: u64be] [payload: length bytes]

  Type 0x01 — FILE_META:  filename(UTF-8) + NUL + filesize(u64be)
  Type 0x02 — FILE_DATA:  raw binary chunk
  Type 0x03 — FILE_END:   empty payload (marks end of file)
  Type 0x04 — LIST_REQ:   empty payload (host → guest)
  Type 0x05 — LIST_RESP:  NUL-separated filenames (guest → host)

Started at boot via inittab. Killed by config-agent if file transfer is disabled.
"""

import os
import select
import signal
import socket
import struct
import sys
import time

VSOCK_PORT = 5100
HOST_CID = 2  # Apple Virtualization.framework host CID
DOWNLOAD_DIR = "/home/chrome/Downloads"

HEADER_SIZE = 16  # 1 byte type + 7 reserved + 8 bytes length
CHUNK_SIZE = 1024 * 1024  # 1 MB raw chunks

# Frame types
TYPE_META = 0x01
TYPE_DATA = 0x02
TYPE_END = 0x03
TYPE_LIST_REQ = 0x04
TYPE_LIST_RESP = 0x05


def send_frame(sock, frame_type, payload=b""):
    """Send a single binary frame: [type:u8][reserved:7][length:u64be][payload]."""
    header = struct.pack(">B7xQ", frame_type, len(payload))
    sock.sendall(header + payload)


def recv_exact(sock, n):
    """Receive exactly n bytes from the socket."""
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("connection closed")
        buf.extend(chunk)
    return bytes(buf)


def send_file(sock, filepath):
    """Send a file to the host using binary frames."""
    filename = os.path.basename(filepath)
    try:
        file_size = os.path.getsize(filepath)

        # FILE_META: filename(UTF-8) + NUL + filesize(u64be)
        meta = filename.encode("utf-8") + b"\x00" + struct.pack(">Q", file_size)
        send_frame(sock, TYPE_META, meta)

        # FILE_DATA chunks
        with open(filepath, "rb") as f:
            while True:
                chunk = f.read(CHUNK_SIZE)
                if not chunk:
                    break
                send_frame(sock, TYPE_DATA, chunk)

        # FILE_END
        send_frame(sock, TYPE_END)
    except Exception:
        pass


def send_file_list(sock):
    """Send a listing of ~/Downloads to the host."""
    try:
        files = sorted(os.listdir(DOWNLOAD_DIR))
    except Exception:
        files = []
    payload = b"\x00".join(f.encode("utf-8") for f in files)
    send_frame(sock, TYPE_LIST_RESP, payload)


def process_frames(sock, buf):
    """Process complete frames from buffer. Returns remaining bytes."""
    while len(buf) >= HEADER_SIZE:
        frame_type = buf[0]
        # Bytes 1..7 are reserved (skip them)
        payload_len = struct.unpack(">Q", buf[8:16])[0]
        total = HEADER_SIZE + payload_len
        if len(buf) < total:
            break

        payload = buf[HEADER_SIZE:total]
        buf = buf[total:]

        handle_frame(sock, frame_type, payload)

    return buf


# Receive state for incoming file transfers from host
rx_filename = None
rx_file = None


def handle_frame(sock, frame_type, payload):
    """Handle a single received frame."""
    global rx_filename, rx_file

    if frame_type == TYPE_META:
        # Parse: filename(UTF-8) + NUL + filesize(u64be)
        nul = payload.index(0)
        filename = payload[:nul].decode("utf-8")
        # Save to /home/chrome/ (not ~/Downloads) to avoid inotify echo
        dest = os.path.join("/home/chrome", filename)
        rx_filename = filename
        rx_file = open(dest, "wb")

    elif frame_type == TYPE_DATA:
        if rx_file is not None:
            rx_file.write(payload)

    elif frame_type == TYPE_END:
        if rx_file is not None:
            rx_file.close()
            rx_file = None
            rx_filename = None

    elif frame_type == TYPE_LIST_REQ:
        send_file_list(sock)


def run(sock):
    """Main loop: poll ~/Downloads for new files + handle host messages.

    Returns True if data was exchanged (reconnect on disconnect),
    False if host closed immediately (feature disabled, exit).
    """
    global rx_filename, rx_file
    rx_filename = None
    rx_file = None

    buf = b""
    known_files = set()
    got_data = False

    # Snapshot existing files so we only transfer new ones
    try:
        known_files = set(os.listdir(DOWNLOAD_DIR))
    except OSError:
        pass

    sock_fd = sock.fileno()

    try:
        while True:
            # Wait up to 1s for host messages, then check for new files
            readable, _, _ = select.select([sock_fd], [], [], 1.0)

            if readable:
                chunk = sock.recv(1048576)  # 1 MB
                if not chunk:
                    return got_data
                got_data = True
                buf += chunk
                buf = process_frames(sock, buf)

            # Poll for new files in ~/Downloads
            try:
                current = set(os.listdir(DOWNLOAD_DIR))
            except OSError:
                continue

            new_files = current - known_files
            known_files = current

            for filename in sorted(new_files):
                # Skip Chromium temp download files
                if filename.endswith(".crdownload"):
                    continue
                filepath = os.path.join(DOWNLOAD_DIR, filename)
                if os.path.isfile(filepath):
                    time.sleep(0.5)  # let file finish writing
                    send_file(sock, filepath)
    finally:
        if rx_file is not None:
            rx_file.close()
            rx_file = None


def main():
    os.makedirs(DOWNLOAD_DIR, exist_ok=True)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

    while True:
        try:
            sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1048576)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1048576)
            sock.connect((HOST_CID, VSOCK_PORT))
            had_data = run(sock)
            if not had_data:
                # Host closed immediately — feature disabled, exit cleanly
                sock.close()
                return
        except (ConnectionError, OSError):
            pass
        finally:
            try:
                sock.close()
            except Exception:
                pass
        time.sleep(3)


if __name__ == "__main__":
    main()
