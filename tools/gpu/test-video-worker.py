#!/usr/bin/env python3
"""Trusted red H.264 fixture through the actual guest VirGL video wire ABI."""
import argparse
import pathlib
import runpy
import struct
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('helper')
parser.add_argument('fixture')
parser.add_argument('--strip-parameter-sets', action='store_true')
parser.add_argument('--invalid-buffer-size', action='store_true')
parser.add_argument('--planar', action='store_true')
parser.add_argument('--shared', action='store_true')
parser.add_argument('--early-backing', action='store_true')
parser.add_argument('--encoded-readback', action='store_true')
parser.add_argument('--copy-readback', action='store_true')
args = parser.parse_args()
wire = runpy.run_path(str(pathlib.Path(__file__).with_name('test-renderer-worker.py')))
command = wire['command']
commands = [command(0x200, bytes(72), context=7)]
def resource(handle, target, fmt, bind, width, height=1):
    commands.append(command(0x204, struct.pack('<12I', handle, target, fmt, bind | ((1 << 20) if args.shared and target == 2 else 0), width, height, 1, 1, 0, 0, 0, 0)))
    commands.append(command(0x202, struct.pack('<II', handle, 0), context=7))
def backing(handle, data):
    commands.append(command(0xffff0010, struct.pack('<IQI', handle, len(data), 0)))
    for offset in range(0, len(data), 65496):
        chunk = data[offset:offset+65496]
        commands.append(command(0xffff0011, struct.pack('<IQI', handle, offset, len(chunk)) + chunk))
fixture = pathlib.Path(args.fixture).read_bytes()
assert 0 < len(fixture) < 60000
width, height = 64, 64
descriptor = struct.pack('<HBB', 9, 1, 0) + bytes(5132 - 4)
if args.strip_parameter_sets:
    fixture_parser = runpy.run_path(str(pathlib.Path(__file__).with_name('h264-fixture-descriptor.py')))
    descriptor, fixture, (width, height) = fixture_parser['descriptor_and_slices'](fixture)
resource(1, 2, 64, 10, width, height)
resource(2, 2, 64 if args.planar else 65, 10, width // 2, height // 2)
if args.planar:
    resource(5, 2, 64, 10, width // 2, height // 2)
resource(3, 0, 64, 1 << 17, len(descriptor))
resource(4, 0, 64, 1 << 17, len(fixture))
if args.early_backing:
    backing(1, bytes(width * height))
    backing(2, bytes(width * height // (4 if args.planar else 2)))
    if args.planar: backing(5, bytes(width * height // 4))
backing(3, descriptor)
backing(4, fixture)
def submit(opcode, words):
    body = struct.pack('<' + 'I' * (len(words) + 1), opcode | len(words) << 16, *words)
    commands.append(command(0x207, struct.pack('<II', len(body), 0) + body, context=7, flags=1, fence=42))
submit(53, [100, 9, 1, 1, 41, width, height, 1])
submit(55, [200, 165 if args.planar else 166, width, height, 1, 2] + ([5] if args.planar else []))
submit(57, [100, 200])
submit(59, [100, 200, 3, 4, len(fixture) + (1 if args.invalid_buffer_size else 0)])
invalid_index = len(commands) - 1
submit(61, [100, 200])
planes = [(1, width, height, width), (2, width // 2, height // 2, width // 2 if args.planar else width)]
if args.planar:
    planes.append((5, width // 2, height // 2, width // 2))
read_indices = []
for handle, width, height, stride in planes:
    if not args.early_backing:
        backing(handle, bytes(stride * height))
    read_handle = handle
    if args.copy_readback:
        read_handle = handle + 20
        resource(read_handle, 0, 64, 1 << 19, stride * height)
        backing(read_handle, bytes(stride * height))
        submit(45, [handle, 0, 0, stride, stride * height, 0, 0, 0, width, height, 1, read_handle, 0, 3])
    elif args.encoded_readback:
        submit(43, [handle, 0, 0, stride, stride * height, 0, 0, 0, width, height, 1, 0, 2])
    else:
        commands.append(command(0x206, struct.pack('<6IQ4I', 0, 0, 0, width, height, 1, 0, handle, 0, stride, stride * height), context=7, flags=1, fence=43))
    read_indices.append(len(commands))
    commands.append(command(0xffff0012, struct.pack('<IQI', read_handle, 0, 4)))
if args.invalid_buffer_size:
    commands = commands[:invalid_index + 1]
stream = b''.join(struct.pack('<I', len(c)) + c for c in commands)
process = subprocess.run([args.helper, '--worker'], input=stream, capture_output=True, timeout=30)
print(process.stderr.decode(errors='replace'))
assert process.returncode == 0, process.returncode
output = process.stdout
replies = []
while output:
    length = struct.unpack_from('<I', output)[0]
    replies.append(output[4:4+length]); output = output[4+length:]
assert len(replies) == len(commands), len(replies)
for index, reply in enumerate(replies):
    result = struct.unpack_from('<I', reply)[0]
    expected = 0x1200 if args.invalid_buffer_size and index in (invalid_index, invalid_index + 1) else 0x1100
    assert result == expected, (index, hex(struct.unpack_from('<I', commands[index])[0]), hex(result))
if args.invalid_buffer_size:
    print('PASS: oversized guest compressed-buffer read rejected before decode')
    raise SystemExit(0)
samples = [replies[i][24:28] for i in read_indices]
y, uv = samples[:2]
v = samples[2][0] if args.planar else uv[1]
assert y and 55 <= y[0] <= 95 and uv and 75 <= uv[0] <= 115 and v >= 225, [list(p) for p in samples]
print('PASS: guest VirGL H.264 opcodes -> hardware VideoToolbox -> Metal video planes; red fixture verified', [list(p) for p in samples])
