#!/usr/bin/python3 -u
"""Host-only absolute pointer bridge for the custom GPU, on vsock 5821.

Each newline-terminated JSON object is a complete {x, y, buttons} snapshot.
Coordinates are finite numbers clamped to [0, 1], relative to the FULL X screen
with a top-left origin, including any chrome inset hidden by the host. Buttons
are an integer bitmask: left=1, right=2, middle=4. No keyboard or wheel events.
Malformed/oversized messages close the connection and release held buttons.
The legacy VZ pointer remains available; only custom-GPU hosts use this agent.
"""

import fcntl
import json
import math
import os
import socket
import struct
import subprocess
import sys


VSOCK_PORT = 5821
MAX_MESSAGE_BYTES = 1024  # Excluding the terminating newline.
ABS_MAX = 65535
DEVICE_NAME = b"Bromure Absolute Pointer"
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_ABSBIT = 0x40045567
UI_SET_PROPBIT = 0x4004556E
UI_DEV_SETUP = 0x405C5503
UI_ABS_SETUP = 0x401C5504
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
ABS_X, ABS_Y = 0, 1
BUTTON_CODES = (0x110, 0x111, 0x112)
INPUT_PROP_POINTER = 0
BUS_VIRTUAL = 6
EVENT = struct.Struct("<qqHHi")  # Linux input_event on arm64/x86_64.


def log(message):
    print("pointer-agent: " + message, file=sys.stderr, flush=True)


def create_uinput_device():
    subprocess.run(["modprobe", "uinput"], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_CLOEXEC)
    try:
        for event_type in (EV_SYN, EV_KEY, EV_ABS):
            fcntl.ioctl(fd, UI_SET_EVBIT, event_type)
        fcntl.ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_POINTER)
        for code in BUTTON_CODES:
            fcntl.ioctl(fd, UI_SET_KEYBIT, code)
        for code in (ABS_X, ABS_Y):
            fcntl.ioctl(fd, UI_SET_ABSBIT, code)
            # uinput_abs_setup: u16 code + padding + six signed input_absinfo.
            fcntl.ioctl(fd, UI_ABS_SETUP,
                        struct.pack("<H2xiiiiii", code, 0, 0, ABS_MAX, 0, 0, 0))
        fcntl.ioctl(fd, UI_DEV_SETUP,
                    struct.pack("<HHHH80sI", BUS_VIRTUAL, 0x1D6B, 0x0106, 1,
                                DEVICE_NAME, 0))
        fcntl.ioctl(fd, UI_DEV_CREATE)
        return fd
    except BaseException:
        os.close(fd)
        raise


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON field")
        result[key] = value
    return result


def parse_snapshot(line):
    if len(line) > MAX_MESSAGE_BYTES:
        raise ValueError("Pointer message too large")
    message = json.loads(line, object_pairs_hook=unique_object)
    if not isinstance(message, dict) or set(message) != {"x", "y", "buttons"}:
        raise ValueError("Expected x, y and buttons")
    buttons = message["buttons"]
    if type(buttons) is not int or not 0 <= buttons <= 7:
        raise ValueError("Invalid pointer buttons")
    position = []
    for axis in ("x", "y"):
        value = message[axis]
        if type(value) not in (int, float):
            raise ValueError("Invalid pointer coordinate")
        try:
            value = float(value)
        except OverflowError as error:
            raise ValueError("Invalid pointer coordinate") from error
        if not math.isfinite(value):
            raise ValueError("Nonfinite pointer coordinate")
        position.append(round(max(0.0, min(1.0, value)) * ABS_MAX))
    return position[0], position[1], buttons


class Pointer:
    def __init__(self, fd):
        self.fd = fd
        self.buttons = 0

    def emit(self, events):
        data = b"".join(EVENT.pack(0, 0, kind, code, value)
                        for kind, code, value in events)
        if os.write(self.fd, data) != len(data):
            raise OSError("Short uinput write")

    def update(self, x, y, buttons):
        events = [(EV_ABS, ABS_X, x), (EV_ABS, ABS_Y, y)]
        for bit, code in enumerate(BUTTON_CODES):
            if (self.buttons ^ buttons) & (1 << bit):
                events.append((EV_KEY, code, int(bool(buttons & (1 << bit)))))
        # Set state before write so cleanup attempts release even after failure.
        self.buttons = buttons
        self.emit([*events, (EV_SYN, 0, 0)])

    def release(self):
        if self.buttons:
            # Release every permitted button, with no cursor jump.
            events = [(EV_KEY, code, 0) for code in BUTTON_CODES]
            self.emit([*events, (EV_SYN, 0, 0)])
            self.buttons = 0


def handle_connection(connection, pointer):
    pending = bytearray()
    try:
        while True:
            chunk = connection.recv(MAX_MESSAGE_BYTES + 1)
            if not chunk:
                return
            pending.extend(chunk)
            while b"\n" in pending:
                line, _, remainder = pending.partition(b"\n")
                pending = bytearray(remainder)
                pointer.update(*parse_snapshot(line))
            if len(pending) > MAX_MESSAGE_BYTES:
                raise ValueError("Pointer message too large")
    finally:
        pointer.release()


def serve(pointer):
    with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as server:
        server.bind((socket.VMADDR_CID_ANY, VSOCK_PORT))
        server.listen(1)
        log("listening on vsock :5821")
        while True:
            connection, address = server.accept()
            with connection:
                if address[0] != socket.VMADDR_CID_HOST:
                    continue
                try:
                    handle_connection(connection, pointer)
                except (ValueError, UnicodeError, RecursionError) as error:
                    log("invalid pointer stream: " + type(error).__name__)
                except (ConnectionError, TimeoutError):
                    log("host disconnected")


def main():
    fd = create_uinput_device()
    pointer = Pointer(fd)
    try:
        serve(pointer)
    finally:
        try:
            pointer.release()
        finally:
            try:
                fcntl.ioctl(fd, UI_DEV_DESTROY)
            finally:
                os.close(fd)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
