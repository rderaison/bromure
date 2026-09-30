#!/usr/bin/env python3
"""Exercise the packaged real Metal worker, including malformed pipe frames."""
import argparse
import struct
import subprocess
import unittest


def command(kind, body=b"", context=0, flags=0, fence=0):
    return struct.pack("<IIQII", kind, flags, fence, context, 0) + body


class WorkerTests(unittest.TestCase):
    def exchange(self, commands, split=False, trailing=b"", expected_exit=0):
        payload = b"".join(struct.pack("<I", len(c)) + c for c in commands) + trailing
        process = subprocess.Popen([HELPER, "--worker"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if split:
            for byte in payload:
                process.stdin.write(bytes([byte]))
                process.stdin.flush()
            process.stdin.close()
            process.stdin = None
            output, diagnostics = process.communicate(timeout=15)
        else:
            output, diagnostics = process.communicate(payload, timeout=15)
        self.assertEqual(process.returncode, expected_exit, diagnostics.decode(errors="replace"))
        replies = []
        while output:
            self.assertGreaterEqual(len(output), 4)
            length = struct.unpack_from("<I", output)[0]
            self.assertTrue(24 <= length <= 65536)
            self.assertGreaterEqual(len(output), length + 4)
            replies.append(output[4:4 + length])
            output = output[4 + length:]
        return replies

    def test_capsets_and_partial_reads(self):
        replies = self.exchange([command(0x108, struct.pack("<II", index, 0))
                                 for index in (0, 1)], split=True)
        sizes = []
        for index, reply in enumerate(replies):
            self.assertEqual(len(reply), 40)
            kind, version, size = struct.unpack_from("<III", reply, 24)
            self.assertEqual(kind, index + 1)
            self.assertGreater(version, 0)
            self.assertGreater(size, 0)
            sizes.append((kind, version, size))
        caps = self.exchange([command(0x109, struct.pack("<II", kind, version))
                              for kind, version, _ in sizes])
        for reply, (_, _, size) in zip(caps, sizes):
            self.assertEqual(struct.unpack_from("<I", reply)[0], 0x1103)
            self.assertEqual(len(reply), size + 24)

    def test_context_lifetime_and_reset(self):
        create = command(0x200, struct.pack("<II64s", 4, 0, b"test"), context=7)
        destroy = command(0x201, context=7)
        replies = self.exchange([create, create, destroy, destroy, create,
                                 command(0xffff0001), create, destroy])
        self.assertEqual([struct.unpack_from("<I", r)[0] for r in replies],
                         [0x1100, 0x1204, 0x1100, 0x1204, 0x1100, 0x1100, 0x1100, 0x1100])

    def test_context_budget(self):
        replies = self.exchange([command(0x200, bytes(72), context=i)
                                 for i in range(1, 34)])
        self.assertEqual([struct.unpack_from("<I", r)[0] for r in replies],
                         [0x1100] * 32 + [0x1201])

    def test_3d_submission_fence_and_native_texture(self):
        # Pinned VirGL wire ABI: surface, framebuffer, red clear. This goes
        # through the exact immutable SUBMIT_3D decoder used by guest commands.
        words = [1 | (8 << 8) | (5 << 16), 11, 9, 1, 0, 0,
                 5 | (3 << 16), 1, 0, 11,
                 7 | (8 << 16), 4, 0x3f800000, 0, 0, 0x3f800000, 0, 0, 0]
        stream = struct.pack("<" + "I" * len(words), *words)
        replies = self.exchange([
            command(0x200, struct.pack("<II64s", 4, 0, b"test"), context=7),
            command(0x204, struct.pack("<12I", 9, 2, 1, (1 << 1) | (1 << 18),
                                      64, 64, 1, 1, 0, 0, 0, 0)),
            command(0x202, struct.pack("<II", 9, 0), context=7),
            command(0x207, struct.pack("<II", len(stream), 0) + stream,
                    context=7, flags=1, fence=0x123456789abcdef0),
            command(0xffff0002, struct.pack("<II", 9, 0)),
            command(0x102, struct.pack("<II", 9, 0)),
            command(0x201, context=7),
        ])
        self.assertEqual([struct.unpack_from("<I", r)[0] for r in replies], [0x1100] * 7)
        self.assertEqual(struct.unpack_from("<Q", replies[3], 8)[0], 0x123456789abcdef0)

    def test_invalid_commands_and_fence_metadata(self):
        replies = self.exchange([command(0x108, struct.pack("<II", 2, 0)),
                                 command(0x109, struct.pack("<II", 1, 99)),
                                 command(0x100, flags=2), command(0x777),
                                 command(0x100, flags=1, fence=0x123456789abcdef0)])
        self.assertEqual([struct.unpack_from("<I", r)[0] for r in replies],
                         [0x1205, 0x1205, 0x1205, 0x1200, 0x1101])
        self.assertEqual(struct.unpack_from("<Q", replies[-1], 8)[0], 0x123456789abcdef0)

    def test_backing_upload_transfer_and_bounds(self):
        pixels = bytes([0, 0, 255, 255]) * (64 * 64)
        private = lambda kind, offset, count, data=b"": command(
            kind, struct.pack("<IQI", 9, offset, count) + data)
        replies = self.exchange([
            command(0x200, bytes(72), context=7),
            command(0x204, struct.pack("<12I", 9, 2, 1, (1 << 1) | (1 << 18),
                                      64, 64, 1, 1, 0, 0, 0, 0)),
            command(0x202, struct.pack("<II", 9, 0), context=7),
            private(0xffff0010, len(pixels), 0),
            private(0xffff0011, 0, len(pixels), pixels),
            command(0x205, struct.pack("<6IQ4I", 0, 0, 0, 64, 64, 1, 0, 9, 0, 256, 16384),
                    context=7, flags=1, fence=42),
            command(0xffff0002, struct.pack("<II", 9, 0)),
            private(0xffff0012, 0, 4),
            private(0xffff0012, len(pixels), 1),
            private(0xffff0011, 0xffffffffffffffff, 1, b"x"),
            command(0x107, struct.pack("<II", 9, 0)),
            private(0xffff0012, 0, 4),
        ])
        self.assertEqual([struct.unpack_from("<I", r)[0] for r in replies],
                         [0x1100] * 8 + [0x1205, 0x1205, 0x1100, 0x1205])
        self.assertEqual(replies[7][24:], pixels[:4])

    def test_truncated_and_oversize_frames(self):
        for payload in (b"\x18", struct.pack("<I", 23), struct.pack("<I", 65537),
                        struct.pack("<I", 24) + bytes(12)):
            self.assertEqual(self.exchange([], trailing=payload, expected_exit=1), [])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper", help="Packaged sandboxed metal-probe executable")
    HELPER = parser.parse_args().helper
    unittest.main(argv=[__file__])
