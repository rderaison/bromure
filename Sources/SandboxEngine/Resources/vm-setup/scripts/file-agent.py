#!/usr/bin/python3 -u
"""Bromure file transfer agent — runs inside the guest VM.

Connects to the host over vsock and transfers files bidirectionally.
Watches ~/Downloads for new/changed files and sends them to the host.
Receives files from the host and writes them to ~/Downloads.

Protocol: newline-delimited JSON.
JSON fields: type, filename, size, data (base64), files (for listings).

Started from xinitrc when FILE_TRANSFER=1 env var is set.
"""

import base64
import json
import os
import select
import signal
import socket
import sys
import time

VSOCK_PORT = 5100
HOST_CID = 2  # Apple Virtualization.framework host CID
DOWNLOAD_DIR = os.path.expanduser("~/Downloads")


def send_json(sock, obj):
    """Send a JSON object as a newline-terminated string."""
    line = json.dumps(obj, separators=(",", ":")) + "\n"
    data = line.encode("utf-8")
    sock.sendall(data)


CHUNK_SIZE = 512 * 1024  # 512 KB raw → ~700 KB base64

def send_file(sock, filepath):
    """Send a file to the host in chunks."""
    filename = os.path.basename(filepath)
    try:
        file_size = os.path.getsize(filepath)

        # Small files (< 1 MB): send in one shot for simplicity
        if file_size < 1_048_576:
            with open(filepath, "rb") as f:
                raw = f.read()
            b64 = base64.b64encode(raw).decode("ascii")
            send_json(sock, {
                "type": "file_download",
                "filename": filename,
                "size": len(raw),
                "data": b64,
            })
            return

        # Large files: chunked transfer
        send_json(sock, {
            "type": "file_start",
            "filename": filename,
            "size": file_size,
        })

        with open(filepath, "rb") as f:
            seq = 0
            while True:
                chunk = f.read(CHUNK_SIZE)
                if not chunk:
                    break
                b64 = base64.b64encode(chunk).decode("ascii")
                send_json(sock, {
                    "type": "file_chunk",
                    "seq": seq,
                    "data": b64,
                })
                seq += 1

        send_json(sock, {
            "type": "file_end",
            "filename": filename,
            "chunks": seq,
        })
    except Exception:
        pass


def send_file_list(sock):
    """Send a listing of ~/Downloads to the host."""
    try:
        files = os.listdir(DOWNLOAD_DIR)
    except Exception:
        files = []
    send_json(sock, {
        "type": "file_list_response",
        "files": sorted(files),
    })


def process_message(sock, line):
    """Process a JSON message received from the host."""
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        return

    msg_type = msg.get("type", "")

    if msg_type == "file_upload":
        filename = msg.get("filename", "unknown")
        b64_data = msg.get("data", "")
        if b64_data:
            try:
                raw = base64.b64decode(b64_data)
                # Save to /home/chrome/ (not ~/Downloads) to avoid
                # the inotify watch echoing the file back to the host.
                dest = os.path.join("/home/chrome", filename)
                with open(dest, "wb") as f:
                    f.write(raw)
            except Exception:
                pass

    elif msg_type == "file_list":
        send_file_list(sock)


def run(sock):
    """Main loop: poll ~/Downloads for new files + handle host messages."""
    sock_buf = b""
    known_files = set()

    # Snapshot existing files so we only transfer new ones
    try:
        known_files = set(os.listdir(DOWNLOAD_DIR))
    except OSError:
        pass
    # known_files snapshot taken — only new files will be transferred

    sock_fd = sock.fileno()

    try:
        while True:
            # Wait up to 1s for host messages, then check for new files
            readable, _, _ = select.select([sock_fd], [], [], 1.0)

            if readable:
                chunk = sock.recv(1048576)  # 1MB
                if not chunk:
                    return
                sock_buf += chunk

                while b"\n" in sock_buf:
                    line, sock_buf = sock_buf.split(b"\n", 1)
                    if line:
                        process_message(sock, line.decode("utf-8", errors="replace"))

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
        pass


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
            run(sock)
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
