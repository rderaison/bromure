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
                      denyWriteNo?: number;
                      /** Fail the Nth write with ENOSPC, path double-quoted
                       *  as Python does when it holds an apostrophe. */
                      noSpaceNo?: number;
                      dest?: string } = {}) {
  const files = new Map<string, string>([[opts.dest ?? '/home/ubuntu/notes.txt', 'ORIGINAL']]);
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
      if (opts.noSpaceNo === writes) {
        throw new Error(`[Errno 28] No space left on device: "${o.path}"`);
      }
    }
    if (o.op === 'read') {
      // Its size: the chunk sizes it holds (an unbracketed fixture, its length).
      const f = files.get(o.path);
      if (f === undefined) throw new Error(`[Errno 2] No such file or directory: '${o.path}'`);
      const parts = [...f.matchAll(/\[(\d+)\]/g)].map(m => Number(m[1]));
      return { size: parts.length ? parts.reduce((a, b) => a + b, 0) : f.length };
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
    expect(tmp).toMatch(/^\/home\/ubuntu\/\.bromure-[0-9a-f-]{36}\.part$/);  // beside it: same filesystem
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
    expect(g.ops[0]).toMatch(/^write \/home\/ubuntu\/\.bromure-/);
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

  // Regression: the temp name was `.<name>.bromure-<uuid>.part` — 51 bytes
  // more than the name, so a valid name over ~204 bytes made the first write
  // fail with ENAMETOOLONG on a 255-byte-component filesystem.
  it('a long (valid) name still gets a temp name within the 255-byte limit', async () => {
    const g = guest();
    const dest = '/home/ubuntu/' + 'n'.repeat(250);
    expect(await replaceGuestFile(bytes(3), dest, 4, g.op, enc)).toBe(3);
    const tmp = g.ops[0].slice('write '.length);
    expect(new TextEncoder().encode(tmp.slice(tmp.lastIndexOf('/') + 1)).length).toBeLessThanOrEqual(255);
    expect(tmp.startsWith('/home/ubuntu/.bromure-')).toBe(true);
    expect(g.files.has(dest)).toBe(true);
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

  // Regression (CWE-362): on that path a NEW destination the failed copy
  // created was removed when its size still matched the bytes written — but
  // another drop may have finished there since with that very size (both
  // empty, say). A guest this old can't tell files apart: nothing is removed.
  const NEW = '/home/ubuntu/new.txt';
  it('an old guest: a new file the direct write fails to fill stays (never removed by path)', async () => {
    const g = guest({ rename: 'unknown' });
    let opens = 0;
    const open = () => opens++ === 0 ? bytes(8)() : failingAfter(4)();
    await expect(replaceGuestFile(open, NEW, 4, g.op, enc)).rejects.toThrow('could not be read');
    expect(g.ops).not.toContain(`remove ${NEW}`);
    expect(g.files.get(NEW)).toBe('[4]');                                       // incomplete, and said so
  });

  it('an old guest: another drop finished at the same name with the same size is not removed', async () => {
    const g = guest({ rename: 'unknown' });
    let opens = 0;
    const open = () => {
      if (opens++ === 0) return bytes(8)();
      let step = 0;
      return new ReadableStream<Uint8Array>({
        pull(c) {
          if (step++ === 0) { c.enqueue(new Uint8Array(4)); return; }
          g.files.set(NEW, '[4]');                                             // the other drop: same size, finished
          c.error(new DOMException('The file could not be read.', 'NotReadableError'));
        },
      });
    };
    await expect(replaceGuestFile(open, NEW, 4, g.op, enc)).rejects.toThrow('could not be read');
    expect(g.files.get(NEW)).toBe('[4]');
    expect(g.ops).not.toContain(`remove ${NEW}`);
  });

  it('an old guest: a new file another drop wrote over meanwhile is not removed', async () => {
    const g = guest({ rename: 'unknown' });
    let opens = 0;
    const open = () => {
      if (opens++ === 0) return bytes(8)();
      let step = 0;
      return new ReadableStream<Uint8Array>({
        pull(c) {
          if (step++ === 0) { c.enqueue(new Uint8Array(4)); return; }
          g.files.set(NEW, '[100]');                                           // the other drop finished
          c.error(new DOMException('The file could not be read.', 'NotReadableError'));
        },
      });
    };
    await expect(replaceGuestFile(open, NEW, 4, g.op, enc)).rejects.toThrow('could not be read');
    expect(g.files.get(NEW)).toBe('[100]');
    expect(g.ops).not.toContain(`remove ${NEW}`);
  });
});

// Regression (CWE-20): ENOSPC creating the temp file, its path double-quoted
// (it holds an apostrophe) and naming a "permission denied's" folder, read as
// a refusal: the fallback then wrote straight onto the destination, whose
// first write truncates it.
describe('replaceGuestFile: a non-refusal error is never a direct write', () => {
  // The fallback the anchored check must keep: through an older host the
  // refusal arrives wrapped, and a writable file in a directory the guest
  // can't create a sibling in must still upload.
  it("an older host's wrapped refusal still falls back to the direct write", async () => {
    const g = guest({ roDir: '/home/ubuntu' });
    const wrapped: typeof g.op = async o => {
      try { return await g.op(o); }
      catch (e: any) { throw new Error(`commandFailed(exitCode: 1, stderr: "${String(e.message).replace(/'/g, "\\'")}")`); }
    };
    expect(await replaceGuestFile(bytes(10), DEST, 4, wrapped, enc)).toBe(10);
    expect(g.files.get(DEST)).toBe('[4][4][2]');
  });

  it("ENOSPC under a folder named permission denied's leaves the destination untouched", async () => {
    const dest = "/home/permission denied's/notes.txt";
    const g = guest({ noSpaceNo: 1, dest });
    await expect(replaceGuestFile(bytes(10), dest, 4, g.op, enc)).rejects.toThrow('No space left');
    expect(g.files.get(dest)).toBe('ORIGINAL');
    expect(g.ops.some(o => o === `write ${dest}`)).toBe(false);
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

  // Regression (CWE-20): the parser cut the message at `: '`, but Python
  // quotes a path holding an apostrophe with ", so the path stayed in and its
  // words counted: ENOSPC on `permission denied's.txt` read as a refusal.
  it("a double-quoted path's words never make a refusal", () => {
    expect(permissionDenied(new Error(`[Errno 28] No space left on device: "/d/.permission denied's.txt.bromure-abc.part"`))).toBe(false);
    expect(permissionDenied(new Error(`[Errno 5] Input/output error: "/d/[Errno 13] it's"`))).toBe(false);
    expect(permissionDenied(new Error('unknown file op: Operation not permitted'))).toBe(false);
    expect(permissionDenied(new Error(`[Errno 13] Permission denied: "/d/.it's.bromure-1.part"`))).toBe(true);
    expect(permissionDenied(new Error('Operation not permitted'))).toBe(true);   // a Sidecar Mac (strerror)
  });

  // What an older Mac host puts on the wire for a VM guest's error: Swift's
  // String(describing:) of GuestExecError.commandFailed, its quotes escaped.
  it("reads a guest's error inside an older host's enum dump, by its start only", () => {
    expect(permissionDenied(new Error(String.raw`commandFailed(exitCode: 1, stderr: "[Errno 13] Permission denied: '/d/.bromure-1.part'")`))).toBe(true);
    expect(permissionDenied(new Error(String.raw`commandFailed(exitCode: 1, stderr: "[Errno 1] Operation not permitted: '/d/x'")`))).toBe(true);
    expect(permissionDenied(new Error(String.raw`commandFailed(exitCode: 1, stderr: "[Errno 28] No space left on device: "/home/permission denied's/.bromure-1.part"")`))).toBe(false);
    expect(permissionDenied(new Error(String.raw`commandFailed(exitCode: 1, stderr: "[Errno 5] Input/output error: "/d/[Errno 13] x"")`))).toBe(false);
    expect(permissionDenied(new Error('connectionFailed'))).toBe(false);
  });
});

// Regression (CWE-200): the staging file was created with the guest's
// default mode (0644) and only took the destination's (perhaps 0600) at the
// rename, readable by others while a large upload filled it. Its first write
// now asks for an owner-only file.
describe('replaceGuestFile staging is owner-only', () => {
  it('the first write of the temp file is `staged`, the appends and the rename are not', async () => {
    const seen: Record<string, any>[] = [];
    const op = async (o: Record<string, any>) => { seen.push(o); };
    await replaceGuestFile(bytes(3000), DEST, 1024, op, enc);
    const writes = seen.filter(o => o.op === 'write');
    expect(writes.length).toBeGreaterThan(1);
    expect(writes[0].staged).toBe(true);
    expect(writes[0].append).toBe(false);
    expect(writes.slice(1).every(o => !('staged' in o))).toBe(true);
    expect(seen.find(o => o.op === 'rename')?.staged).toBeUndefined();
  });

  it('the old-guest fallback writes the destination directly, not staged', async () => {
    const seen: Record<string, any>[] = [];
    const op = async (o: Record<string, any>) => { seen.push(o); if (o.op === 'rename') throw new Error("unknown file op 'rename'"); };
    await replaceGuestFile(bytes(10), DEST, 1024, op, enc);
    const direct = seen.filter(o => o.op === 'write' && o.path === DEST);
    expect(direct.length).toBe(1);
    expect(direct[0].staged).toBeUndefined();
  });
});
