#!/usr/bin/env python3
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
import subprocess
import sys
import time

VSOCK_PORT = 5100
HOST_CID = 2  # Apple Virtualization.framework host CID
DOWNLOAD_DIR = os.path.expanduser("~/Downloads")
CONSOLE = None  # /dev/hvc0 for debug logging


def log(msg):
    """Write debug message to VM console."""
    global CONSOLE
    if CONSOLE is None:
        try:
            CONSOLE = open("/dev/hvc0", "w")
        except Exception:
            CONSOLE = False
    if CONSOLE:
        try:
            CONSOLE.write(f"[file-agent] {msg}\n")
            CONSOLE.flush()
        except Exception:
            pass


def send_json(sock, obj):
    """Send a JSON object as a newline-terminated string."""
    line = json.dumps(obj, separators=(",", ":")) + "\n"
    data = line.encode("utf-8")
    sock.sendall(data)


def send_file(sock, filepath):
    """Send a file to the host."""
    filename = os.path.basename(filepath)
    try:
        with open(filepath, "rb") as f:
            raw = f.read()
        b64 = base64.b64encode(raw).decode("ascii")
        send_json(sock, {
            "type": "file_download",
            "filename": filename,
            "size": len(raw),
            "data": b64,
        })
    except Exception as e:
        log(f"send error: {e}")


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
        log(f"invalid JSON: {line[:100]}")
        return

    msg_type = msg.get("type", "")

    if msg_type == "file_upload":
        filename = msg.get("filename", "unknown")
        b64_data = msg.get("data", "")
        if b64_data:
            try:
                raw = base64.b64decode(b64_data)
                dest = os.path.join(DOWNLOAD_DIR, filename)
                with open(dest, "wb") as f:
                    f.write(raw)
            except Exception as e:
                log(f"upload error: {e}")

    elif msg_type == "file_list":
        send_file_list(sock)


def start_watcher():
    """Start inotifywait to watch ~/Downloads for new files.

    Returns the subprocess Popen object, or None if inotifywait is unavailable.
    """
    try:
        proc = subprocess.Popen(
            ["inotifywait", "-m", "-e", "close_write", "-e", "moved_to",
             "--format", "%f", DOWNLOAD_DIR],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        return proc
    except FileNotFoundError:
        log("inotifywait not found, watcher disabled")
        return None


def run(sock):
    """Main loop: multiplex between vsock input and inotifywait output."""
    watcher = start_watcher()
    sock_buf = b""
    watch_buf = b""

    # Use raw fd for the watcher to avoid buffered I/O mismatch with select()
    sock_fd = sock.fileno()
    watch_fd = watcher.stdout.fileno() if watcher else -1

    # Set watcher stdout to non-buffered raw mode
    if watcher:
        os.set_blocking(watch_fd, False)

    poll_fds = [sock_fd]
    if watch_fd >= 0:
        poll_fds.append(watch_fd)

    try:
        while True:
            readable, _, _ = select.select(poll_fds, [], [], 5.0)

            for fd in readable:
                if fd == sock_fd:
                    # Data from host
                    chunk = sock.recv(1048576)  # 1MB
                    if not chunk:
                        return
                    sock_buf += chunk

                    # Process complete lines
                    while b"\n" in sock_buf:
                        line, sock_buf = sock_buf.split(b"\n", 1)
                        if line:
                            process_message(sock, line.decode("utf-8", errors="replace"))

                elif fd == watch_fd:
                    try:
                        chunk = os.read(watch_fd, 65536)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        poll_fds.remove(watch_fd)
                        watch_fd = -1
                        watcher = None
                        continue
                    watch_buf += chunk

                    # Process complete lines (filenames)
                    while b"\n" in watch_buf:
                        line, watch_buf = watch_buf.split(b"\n", 1)
                        filename = line.decode("utf-8", errors="replace").strip()
                        if not filename:
                            continue
                        filepath = os.path.join(DOWNLOAD_DIR, filename)
                        if os.path.isfile(filepath):
                            time.sleep(0.5)  # let file finish writing
                            send_file(sock, filepath)
    finally:
        if watcher:
            watcher.terminate()
            watcher.wait()


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
