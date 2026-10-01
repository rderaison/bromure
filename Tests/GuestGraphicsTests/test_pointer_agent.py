"""Pointer protocol and actual packed Linux events; no host input injection."""

import json
import socket
import struct
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

from test_guest_graphics import load_script

agent = load_script("pointer-agent")


class PointerAgentTests(unittest.TestCase):
    def receive_stream(self, pointer, stream):
        # Read while writing: Darwin's socketpair buffer need not hold the
        # backlog. Deliberately use a small buffer on every platform.
        sender, receiver = socket.socketpair()
        errors = []
        with sender, receiver:
            sender.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1024)
            sender.settimeout(5)
            receiver.settimeout(5)

            def send():
                try:
                    sender.sendall(stream)
                    sender.shutdown(socket.SHUT_WR)
                except OSError as error:
                    errors.append(error)
                finally:
                    sender.close()

            writer = threading.Thread(target=send, daemon=True)
            writer.start()
            try:
                agent.handle_connection(receiver, pointer)
            finally:
                receiver.close()
                writer.join(timeout=6)
            self.assertFalse(writer.is_alive(), "Pointer test writer did not stop")
            self.assertEqual(errors, [], "Pointer test sender failed")

    def events(self, chunks):
        # A socketpair exercises the stream reader; a file replaces /dev/uinput.
        with tempfile.TemporaryFile() as output:
            pointer = agent.Pointer(output.fileno())
            sender, receiver = socket.socketpair()
            try:
                sender.sendall(b"".join(chunks))
                sender.shutdown(socket.SHUT_WR)
                error = None
                try:
                    agent.handle_connection(receiver, pointer)
                except ValueError as caught:
                    error = caught
                output.seek(0)
                events = [event[2:] for event in agent.EVENT.iter_unpack(output.read())]
                return events, error, pointer.buttons
            finally:
                sender.close()
                receiver.close()

    def test_coordinate_bounds_and_button_policy(self):
        self.assertEqual(agent.parse_snapshot(b'{"x":0,"y":1,"buttons":7}'), (0, 65535, 7))
        self.assertEqual(agent.parse_snapshot(b'{"x":-3,"y":2,"buttons":0}'), (0, 65535, 0))
        self.assertEqual(agent.parse_snapshot(b'{"x":0.5,"y":0.5,"buttons":1}'), (32768, 32768, 1))
        for field, value in (("x", True), ("x", "1"), ("x", float("inf")),
                             ("y", float("nan")), ("buttons", -1), ("buttons", 8),
                             ("buttons", True), ("buttons", 1.0)):
            message = {"x": 0, "y": 0, "buttons": 0, field: value}
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                agent.parse_snapshot(json.dumps(message).encode())

    def test_press_drag_release_and_disconnect(self):
        events, error, buttons = self.events([
            b'{"x":0,"y":0,"buttons":1}\n',
            b'{"x":1,"y":1,"buttons":1}\n',
            b'{"x":1,"y":1,"buttons":0}\n',
            b'{"x":0.5,"y":0.5,"buttons":6}\n',
        ])
        self.assertIsNone(error)
        self.assertEqual(buttons, 0)
        keys = [event for event in events if event[0] == agent.EV_KEY]
        self.assertEqual(keys, [(1, 0x110, 1), (1, 0x110, 0),
                               (1, 0x111, 1), (1, 0x112, 1),
                               (1, 0x110, 0), (1, 0x111, 0), (1, 0x112, 0)])
        self.assertEqual(sum(event == (0, 0, 0) for event in events), 5)
        self.assertEqual(events[:3], [(3, 0, 0), (3, 1, 0), (1, 0x110, 1)])

    def test_invalid_or_oversize_stream_releases_buttons(self):
        invalid = [b'[]\n', b'{"x":0,"y":0,"buttons":1,"key":65}\n',
                   b'{"x":0,"x":1,"y":0,"buttons":0}\n',
                   b'x' * 1025, b'x' * 1025 + b'\n', b'\xff\n']
        for suffix in invalid:
            with self.subTest(suffix=suffix[:40]):
                events, error, buttons = self.events([
                    b'{"x":0,"y":0,"buttons":1}\n', suffix])
                self.assertIsNotNone(error)
                self.assertEqual(buttons, 0)
                self.assertEqual(events[-4:], [(1, 0x110, 0), (1, 0x111, 0), (1, 0x112, 0), (0, 0, 0)])

    def test_fragmented_message_and_truncated_disconnect(self):
        class Fragmented:
            chunks = iter([b'{"x":0', b',"y":1,"buttons":4}', b'\n{"x":', b''])

            def recv(self, limit):
                return next(self.chunks)

        with tempfile.TemporaryFile() as output:
            pointer = agent.Pointer(output.fileno())
            agent.handle_connection(Fragmented(), pointer)
            output.seek(0)
            events = [event[2:] for event in agent.EVENT.iter_unpack(output.read())]
        self.assertIn((1, 0x112, 1), events)
        self.assertEqual(events[-2:], [(1, 0x112, 0), (0, 0, 0)])

    def test_maximum_sized_valid_message(self):
        line = b'{"x":0,"y":0,"buttons":0}'
        events, error, _ = self.events([line.ljust(1024, b' ') + b'\n'])
        self.assertIsNone(error)
        self.assertEqual(events, [(3, 0, 0), (3, 1, 0), (0, 0, 0)])

    def test_partial_frame_reconnect_discards_fragment_and_replays_full_frame(self):
        pressed = b'{"x":0,"y":0,"buttons":1}\n'
        replay = b'{"x":1,"y":1,"buttons":3}\n'
        released = b'{"x":1,"y":1,"buttons":0}\n'
        for split in range(1, len(replay)):
            with self.subTest(split=split), tempfile.TemporaryFile() as output:
                pointer = agent.Pointer(output.fileno())
                # Use the same uinput device across two independent streams.
                # Every possible incomplete prefix must die with the old one.
                for stream in (pressed + replay[:split], replay + released):
                    self.receive_stream(pointer, stream)
                    self.assertEqual(pointer.buttons, 0)
                output.seek(0)
                events = [event[2:] for event in agent.EVENT.iter_unpack(output.read())]
                positions = [event[2] for event in events
                             if event[:2] == (agent.EV_ABS, agent.ABS_X)]
                self.assertEqual(positions, [0, 65535, 65535])
                presses = [event[1] for event in events
                           if event[0] == agent.EV_KEY and event[2] == 1]
                self.assertEqual(presses, [0x110, 0x110, 0x111])

    def test_overflow_disconnect_then_reset_snapshot_leaves_buttons_released(self):
        # Model the host overflow contract: already-written complete frames
        # and an incomplete tail, then disconnect and reconnect with buttons=0.
        # This tests receiver recovery, not the host's queue size enforcement.
        backlog = b''.join(json.dumps({"x": 0.5, "y": 0.5,
                                      "buttons": 1 + i % 7}).encode() + b'\n'
                           for i in range(256))
        with tempfile.TemporaryFile() as output:
            pointer = agent.Pointer(output.fileno())
            for stream in (backlog + b'{"x":', b'{"x":1,"y":1,"buttons":0}\n'):
                self.receive_stream(pointer, stream)
                self.assertEqual(pointer.buttons, 0)
            output.seek(0)
            events = [event[2:] for event in agent.EVENT.iter_unpack(output.read())]
            self.assertEqual(events[-7:], [(1, 0x110, 0), (1, 0x111, 0),
                                          (1, 0x112, 0), (0, 0, 0),
                                          (3, 0, 65535), (3, 1, 65535), (0, 0, 0)])

    def test_uinput_device_has_only_absolute_axes_and_three_buttons(self):
        with patch.object(agent.subprocess, "run"), \
                patch.object(agent.os, "open", return_value=42), \
                patch.object(agent.fcntl, "ioctl") as ioctl:
            self.assertEqual(agent.create_uinput_device(), 42)
        calls = [call.args for call in ioctl.call_args_list]
        self.assertIn((42, agent.UI_SET_PROPBIT, agent.INPUT_PROP_POINTER), calls)
        self.assertEqual([c[2] for c in calls if c[1] == agent.UI_SET_KEYBIT], [0x110, 0x111, 0x112])
        axes = [struct.unpack("<H2xiiiiii", c[2]) for c in calls if c[1] == agent.UI_ABS_SETUP]
        self.assertEqual(axes, [(0, 0, 0, 65535, 0, 0, 0), (1, 0, 0, 65535, 0, 0, 0)])
        self.assertEqual(calls[-1], (42, agent.UI_DEV_CREATE))

    def test_only_host_cid_can_inject(self):
        clients, connections = [], []
        for cid, mask in ((3, 2), (2, 1)):
            client, connection = socket.socketpair()
            client.sendall(json.dumps({"x": 0, "y": 0, "buttons": mask}).encode() + b'\n')
            client.shutdown(socket.SHUT_WR)
            clients.append(client)
            connections.append((connection, (cid, 1234)))
        # Model the Linux-only vsock interface explicitly. Darwin can run this
        # socketpair/event-packing test without exporting Linux socket constants.
        linux_socket = SimpleNamespace(AF_VSOCK=40, SOCK_STREAM=1,
                                       VMADDR_CID_ANY=0xFFFFFFFF, VMADDR_CID_HOST=2,
                                       socket=MagicMock())
        with tempfile.TemporaryFile() as output, patch.object(agent, "socket", linux_socket):
            server = linux_socket.socket.return_value.__enter__.return_value
            server.accept.side_effect = [*connections, KeyboardInterrupt()]
            try:
                with self.assertRaises(KeyboardInterrupt):
                    agent.serve(agent.Pointer(output.fileno()))
                output.seek(0)
                presses = [e[2:] for e in agent.EVENT.iter_unpack(output.read()) if e[2] == 1 and e[4] == 1]
                self.assertEqual(presses, [(1, 0x110, 1)])
            finally:
                for client in clients:
                    client.close()
                for connection, _ in connections:
                    connection.close()


if __name__ == "__main__":
    unittest.main()
