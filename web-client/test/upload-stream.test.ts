import { describe, it, expect, vi } from 'vitest';
import { writeStreamChunked } from '../src/core/remote/chunkedWrite';
import { tarGzStream } from '../src/features/machines/tar';

// Regression: dropped files and folder archives were read whole
// (`file.arrayBuffer()`) before being sent in chunks; they now stream, one
// chunk in memory at a time.

function bytes(n: number, seed = 1): Uint8Array {
  const b = new Uint8Array(n);
  for (let i = 0; i < n; i++) b[i] = (i * 31 + seed) & 0xff;
  return b;
}
/** A File whose arrayBuffer() fails: a whole-file read would break the test. */
function streamOnlyFile(data: Uint8Array, name: string): File {
  const f = new File([data as BlobPart], name, { lastModified: 1_700_000_000_000 });
  vi.spyOn(f, 'arrayBuffer').mockRejectedValue(new Error('whole-file read'));
  return f;
}
async function collect(stream: ReadableStream<Uint8Array>, chunk: number) {
  const calls: { len: number; append: boolean }[] = [];
  const parts: Uint8Array[] = [];
  const total = await writeStreamChunked(stream, chunk, async (b, append) => { calls.push({ len: b.length, append }); parts.push(b); });
  const out = new Uint8Array(total);
  let o = 0; for (const p of parts) { out.set(p, o); o += p.length; }
  return { calls, out, total };
}

describe('writeStreamChunked', () => {
  it('sends a file in pieces of at most the chunk size, first write then appends', async () => {
    const data = bytes(10_000 + 123);
    const { calls, out } = await collect(streamOnlyFile(data, 'big.bin').stream(), 4096);
    expect(calls.map(c => c.len)).toEqual([4096, 4096, 1931]);
    expect(calls.map(c => c.append)).toEqual([false, true, true]);
    expect(out).toEqual(data);
  });

  it('an exact multiple of the chunk size ends without an empty write', async () => {
    const { calls } = await collect(new Blob([bytes(8192) as BlobPart]).stream(), 4096);
    expect(calls.map(c => c.len)).toEqual([4096, 4096]);
  });

  it('an empty file is still created (one empty, non-append write)', async () => {
    const { calls } = await collect(new Blob([]).stream(), 4096);
    expect(calls).toEqual([{ len: 0, append: false }]);
  });

  it('a failed write stops the copy and rejects', async () => {
    let n = 0;
    const p = writeStreamChunked(new Blob([bytes(20_000) as BlobPart]).stream(), 4096, async () => { if (++n === 2) throw new Error('guest said no'); });
    await expect(p).rejects.toThrow('guest said no');
    expect(n).toBe(2);
  });
});

describe('tarGzStream', () => {
  it('archives files without reading them whole, and round-trips', async () => {
    const a = bytes(700, 3), b = bytes(5000, 7);
    const gz = tarGzStream([
      { path: 'dir', dir: true },
      { path: 'dir/a.txt', file: streamOnlyFile(a, 'a.txt') },
      { path: 'b.bin', file: streamOnlyFile(b, 'b.bin') },
      { path: '../escape', file: streamOnlyFile(a, 'escape') },
    ]);
    const tar = new Uint8Array(await new Response((gz as ReadableStream<any>).pipeThrough(new DecompressionStream('gzip'))).arrayBuffer());
    const members: Record<string, Uint8Array | 'dir'> = {};
    const dec = new TextDecoder();
    for (let off = 0; off + 512 <= tar.length;) {
      const h = tar.subarray(off, off + 512);
      if (h.every(x => x === 0)) break;
      const name = dec.decode(h.subarray(0, 100)).replace(/\0.*$/s, '');
      const size = parseInt(dec.decode(h.subarray(124, 136)).replace(/\0.*$/s, '').trim() || '0', 8);
      off += 512;
      members[name] = h[156] === 0x35 ? 'dir' : tar.slice(off, off + size);
      off += Math.ceil(size / 512) * 512;
    }
    expect(Object.keys(members)).toEqual(['./dir/', './dir/a.txt', './b.bin']);
    expect(members['./dir/a.txt']).toEqual(a);
    expect(members['./b.bin']).toEqual(b);
  });
});
