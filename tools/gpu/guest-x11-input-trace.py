#!/usr/bin/env python3
"""Passive, bounded input/resize diagnostic; never installed as a guest service.

Run as the desktop user:
  DISPLAY=:0 python3 guest-x11-input-trace.py --seconds 300 > /tmp/x11-input.jsonl

Requires libX11, libXi, libXrandr and libXtst (RECORD). No Python dependencies.
RECORD captures core device button coordinates before delivery, even when Chrome
selects XI2 events instead of core events. The same RECORD stream captures only
THIS observer's root Configure/RandR events and initial geometry reply. Thus
ordinal is server observation order, not a merge of two read queues. XI2 raw
buttons are supplementary on a separate stream (xi_ordinal); they carry no
coordinates and MUST NOT be used to order geometry against core buttons.
No grabs, focus changes, pointer queries, window creation or browser access.

root_x/y and root_width/height are X root pixels, NOT CSS pixels or host points.
Root dimensions are the latest preceding root Configure event (initially the
recorded GetGeometry reply), with geometry_ordinal identifying that evidence.
The pre-delivery core wire_root can be zero; this tool targets the default root.
RandR notifications describe output changes separately and do not overwrite root
geometry. XI2 raw buttons have no coordinates; correlate their timestamp/detail
with core_button records. X timestamps are wrapping 32-bit milliseconds; utc_ns
and monotonic_ns are receipt times, not event-generation times. Synthetic sent
Configure events are logged but cannot change trusted geometry.

The diagnostic exits after --seconds (1..3600), --max-events, or SIGTERM/SIGINT.
A hard SIGALRM watchdog terminates five seconds later if Xlib/output blocks. JSON
must be redirected to a file/regularly drained pipe. Missing extensions or parse
errors fail explicitly; there is no racing XQueryPointer fallback.
Protocol layouts: X11/Xproto.h, extensions/XI2proto.h, randrproto.h, record.h.
"""

import argparse
import ctypes as C
import json
import select
import signal
import struct
import sys
import time


class Range8(C.Structure):
    _fields_ = [("first", C.c_ubyte), ("last", C.c_ubyte)]


class Range16(C.Structure):
    _fields_ = [("first", C.c_ushort), ("last", C.c_ushort)]


class ExtRange(C.Structure):
    _fields_ = [("major", Range8), ("minor", Range16)]


class RecordRange(C.Structure):
    _fields_ = [("core_requests", Range8), ("core_replies", Range8),
                ("ext_requests", ExtRange), ("ext_replies", ExtRange),
                ("delivered_events", Range8), ("device_events", Range8),
                ("errors", Range8), ("client_started", C.c_int),
                ("client_died", C.c_int)]


class RecordData(C.Structure):
    _fields_ = [("id_base", C.c_ulong), ("server_time", C.c_ulong),
                ("client_seq", C.c_ulong), ("category", C.c_int),
                ("client_swapped", C.c_int), ("data", C.POINTER(C.c_ubyte)),
                ("data_len", C.c_ulong)]


class XIEventMask(C.Structure):
    _fields_ = [("deviceid", C.c_int), ("mask_len", C.c_int),
                ("mask", C.POINTER(C.c_ubyte))]


class XEvent(C.Union):
    pass


class Cookie(C.Structure):
    _fields_ = [("type", C.c_int), ("serial", C.c_ulong), ("send_event", C.c_int),
                ("display", C.c_void_p), ("extension", C.c_int), ("evtype", C.c_int),
                ("cookie", C.c_uint), ("data", C.c_void_p)]


class RawButton(C.Structure):
    _fields_ = [("type", C.c_int), ("serial", C.c_ulong), ("send_event", C.c_int),
                ("display", C.c_void_p), ("extension", C.c_int), ("evtype", C.c_int),
                ("time", C.c_ulong), ("deviceid", C.c_int), ("sourceid", C.c_int),
                ("detail", C.c_int), ("flags", C.c_int)]


XEvent._fields_ = [("type", C.c_int), ("cookie", Cookie), ("pad", C.c_long * 24)]


CALLBACK = C.CFUNCTYPE(None, C.c_void_p, C.POINTER(RecordData))


def bind(lib, name, result, *args):
    f = getattr(lib, name)
    f.restype, f.argtypes = result, list(args)
    return f


class Stream:
    def __init__(self, root, rr_base, xi_opcode, emit):
        self.root, self.rr_base, self.xi_opcode = root, rr_base, xi_opcode
        self.emit = emit
        self.ordinal = 0
        self.geometry = None
        self.geometry_ordinal = None
        self.ready = False

    def record(self, raw, swapped=False, server_time=0, client_id=0):
        endian = "<" if (sys.byteorder == "little") != bool(swapped) else ">"
        offset = 0
        while offset < len(raw):
            if len(raw) - offset < 32:
                raise ValueError("truncated X protocol element")
            kind = raw[offset] & 127
            length = 32
            if kind in (1, 35):
                length += 4 * struct.unpack_from(endian + "I", raw, offset + 4)[0]
            if length > len(raw) - offset:
                raise ValueError("truncated variable-length X protocol element")
            data = raw[offset:offset + length]
            offset += length
            self.ordinal += 1
            get = lambda fmt, at: struct.unpack_from(endian + fmt, data, at)
            row = {"stream": "record", "ordinal": self.ordinal, "server_record_time_ms": server_time,
                   "record_client_id": client_id, "sent_event": bool(data[0] & 128)}
            if kind == 1:  # Only GetGeometry replies are selected.
                if get("I", 8)[0] != self.root:
                    raise ValueError("initial geometry reply belongs to another root")
                self.geometry = get("HH", 16)
                self.geometry_ordinal = self.ordinal
                self.ready = True
                row.update(event="ready", units="X root pixels", root=self.root)
            elif kind in (4, 5) and client_id == 0:
                row.update(event="core_button", action="down" if kind == 4 else "up",
                           button=data[1], event_time_ms=get("I", 4)[0],
                           root_x=get("h", 20)[0], root_y=get("h", 22)[0],
                           wire_root=get("I", 8)[0], state=get("H", 28)[0])
            elif kind == 22 and get("I", 8)[0] == self.root:
                width, height = get("HH", 20)
                row.update(event="root_configure", width=width, height=height,
                           event_time_ms=None)
                if not row["sent_event"]:
                    self.geometry = (width, height)
                    self.geometry_ordinal = self.ordinal
            elif kind == self.rr_base and get("I", 12)[0] == self.root:
                row.update(event="randr_screen", event_time_ms=get("I", 4)[0],
                           config_time_ms=get("I", 8)[0], rotation=data[1],
                           width=get("H", 24)[0], height=get("H", 26)[0])
            elif kind == self.rr_base + 1:
                row.update(event="randr_notify", subtype=data[1], wire_hex=data.hex())
                if data[1] in (0, 1):
                    row["event_time_ms"] = get("I", 4)[0]
                if data[1] == 0:
                    row.update(crtc=get("I", 12)[0], mode=get("I", 16)[0],
                               x=get("h", 24)[0], y=get("h", 26)[0],
                               width=get("H", 28)[0], height=get("H", 30)[0])
            else:
                continue
            row.update(root_width=self.geometry[0] if self.geometry else None,
                       root_height=self.geometry[1] if self.geometry else None,
                       geometry_ordinal=self.geometry_ordinal)
            self.emit(row)


class Observer:
    def __init__(self, emit):
        self.x = C.CDLL("libX11.so.6")
        self.xt = C.CDLL("libXtst.so.6")
        self.xi = C.CDLL("libXi.so.6")
        self.rr = C.CDLL("libXrandr.so.2")
        P, U, I = C.c_void_p, C.c_ulong, C.c_int
        IP = C.POINTER(I)
        for name, result, args in (
            ("XOpenDisplay", P, [C.c_char_p]), ("XCloseDisplay", I, [P]),
            ("XDefaultRootWindow", U, [P]), ("XDefaultGC", P, [P, I]),
            ("XDefaultScreen", I, [P]), ("XGContextFromGC", U, [P]),
            ("XConnectionNumber", I, [P]), ("XSync", I, [P, I]),
            ("XNoOp", I, [P]), ("XFlush", I, [P]),
            ("XPending", I, [P]), ("XNextEvent", I, [P, C.POINTER(XEvent)]),
            ("XGetEventData", I, [P, C.POINTER(Cookie)]),
            ("XFreeEventData", None, [P, C.POINTER(Cookie)]),
            ("XSelectInput", I, [P, U, C.c_long]),
            ("XQueryExtension", I, [P, C.c_char_p, IP, IP, IP]),
            ("XGetGeometry", I, [P, U, C.POINTER(U), IP, IP,
                                 C.POINTER(C.c_uint), C.POINTER(C.c_uint),
                                 C.POINTER(C.c_uint), C.POINTER(C.c_uint)]),
        ):
            bind(self.x, name, result, *args)
        bind(self.xt, "XRecordQueryVersion", I, P, IP, IP)
        bind(self.xt, "XRecordCreateContext", U, P, I, C.POINTER(U), I,
             C.POINTER(C.POINTER(RecordRange)), I)
        bind(self.xt, "XRecordEnableContextAsync", I, P, U, CALLBACK, P)
        bind(self.xt, "XRecordProcessReplies", None, P)
        bind(self.xt, "XRecordDisableContext", I, P, U)
        bind(self.xt, "XRecordFreeContext", I, P, U)
        bind(self.xt, "XRecordFreeData", None, C.POINTER(RecordData))
        bind(self.xi, "XIQueryVersion", I, P, IP, IP)
        bind(self.xi, "XISelectEvents", I, P, U, C.POINTER(XIEventMask), I)
        bind(self.rr, "XRRQueryExtension", I, P, IP, IP)
        bind(self.rr, "XRRSelectInput", None, P, U, I)
        self.control = self.data = None
        self.context = 0
        self.failure = None
        self.emit = emit
        self.xi_ordinal = 0
        self.callback = CALLBACK(self.receive)
        try:
            self.control, self.data = self.x.XOpenDisplay(None), self.x.XOpenDisplay(None)
            if not self.control or not self.data:
                raise RuntimeError("Cannot open DISPLAY as this desktop user")
            major, minor, rr_base, error, xi_opcode = I(), I(), I(), I(), I()
            if not self.xt.XRecordQueryVersion(self.control, C.byref(major), C.byref(minor)):
                raise RuntimeError("X RECORD extension unavailable")
            if not self.rr.XRRQueryExtension(self.control, C.byref(rr_base), C.byref(error)):
                raise RuntimeError("RandR extension unavailable")
            if not self.x.XQueryExtension(self.control, b"XInputExtension", C.byref(xi_opcode),
                                         C.byref(major), C.byref(error)):
                raise RuntimeError("XInput extension unavailable")
            major.value, minor.value = 2, 1
            if self.xi.XIQueryVersion(self.control, C.byref(major), C.byref(minor)) != 0:
                raise RuntimeError("XI2.1 unavailable")
            root = self.x.XDefaultRootWindow(self.control)
            self.stream = Stream(root, rr_base.value, xi_opcode.value, emit)
            self.x.XSelectInput(self.control, root, 1 << 17)  # StructureNotify only.
            self.rr.XRRSelectInput(self.control, root, 7)  # Screen, CRTC, output.
            bits = (C.c_ubyte * 3)(0, 128, 1)  # XI_RawButtonPress/Release.
            mask = XIEventMask(1, 3, bits)  # XIAllMasterDevices, no slave duplicates.
            if self.xi.XISelectEvents(self.control, root, C.byref(mask), 1) != 0:
                raise RuntimeError("XI2 raw button selection failed")
            # A GC XID identifies ONLY our observer connection, not all clients.
            gc = self.x.XDefaultGC(self.control, self.x.XDefaultScreen(self.control))
            clients = (U * 1)(self.x.XGContextFromGC(gc))
            ranges = [RecordRange() for _ in range(2)]
            # A recorded no-op switches RECORD's buffered category, flushing
            # the last device event even on an otherwise completely idle Xvfb.
            ranges[0].core_requests = Range8(127, 127)
            ranges[0].core_replies = Range8(14, 14)  # Initial root GetGeometry.
            ranges[0].device_events = Range8(4, 5)  # Global pre-delivery core buttons.
            ranges[0].delivered_events = Range8(22, 22)  # Our root ConfigureNotify.
            # Xorg RECORD does not reliably record variable-length XI2 events.
            # Read raw cookies separately; never attach guessed geometry to them.
            ranges[1].delivered_events = Range8(rr_base.value, rr_base.value + 1)
            pointers = (C.POINTER(RecordRange) * 2)(*[C.pointer(r) for r in ranges])
            self.context = self.xt.XRecordCreateContext(self.control, 1, clients, 1, pointers, 2)
            if not self.context:
                raise RuntimeError("XRecordCreateContext failed")
            self.x.XSync(self.control, 0)
            if not self.xt.XRecordEnableContextAsync(self.data, self.context, self.callback, None):
                raise RuntimeError("XRecordEnableContextAsync failed")
            # Record the reply itself to seed geometry at the correct stream ordinal.
            out_root, x, y = U(), I(), I()
            width, height, border, depth = [C.c_uint() for _ in range(4)]
            if not self.x.XGetGeometry(self.control, root, C.byref(out_root), C.byref(x),
                                      C.byref(y), C.byref(width), C.byref(height),
                                      C.byref(border), C.byref(depth)):
                raise RuntimeError("Cannot query initial root geometry")
        except BaseException:
            self.close()
            raise

    def receive(self, closure, pointer):
        try:
            record = pointer.contents
            if record.category == 0 and not self.failure:
                if record.data_len > 262144:
                    raise ValueError("unexpected RECORD element over 1 MiB")
                self.stream.record(C.string_at(record.data, record.data_len * 4),
                                   record.client_swapped, record.server_time, record.id_base)
        except Exception as exc:
            self.failure = str(exc)
        finally:
            self.xt.XRecordFreeData(pointer)

    def poll(self, timeout):
        # A no-op wakes an otherwise idle server so its final buffered RECORD
        # element is flushed. It does not query or change input/geometry.
        self.x.XNoOp(self.control)
        self.x.XFlush(self.control)
        # This reads ordered records already buffered by Xlib before waiting.
        self.xt.XRecordProcessReplies(self.data)
        event = XEvent()
        for _ in range(256):
            if not self.x.XPending(self.control):
                break
            self.x.XNextEvent(self.control, C.byref(event))
            if event.type == 35 and self.x.XGetEventData(self.control, C.byref(event.cookie)):
                try:
                    cookie = event.cookie
                    if cookie.extension == self.stream.xi_opcode and cookie.evtype in (15, 16):
                        raw = C.cast(cookie.data, C.POINTER(RawButton)).contents
                        self.xi_ordinal += 1
                        self.emit({"stream": "xi2", "xi_ordinal": self.xi_ordinal,
                                   "event": "xi2_raw_button", "event_time_ms": raw.time,
                                   "action": "down" if raw.evtype == 15 else "up",
                                   "device_id": raw.deviceid, "source_id": raw.sourceid,
                                   "button": raw.detail})
                finally:
                    self.x.XFreeEventData(self.control, C.byref(event.cookie))
        fds = [self.x.XConnectionNumber(d) for d in (self.data, self.control)]
        select.select(fds, [], [], timeout)
        self.xt.XRecordProcessReplies(self.data)
        if self.failure:
            raise RuntimeError(self.failure)

    def close(self):
        if self.context and self.control:
            self.xt.XRecordDisableContext(self.control, self.context)
            self.x.XSync(self.control, 0)
            if self.data:
                self.xt.XRecordProcessReplies(self.data)
            self.xt.XRecordFreeContext(self.control, self.context)
            self.context = 0
        for attr in ("data", "control"):
            display = getattr(self, attr)
            if display:
                self.x.XCloseDisplay(display)
                setattr(self, attr, None)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seconds", type=int, default=300, choices=range(1, 3601), metavar="1..3600")
    parser.add_argument("--max-events", type=int, default=100000)
    args = parser.parse_args()
    if not 1 <= args.max_events <= 1000000:
        parser.error("--max-events must be 1..1000000")
    stopped = False
    count = 0

    def stop(signum, frame):
        nonlocal stopped
        stopped = True

    def emit(row):
        nonlocal count, stopped
        if count >= args.max_events:
            stopped = True
            return
        count += 1
        row.update(monotonic_ns=time.monotonic_ns(), utc_ns=time.time_ns())
        print(json.dumps(row, separators=(",", ":")), flush=True)

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    # The kernel default also terminates a blocked native Xlib call. A Python
    # alarm handler would wait for that call to return before it could run.
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.alarm(args.seconds + 5)
    observer = None
    try:
        deadline = time.monotonic() + args.seconds
        observer = Observer(emit)
        while not stopped and time.monotonic() < deadline:
            observer.poll(min(0.1, max(0, deadline - time.monotonic())))
        if not observer.stream.ready:
            raise RuntimeError("No recorded initial geometry reply; trace is not ready")
        observer.close()
        if observer.failure:
            raise RuntimeError(observer.failure)
        print(json.dumps({"event": "end", "records": count,
                          "reason": "stopped_or_limit" if stopped else "deadline"}), flush=True)
        return 0
    except (OSError, RuntimeError, ValueError) as exc:
        print(json.dumps({"event": "error", "message": str(exc)}), flush=True)
        return 1
    finally:
        if observer:
            observer.close()
        signal.alarm(0)


if __name__ == "__main__":
    sys.exit(main())
