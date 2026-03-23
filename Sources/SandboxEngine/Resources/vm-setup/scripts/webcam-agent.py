#!/usr/bin/env python3
"""
webcam-agent.py — On-demand virtual webcam bridge.

Probes the host at startup to learn the camera resolution, then configures
v4l2loopback to match. Only activates the real camera when Chrome opens
/dev/video0 for reading.

Protocol (binary, over vsock port 5400):
  1. 12-byte header from host: width(u32le) + height(u32le) + fps(u32le)
  2. Repeated frames from host: size(u32le) + raw YUYV pixel data
"""

import fcntl
import glob
import os
import socket
import struct
import sys
import time
import traceback

VSOCK_PORT = 5400
VIDEO_DEV = "/dev/video0"

# v4l2 ioctl constants
VIDIOC_S_FMT = 0xC0D05605
V4L2_BUF_TYPE_VIDEO_OUTPUT = 2
V4L2_PIX_FMT_YUYV = 0x56595559
V4L2_FIELD_NONE = 1


def set_v4l2_format(fd, width, height):
    """Set the v4l2loopback device format to YUYV."""
    # struct v4l2_format is 208 bytes on 64-bit:
    #   offset 0: __u32 type
    #   offset 4: 4 bytes padding (union aligned to 8 on 64-bit due to pointers)
    #   offset 8: union fmt — struct v4l2_pix_format starts here
    fmt = bytearray(208)
    image_size = width * height * 2
    PIX = 8  # pix_format offset within v4l2_format on 64-bit
    struct.pack_into("<I", fmt, 0, V4L2_BUF_TYPE_VIDEO_OUTPUT)
    struct.pack_into("<I", fmt, PIX + 0, width)
    struct.pack_into("<I", fmt, PIX + 4, height)
    struct.pack_into("<I", fmt, PIX + 8, V4L2_PIX_FMT_YUYV)
    struct.pack_into("<I", fmt, PIX + 12, V4L2_FIELD_NONE)
    struct.pack_into("<I", fmt, PIX + 16, width * 2)      # bytesperline
    struct.pack_into("<I", fmt, PIX + 20, image_size)      # sizeimage
    fcntl.ioctl(fd, VIDIOC_S_FMT, fmt)


def read_exact(sock, n):
    """Read exactly n bytes from socket."""
    buf = bytearray(n)
    pos = 0
    while pos < n:
        chunk = sock.recv(n - pos)
        if not chunk:
            return None
        buf[pos:pos + len(chunk)] = chunk
        pos += len(chunk)
    return bytes(buf)


def has_readers(my_pid):
    """Check if any other process has /dev/video0 open."""
    for fd_dir in glob.glob("/proc/[0-9]*/fd"):
        pid = fd_dir.split("/")[2]
        if pid == my_pid:
            continue
        try:
            for fd_link in os.listdir(fd_dir):
                target = os.readlink(os.path.join(fd_dir, fd_link))
                if target == VIDEO_DEV:
                    return True
        except (OSError, PermissionError):
            continue
    return False


def log(msg):
    print(f"[webcam-agent] {msg}", file=sys.stderr, flush=True)


def stream_frames(sock, vfd, width, height):
    """Read frames from host vsock and write to v4l2loopback."""
    frame_size = width * height * 2

    while True:
        size_data = read_exact(sock, 4)
        if not size_data:
            break
        sz = struct.unpack("<I", size_data)[0]
        if sz != frame_size:
            log(f"unexpected frame size {sz}, expected {frame_size}")
            read_exact(sock, sz)
            continue

        frame = read_exact(sock, sz)
        if not frame:
            break

        os.write(vfd, frame)


def read_chrome_env(key, default=""):
    """Read a value from /tmp/bromure/chrome-env."""
    try:
        with open("/tmp/bromure/chrome-env") as f:
            for line in f:
                if line.startswith(key + "="):
                    return line.split("=", 1)[1].strip()
    except Exception:
        pass
    return default


def main():
    import signal
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    my_pid = str(os.getpid())

    # Wait for /dev/video0 (created by config-agent when webcam is enabled).
    # The device won't exist until a session is claimed and config-agent loads
    # v4l2loopback, so use a long sleep to avoid burning CPU in pre-warmed VMs.
    log("waiting for " + VIDEO_DEV)
    while not os.path.exists(VIDEO_DEV):
        time.sleep(5)

    # Read camera resolution from chrome-env (written by config-agent)
    width = int(read_chrome_env("WEBCAM_WIDTH", "640"))
    height = int(read_chrome_env("WEBCAM_HEIGHT", "480"))
    log(f"host camera: {width}x{height}")

    # Open the device and set format to match host camera
    vfd = os.open(VIDEO_DEV, os.O_WRONLY)
    try:
        set_v4l2_format(vfd, width, height)
        # Write a blank frame so v4l2loopback sets ready_for_capture=1
        # and advertises VIDEO_CAPTURE to readers (e.g. Chrome).
        os.write(vfd, b'\x80\x10' * (width * height))
        log(f"format set on {VIDEO_DEV}: {width}x{height} YUYV")
    except Exception:
        log("failed to set format:\n" + traceback.format_exc())
        os.close(vfd)
        return

    try:
        # Main loop: wait for readers, then stream
        while True:
            if not has_readers(my_pid):
                time.sleep(2)
                continue

            log("reader detected, connecting to host")
            sock = None
            try:
                sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
                sock.settimeout(10)
                sock.connect((2, VSOCK_PORT))
                sock.settimeout(None)  # back to blocking for streaming

                # Read 12-byte header (resolution should match chrome-env)
                header = read_exact(sock, 12)
                if not header:
                    log("no header received")
                    continue

                w, h, f = struct.unpack("<III", header)
                log(f"streaming: {w}x{h} YUYV @ {f}fps")

                if w != width or h != height:
                    log(f"warning: stream {w}x{h} != device {width}x{height}, restart VM to fix")

                stream_frames(sock, vfd, w, h)

            except Exception:
                log("error:\n" + traceback.format_exc())
            finally:
                if sock:
                    try:
                        sock.close()
                    except OSError:
                        pass
                log("disconnected from host")

            time.sleep(1)
    finally:
        os.close(vfd)


if __name__ == "__main__":
    main()
