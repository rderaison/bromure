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

    def test_fullscreen_depth_budget(self):
        # User's 5K fullscreen depth attachment: 4 bytes, not fallback 32.
        for samples in (0, 4):
            with self.subTest(samples=samples):
                replies = self.exchange([
                    command(0x204, struct.pack("<12I", 9, 2, 20, 1,
                                              5120, 2948, 1, 1, 0, samples, 0, 0)),
                    command(0xffff0030),
                    command(0x102, struct.pack("<II", 9, 0)),
                ])
                self.assertEqual(struct.unpack_from("<I", replies[0])[0], 0x1100)
                self.assertEqual(struct.unpack_from("<Q", replies[1], 32)[0],
                                 5120 * 2948 * 4 * max(samples, 1))
                self.assertEqual(struct.unpack_from("<I", replies[2])[0], 0x1100)

    def test_fullscreen_depth_byte_limit_preserved(self):
        replies = self.exchange([
            command(0x204, struct.pack("<12I", 9, 2, 20, 1,
                                      5120, 2948, 1, 1, 0, 8, 0, 0)),
            command(0xffff0030),
        ])
        self.assertEqual(struct.unpack_from("<I", replies[0])[0], 0x1201)
        self.assertEqual(struct.unpack_from("<I", replies[1], 24)[0], 0)
        self.assertEqual(struct.unpack_from("<Q", replies[1], 32)[0], 0)

    def test_retina_buffer_and_backing_budget(self):
        # Buffer width is bytes, not texels. Browser staging buffers at 5K
        # legitimately exceed16MiB; keep256MiB each and separate bounded GPU/staging pools.
        size = 34447360
        commands = []
        for i in range(1, 10):
            commands += [command(0x204, struct.pack("<12I", i, 0, 64, 16,
                                                   size, 1, 1, 1, 0, 0, 0, 0)),
                         command(0xffff0010, struct.pack("<IQI", i, size, 0))]
        replies = self.exchange(commands)
        self.assertTrue(all(struct.unpack_from("<I", r)[0] == 0x1100 for r in replies))

    def test_6k_8k_adaptive_depth_budget(self):
        for width, height in ((6016, 3384), (7680, 4320)):
            with self.subTest(width=width):
                replies = self.exchange([
                    command(0xffff0020, struct.pack("<II", width, height)),
                    command(0x204, struct.pack("<12I", 9, 2, 20, 1,
                                              width, height, 1, 1, 0, 4, 0, 0)),
                    command(0xffff0030),
                ])
                self.assertEqual([struct.unpack_from("<I", r)[0] for r in replies], [0x1100] * 3)
                self.assertEqual(struct.unpack_from("<Q", replies[2], 32)[0], width * height * 16)
                gpu, staging, resource = struct.unpack_from("<QQQ", replies[2], 64)
                self.assertTrue(1073741824 <= gpu <= 4294967296)
                self.assertTrue(1073741824 <= staging <= 2147483648)
                self.assertEqual(resource, 536870912)

    def test_browser_resource_count(self):
        # Real page browsing needs >256 small live resources, well below 1 GiB.
        commands = [command(0x204, struct.pack("<12I", i, 0, 64, 16,
                                               64, 1, 1, 1, 0, 0, 0, 0))
                    for i in range(1, 301)]
        commands += [command(0xffff0030)]
        commands += [command(0x102, struct.pack("<II", i, 0)) for i in range(1, 301)]
        commands += [command(0xffff0030)]
        replies = self.exchange(commands)
        self.assertTrue(all(struct.unpack_from("<I", r)[0] == 0x1100 for r in replies))
        self.assertEqual(struct.unpack_from("<I", replies[300], 24)[0], 300)
        self.assertEqual(struct.unpack_from("<Q", replies[300], 32)[0], 300 * 65536)
        self.assertEqual(struct.unpack_from("<I", replies[-1], 24)[0], 0)
        self.assertEqual(struct.unpack_from("<Q", replies[-1], 32)[0], 0)

    def test_live_pools_grow_above_one_gib_and_release(self):
        # Real browsing/resize can retain >1GiB despite a modest scanout.
        # Allocate both Metal storage and host staging, then check accounting.
        import os
        ram_ceiling = max(1073741824, os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE") // 8 // 268435456 * 268435456)
        if ram_ceiling <= 1073741824:
            self.skipTest("Host RAM policy caps pools at1GiB")
        size = 67108864
        commands = []
        for i in range(1, 18):
            commands += [command(0x204, struct.pack("<12I", i, 0, 64, 16, size, 1, 1, 1, 0, 0, 0, 0)),
                         command(0xffff0010, struct.pack("<IQI", i, size, 0))]
        commands += [command(0xffff0030)]
        commands += [command(0x102, struct.pack("<II", i, 0)) for i in range(1, 18)]
        commands += [command(0xffff0030)]
        replies = self.exchange(commands)
        self.assertTrue(all(struct.unpack_from("<I", r)[0] == 0x1100 for r in replies))
        stats = replies[34]
        self.assertEqual(struct.unpack_from("<Q", stats, 32)[0], 17 * size)
        self.assertEqual(struct.unpack_from("<Q", stats, 40)[0], 17 * size)
        gpu, staging = struct.unpack_from("<QQ", stats, 64)
        self.assertEqual((gpu, staging), (1342177280, 1342177280))
        self.assertEqual(struct.unpack_from("<QQ", replies[-1], 32), (0, 0))

    def test_demand_growth_stops_at_staging_ceiling(self):
        import os
        ram_ceiling = max(1073741824, os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE") // 8 // 268435456 * 268435456)
        ceiling = min(ram_ceiling, 2147483648)
        size = 134217728
        count = ceiling // size
        commands = []
        for i in range(1, count + 2):
            commands += [command(0x204, struct.pack("<12I", i, 0, 64, 16, size, 1, 1, 1, 0, 0, 0, 0)),
                         command(0xffff0010, struct.pack("<IQI", i, size, 0))]
        commands += [command(0xffff0030)]
        commands += [command(0x102, struct.pack("<II", i, 0)) for i in range(1, count + 2)]
        commands += [command(0xffff0030)]
        replies = self.exchange(commands)
        self.assertTrue(all(struct.unpack_from("<I", r)[0] == 0x1100 for r in replies[:count * 2]))
        self.assertNotEqual(struct.unpack_from("<I", replies[count * 2 + 1])[0], 0x1100)
        stats = replies[count * 2 + 2]
        self.assertEqual(struct.unpack_from("<Q", stats, 40)[0], ceiling)
        self.assertEqual(struct.unpack_from("<Q", stats, 72)[0], ceiling)
        self.assertEqual(struct.unpack_from("<QQ", replies[-1], 32), (0, 0))

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

    def test_bgrx_top_origin_2d_upload(self):
        # Linux framebuffer uploads use opaque BGRX with top-left origin. Metal
        # still stores four bytes; treating it as 24-bit RGB breaks GLES upload.
        pixels = bytes([0, 0, 255, 255]) * (64 * 64)
        replies = self.exchange([
            command(0x101, struct.pack("<4I", 9, 2, 64, 64)),
            command(0xffff0010, struct.pack("<IQI", 9, len(pixels), 0)),
            command(0xffff0011, struct.pack("<IQI", 9, 0, len(pixels)) + pixels),
            command(0x105, struct.pack("<4IQII", 0, 0, 64, 64, 0, 9, 0), flags=1, fence=42),
            command(0xffff0002, struct.pack("<II", 9, 0)),
        ])
        self.assertEqual([struct.unpack_from("<I", r)[0] for r in replies], [0x1100] * 5)

    def test_real_multisample_clear_and_resolve(self):
        # Clear a real four-sample renderbuffer, resolve on GPU into a native
        # scanout texture, and verify the resolved red pixel.
        words = [1 | (8 << 8) | (5 << 16), 11, 9, 1, 0, 0,
                 5 | (3 << 16), 1, 0, 11,
                 7 | (8 << 16), 4, 0x3f800000, 0, 0, 0x3f800000, 0, 0, 0,
                 16 | (21 << 16), 15, 0, 0, 10, 0, 1, 0, 0, 0, 64, 64, 1,
                 9, 0, 1, 0, 0, 0, 64, 64, 1]
        stream = struct.pack("<" + "I" * len(words), *words)
        replies = self.exchange([
            command(0x204, struct.pack("<12I", 9, 2, 1, 2, 64, 64, 1, 1, 0, 4, 0, 0)),
            command(0x204, struct.pack("<12I", 10, 2, 1, 2 | (1 << 18), 64, 64, 1, 1, 0, 0, 0, 0)),
            command(0x200, bytes(72), context=7),
            command(0x202, struct.pack("<II", 9, 0), context=7),
            command(0x202, struct.pack("<II", 10, 0), context=7),
            command(0x207, struct.pack("<II", len(stream), 0) + stream, context=7, flags=1, fence=42),
            command(0xffff0002, struct.pack("<II", 10, 0)),
        ])
        self.assertEqual([struct.unpack_from("<I", r)[0] for r in replies], [0x1100] * 7)

    def test_cross_context_buffer_upload_and_readback(self):
        # Resources belong to VirGL's resource context, not the startup probe.
        # Independent guest contexts must access the same underlying GL buffer.
        payload = bytes(range(64))
        private = lambda kind, offset, count, data=b"": command(
            kind, struct.pack("<IQI", 9, offset, count) + data)
        transfer = lambda direction: struct.pack("<14I", 43 | (13 << 16),
            9, 0, 0, 0, 0, 0, 0, 0, 64, 1, 1, 0, direction)
        upload, download = transfer(1), transfer(2)
        replies = self.exchange([
            command(0x204, struct.pack("<12I", 9, 0, 64, 16, 64, 1, 1, 1, 0, 0, 0, 0)),
            command(0x200, bytes(72), context=7),
            command(0x200, bytes(72), context=8),
            command(0x202, struct.pack("<II", 9, 0), context=7),
            command(0x202, struct.pack("<II", 9, 0), context=8),
            private(0xffff0010, 64, 0), private(0xffff0011, 0, 64, payload),
            command(0x207, struct.pack("<II", len(upload), 0) + upload, context=7, flags=1, fence=1),
            private(0xffff0011, 0, 64, bytes(64)),
            command(0x207, struct.pack("<II", len(download), 0) + download, context=8, flags=1, fence=2),
            private(0xffff0012, 0, 64),
        ])
        self.assertEqual([struct.unpack_from("<I", r)[0] for r in replies], [0x1100] * 11)
        self.assertEqual(replies[-1][24:], payload)

    def test_large_3d_submission_and_non_submission_limit(self):
        create = command(0x200, struct.pack("<II64s", 4, 0, b"large"), context=7)
        # Real valid VirGL NOP stream spanning the former 64-KiB ceiling.
        stream = bytes(80000)
        submit = command(0x207, struct.pack("<II", len(stream), 0) + stream, context=7)
        invalid_size = command(0x207, struct.pack("<II", len(stream) - 4, 0) + stream, context=7)
        replies = self.exchange([create, submit, invalid_size, command(0x100, bytes(80000))])
        self.assertEqual([struct.unpack_from("<I", r)[0] for r in replies],
                         [0x1100, 0x1100, 0x1205, 0x1205])

    def test_truncated_and_oversize_frames(self):
        for payload in (b"\x18", struct.pack("<I", 23), struct.pack("<I", 1048577),
                        struct.pack("<I", 24) + bytes(12)):
            self.assertEqual(self.exchange([], trailing=payload, expected_exit=1), [])

    def test_display_resize_preserves_live_resources(self):
        replies = self.exchange([
            command(0xffff0020, struct.pack("<II", 64, 64)),
            command(0x101, struct.pack("<4I", 9, 1, 64, 64)),
            command(0xffff0020, struct.pack("<II", 128, 96)),
            command(0x100),
            command(0x104, struct.pack("<6I", 0, 0, 64, 64, 9, 0)),
            command(0xffff0020, struct.pack("<II", 8192, 8192)),
            command(0x100),
        ])
        self.assertEqual([struct.unpack_from("<I", r)[0] for r in replies],
                         [0x1100, 0x1100, 0x1100, 0x1101, 0x1100, 0x1205, 0x1101])
        self.assertEqual(struct.unpack_from("<III", replies[3], 32), (128, 96, 1))
        self.assertEqual(struct.unpack_from("<III", replies[6], 32), (128, 96, 1))

    def test_cropped_scanout_bounds(self):
        replies = self.exchange([
            command(0x101, struct.pack("<4I", 9, 1, 64, 64)),
            command(0x103, struct.pack("<6I", 8, 12, 32, 24, 0, 9)),
            command(0x104, struct.pack("<6I", 8, 12, 32, 24, 9, 0)),
            command(0x103, struct.pack("<6I", 33, 12, 32, 24, 0, 9)),
        ])
        self.assertEqual([struct.unpack_from("<I", r)[0] for r in replies],
                         [0x1100, 0x1100, 0x1100, 0x1205])

    def test_display_scanout_and_flush(self):
        replies = self.exchange([
            command(0xffff0020, struct.pack("<II", 64, 64)), command(0x100),
            command(0x101, struct.pack("<4I", 9, 1, 64, 64)),
            command(0x103, struct.pack("<6I", 0, 0, 64, 64, 0, 9)),
            command(0x104, struct.pack("<6I", 0, 0, 64, 64, 9, 0)),
            command(0x103, struct.pack("<6I", 0, 0, 64, 64, 1, 9)),
            command(0x104, struct.pack("<6I", 0, 0, 65, 64, 9, 0)),
        ])
        self.assertEqual([struct.unpack_from("<I", r)[0] for r in replies],
                         [0x1100, 0x1101, 0x1100, 0x1100, 0x1100, 0x1202, 0x1205])
        self.assertEqual(struct.unpack_from("<III", replies[1], 32), (64, 64, 1))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper", help="Packaged sandboxed metal-probe executable")
    HELPER = parser.parse_args().helper
    unittest.main(argv=[__file__])
