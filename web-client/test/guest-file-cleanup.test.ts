import { describe, it, expect } from 'vitest';
import { writeGuestFile } from '../src/core/remote/chunkedWrite';

// Regression (CWE-459): a folder drop streams its .tgz into the guest's /tmp
// as members are read; a member failing mid-way left the partial archive
// there. Any partial guest file is now removed when the copy fails.

const enc = (b: Uint8Array) => String(b.length);
function guest(failWriteAt = -1) {
  const ops: string[] = [];
  let writes = 0;
  const op = async (o: Record<string, unknown>) => {
    if (o.op === 'write' && writes++ === failWriteAt) { ops.push('write!'); throw new Error('guest refused'); }
    ops.push(`${o.op}${o.op === 'write' ? (o.append ? '+' : '') : ''} ${o.path}`);
  };
  return { ops, op };
}
/** A stream that yields `good` bytes, then fails like an unreadable File. */
function failingSource(good: number): ReadableStream<Uint8Array> {
  let sent = false;
  return new ReadableStream({
    pull(c) {
      if (!sent) { sent = true; c.enqueue(new Uint8Array(good)); return; }
      c.error(new DOMException('The file could not be read.', 'NotReadableError'));
    },
  });
}

describe('writeGuestFile', () => {
  it('removes the partial file when the source fails after a chunk reached the guest', async () => {
    const g = guest();
    await expect(writeGuestFile(failingSource(10), '/tmp/a.tgz', 4, g.op, enc)).rejects.toThrow('could not be read');
    expect(g.ops).toEqual(['write /tmp/a.tgz', 'write+ /tmp/a.tgz', 'remove /tmp/a.tgz']);
  });

  it('removes it when a later write is refused', async () => {
    const g = guest(1);
    await expect(writeGuestFile(new Blob([new Uint8Array(10)]).stream(), '/x', 4, g.op, enc)).rejects.toThrow('guest refused');
    expect(g.ops).toEqual(['write /x', 'write!', 'remove /x']);
  });

  it('removes nothing when the very first write failed (a file already there stays)', async () => {
    const g = guest(0);
    await expect(writeGuestFile(new Blob([new Uint8Array(10)]).stream(), '/home/ubuntu/keep.txt', 4, g.op, enc)).rejects.toThrow();
    expect(g.ops).toEqual(['write!']);
  });

  it('a gzip archive whose source fails after the guest got data leaves nothing in /tmp', async () => {
    // The folder-drop pipeline's shape: a source read lazily, through gzip,
    // into the guest — the source failing only once chunks have gone in.
    const g = guest();
    let reads = 0;
    const source = new ReadableStream<Uint8Array>({
      pull(c) {
        if (g.ops.length > 0 || reads > 400) { c.error(new DOMException('The file could not be read.', 'NotReadableError')); return; }
        reads++; c.enqueue(crypto.getRandomValues(new Uint8Array(32 * 1024)));   // incompressible
      },
    });
    const archive = (source as ReadableStream<any>).pipeThrough(new CompressionStream('gzip')) as ReadableStream<Uint8Array>;
    await expect(writeGuestFile(archive, '/tmp/bromure-drop-X.tgz', 64 * 1024, g.op, enc)).rejects.toThrow();
    expect(g.ops[0]).toBe('write /tmp/bromure-drop-X.tgz');                    // chunks reached the guest first
    expect(g.ops.at(-1)).toBe('remove /tmp/bromure-drop-X.tgz');
  });

  it('a successful copy removes nothing', async () => {
    const g = guest();
    expect(await writeGuestFile(new Blob([new Uint8Array(10)]).stream(), '/y', 4, g.op, enc)).toBe(10);
    expect(g.ops.every(o => o.startsWith('write'))).toBe(true);
  });
});
