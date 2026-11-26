import { describe, it, expect } from 'vitest';
import { replaceGuestFile, permissionDenied } from '../src/core/remote/chunkedWrite';

// Regression (CWE-73): a dropped file was streamed straight onto its
// destination — the first write truncated a file already there, so a source
// read failing later left it replaced by a prefix. Now the bytes land in a
// temp file beside it, renamed over the destination only once complete.

const enc = (b: Uint8Array) => String(b.length);

/** A tiny guest: files as strings of chunk sizes, plus the op log. */
function guest(opts: { rename?: 'ok' | 'unknown' | 'fail';
                      /** Refuse CREATING any file here, as a non-writable
                       *  directory does — writes to files already present
                       *  still succeed, which is the whole point. */
                      roDir?: string;
                      /** Refuse the Nth write (1-based), to prove a denial
                       *  part-way through does NOT become a direct write. */
                      denyWriteNo?: number } = {}) {
  const files = new Map<string, string>([['/home/ubuntu/notes.txt', 'ORIGINAL']]);
  const ops: string[] = [];
  let writes = 0;
  const op = async (o: Record<string, any>) => {
    ops.push(`${o.op} ${o.path}${o.dest ? ' -> ' + o.dest : ''}`);
    if (o.op === 'write') {
      writes += 1;
      const dir = o.path.slice(0, o.path.lastIndexOf('/'));
      if (opts.roDir === dir && !files.has(o.path)) {
        throw new Error(`[Errno 13] Permission denied: '${o.path}'`);
      }
      if (opts.denyWriteNo === writes) {
        throw new Error(`[Errno 13] Permission denied: '${o.path}'`);
      }
    }
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

  // A user can hold write access to a FILE without write access to its
  // directory — a group-writable file in someone else's home is the ordinary
  // case. Creating the temp sibling is denied there, while the direct write
  // this replaced succeeded, so the upload must still go through.
  it('a non-writable directory falls back to the direct write', async () => {
    const g = guest({ roDir: '/home/ubuntu' });
    expect(await replaceGuestFile(bytes(10), DEST, 4, g.op, enc)).toBe(10);
    expect(g.files.get(DEST)).toBe('[4][4][2]');
    expect([...g.files.keys()]).toEqual([DEST]);          // no temp file left
    // It tried the atomic path first, and only then wrote directly.
    expect(g.ops[0]).toMatch(/^write \/home\/ubuntu\/\.notes\.txt\.bromure-/);
    expect(g.ops.filter(o => o === `write ${DEST}`).length).toBe(3);
    expect(g.ops.some(o => o.startsWith('rename'))).toBe(false);  // never got that far
  });

  // The narrowness matters more than the fallback. writeGuestFile removes the
  // file it created when a copy fails — on the direct path that file is DEST,
  // so falling back after a partial write would delete the user's file
  // instead of leaving it alone.
  it('a denial PART-WAY through does not become a direct write', async () => {
    const g = guest({ denyWriteNo: 2 });
    await expect(replaceGuestFile(bytes(10), DEST, 4, g.op, enc)).rejects.toThrow('Permission denied');
    expect(g.files.get(DEST)).toBe('ORIGINAL');           // untouched
    expect([...g.files.keys()]).toEqual([DEST]);           // temp file cleaned up
    expect(g.ops.some(o => o === `write ${DEST}`)).toBe(false);
  });

  // The direct write is not atomic, but a failure part-way through it must
  // not remove the destination either: that file is the user's own.
  it('a direct write failing part-way keeps the destination (never removed)', async () => {
    const g = guest({ roDir: '/home/ubuntu', denyWriteNo: 3 });
    await expect(replaceGuestFile(bytes(10), DEST, 4, g.op, enc)).rejects.toThrow('Permission denied');
    expect(g.files.has(DEST)).toBe(true);
    expect(g.ops.some(o => o === `remove ${DEST}`)).toBe(false);
  });

  // A refused RENAME must keep its existing behaviour: the destination is
  // left alone and the error surfaces. It must not be mistaken for the
  // directory case just because it also says "Permission denied".
  it('a refused rename still propagates, not falls back', async () => {
    const g = guest({ rename: 'fail' });
    await expect(replaceGuestFile(bytes(10), DEST, 4, g.op, enc)).rejects.toThrow('Permission denied');
    expect(g.files.get(DEST)).toBe('ORIGINAL');
    expect(g.ops.filter(o => o === `write ${DEST}`).length).toBe(0);
  });
});

describe('permissionDenied', () => {
  it('reads the refusal from the message, not from the path it names', () => {
    expect(permissionDenied(new Error("[Errno 13] Permission denied: '/d/.f.bromure-1.part'"))).toBe(true);
    expect(permissionDenied(new Error("[Errno 1] Operation not permitted: '/d/x'"))).toBe(true);
    expect(permissionDenied('Permission denied')).toBe(true);
    expect(permissionDenied(new Error("[Errno 28] No space left on device: '/d/permission-denied.txt'"))).toBe(false);
    expect(permissionDenied(new Error("[Errno 130] Owner died: '/d/x'"))).toBe(false);
  });
});
