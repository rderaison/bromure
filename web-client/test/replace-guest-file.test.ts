import { describe, it, expect } from 'vitest';
import { replaceGuestFile } from '../src/core/remote/chunkedWrite';

// Regression (CWE-73): a dropped file was streamed straight onto its
// destination — the first write truncated a file already there, so a source
// read failing later left it replaced by a prefix. Now the bytes land in a
// temp file beside it, renamed over the destination only once complete.

const enc = (b: Uint8Array) => String(b.length);

/** A tiny guest: files as strings of chunk sizes, plus the op log. */
function guest(opts: { rename?: 'ok' | 'unknown' | 'fail' } = {}) {
  const files = new Map<string, string>([['/home/ubuntu/notes.txt', 'ORIGINAL']]);
  const ops: string[] = [];
  const op = async (o: Record<string, any>) => {
    ops.push(`${o.op} ${o.path}${o.dest ? ' -> ' + o.dest : ''}`);
    if (o.op === 'write') files.set(o.path, (o.append ? files.get(o.path) ?? '' : '') + `[${o.data}]`);
    else if (o.op === 'remove') files.delete(o.path);
    else if (o.op === 'rename') {
      if (opts.rename === 'unknown') throw new Error("unknown file op 'rename'");
      if (opts.rename === 'fail') throw new Error('Permission denied');
      files.set(o.dest, files.get(o.path)!); files.delete(o.path);
    }
  };
  return { files, ops, op };
}
const bytes = (n: number) => () => new Blob([new Uint8Array(n)]).stream();
function failingAfter(good: number) {
  return () => {
    let sent = false;
    return new ReadableStream<Uint8Array>({
      pull(c) { if (!sent) { sent = true; c.enqueue(new Uint8Array(good)); } else c.error(new DOMException('The file could not be read.', 'NotReadableError')); },
    });
  };
}
const DEST = '/home/ubuntu/notes.txt';

describe('replaceGuestFile', () => {
  it('a source read failing mid-copy leaves the existing file untouched (and no temp file)', async () => {
    const g = guest();
    await expect(replaceGuestFile(failingAfter(10), DEST, 4, g.op, enc)).rejects.toThrow('could not be read');
    expect(g.files.get(DEST)).toBe('ORIGINAL');
    expect([...g.files.keys()]).toEqual([DEST]);
    expect(g.ops.some(o => o.startsWith('write ' + DEST))).toBe(false);          // never written directly
  });

  it('a complete copy replaces the file in one rename', async () => {
    const g = guest();
    expect(await replaceGuestFile(bytes(10), DEST, 4, g.op, enc)).toBe(10);
    expect(g.files.get(DEST)).toBe('[4][4][2]');
    expect([...g.files.keys()]).toEqual([DEST]);
    const tmp = g.ops[0].slice('write '.length);
    expect(tmp).toMatch(/^\/home\/ubuntu\/\.notes\.txt\.bromure-[0-9a-f-]+\.part$/);  // beside it: same filesystem
    expect(g.ops.at(-1)).toBe(`rename ${tmp} -> ${DEST}`);
  });

  it('a refused rename leaves the file untouched and removes the temp file', async () => {
    const g = guest({ rename: 'fail' });
    await expect(replaceGuestFile(bytes(10), DEST, 4, g.op, enc)).rejects.toThrow('Permission denied');
    expect(g.files.get(DEST)).toBe('ORIGINAL');
    expect([...g.files.keys()]).toEqual([DEST]);
  });

  it('a guest too old for rename gets the direct write it always had', async () => {
    const g = guest({ rename: 'unknown' });
    expect(await replaceGuestFile(bytes(10), DEST, 4, g.op, enc)).toBe(10);
    expect(g.files.get(DEST)).toBe('[4][4][2]');
    expect([...g.files.keys()]).toEqual([DEST]);
  });

  // CWE-362: two drops of the same name overlap; B finishes while A is
  // part-way, then A's source fails. A's cleanup must never remove `dest` —
  // it's B's finished file. (Each copy's temp name is its own, so A only
  // ever deletes its temp; the next test is the path that used to delete.)
  for (const rename of ['ok', 'unknown'] as const) {
    it(`a failed copy never deletes a concurrent copy's finished file (rename ${rename})`, async () => {
      const g = guest({ rename });
      let release!: () => void;
      const bDone = new Promise<void>(r => { release = r; });
      // A: one chunk, then waits for B to land, then the source fails.
      const a = () => {
        let step = 0;
        return new ReadableStream<Uint8Array>({
          async pull(c) {
            if (step++ === 0) { c.enqueue(new Uint8Array(4)); return; }
            await bDone;
            c.error(new DOMException('The file could not be read.', 'NotReadableError'));
          },
        });
      };
      const pA = replaceGuestFile(a, DEST, 4, g.op, enc).catch(e => e);
      await new Promise(r => setTimeout(r, 0));
      expect(await replaceGuestFile(bytes(6), DEST, 4, g.op, enc)).toBe(6);   // B
      const bContent = g.files.get(DEST);
      release();
      expect(await pA).toBeInstanceOf(Error);
      expect(g.files.get(DEST)).toBe(bContent);                                 // B's file survives
      expect(g.ops).not.toContain(`remove ${DEST}`);
    });
  }

  // Regression (CWE-362): on a guest too old for `rename` the copy falls back
  // to writing `dest` directly — and its failure cleanup removed `dest`,
  // i.e. possibly another drop's finished file. That path no longer cleans up.
  it('an old guest: a direct-write fallback that fails leaves dest for whoever wrote it last', async () => {
    const g = guest({ rename: 'unknown' });
    let opens = 0;
    // First open (the temp copy) completes; the second (the direct write onto
    // dest) fails after one chunk.
    const open = () => opens++ === 0 ? bytes(8)() : failingAfter(4)();
    await expect(replaceGuestFile(open, DEST, 4, g.op, enc)).rejects.toThrow('could not be read');
    expect(g.ops).not.toContain(`remove ${DEST}`);                              // dest isn't this copy's to delete
  });
});

