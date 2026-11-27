// Copy a byte stream into a guest file in bounded pieces (the guest file
// service takes one `write` per request: the first creates/truncates, the
// rest append). Only one piece is held at a time, so a dropped file or folder
// archive of any size never sits whole in renderer memory.

/** Send `stream` as pieces of at most `chunk` bytes; `send(bytes, append)` is
 *  called once per piece, in order, and at least once (an empty source still
 *  creates the file). Returns the byte count. */
export async function writeStreamChunked(
  stream: ReadableStream<Uint8Array>, chunk: number,
  send: (bytes: Uint8Array, append: boolean) => Promise<void>,
  progress?: (sent: number) => void,
): Promise<number> {
  const reader = stream.getReader();
  const buf = new Uint8Array(chunk);
  let fill = 0, sent = 0, first = true;
  const flush = async () => {
    await send(buf.slice(0, fill), !first);
    sent += fill; fill = 0; first = false;
    progress?.(sent);
  };
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      let off = 0;
      while (off < value.length) {
        const n = Math.min(chunk - fill, value.length - off);
        buf.set(value.subarray(off, off + n), fill);
        fill += n; off += n;
        if (fill === chunk) await flush();
      }
    }
    if (fill > 0 || first) await flush();
    return sent;
  } catch (e) {
    reader.cancel(e).catch(() => {});
    throw e;
  } finally {
    reader.releaseLock();
  }
}

/** A guest file-service call (`POST /vms/<id>/file`). */
export type GuestFileOp = (op: Record<string, unknown>, timeoutSec?: number) => Promise<unknown>;

/** Copy `stream` into the guest file `path` (writeStreamChunked). If the copy
 *  fails part-way — the source became unreadable, a write was refused — the
 *  partial file it created is removed before the error propagates: a dropped
 *  folder's half-written /tmp archive or a temp file never stays behind.
 *  A copy that failed before its first write touched nothing, so nothing is
 *  removed.
 *
 *  `path` MUST be this copy's own: a fresh, unique name nothing else writes
 *  (a temp or archive name with a UUID). The cleanup deletes whatever is at
 *  `path`, so on a shared name it would delete another, concurrent copy's
 *  finished file (CWE-362). To land a file on a name others may use, go
 *  through replaceGuestFile. */
export async function writeGuestFile(stream: ReadableStream<Uint8Array>, path: string, chunk: number,
                                     fileOp: GuestFileOp, encode: (b: Uint8Array) => string,
                                     progress?: (sent: number) => void, staged = false): Promise<number> {
  let created = false;
  try {
    return await writeDirect(stream, path, chunk, fileOp, encode, progress, () => { created = true; }, staged);
  } catch (e) {
    if (created) await fileOp({ op: 'remove', path }).catch(() => {});
    throw e;
  }
}

/** The chunked writes alone — no cleanup: for a path this copy doesn't own. */
function writeDirect(stream: ReadableStream<Uint8Array>, path: string, chunk: number,
                     fileOp: GuestFileOp, encode: (b: Uint8Array) => string,
                     progress?: (sent: number) => void, wrote?: () => void,
                     staged = false): Promise<number> {
  return writeStreamChunked(stream, chunk, async (bytes, append) => {
    // `staged`: an upload's staging file, created owner-only (CWE-200).
    await fileOp({ op: 'write', path, data: encode(bytes), append, ...(staged && !append ? { staged: true } : {}) }, 60);
    wrote?.();
  }, progress);
}

/** The guest agent's answer when it predates an op (bromure-agentd.py). */
const unknownOp = (e: unknown) => /unknown file op/i.test(String((e as any)?.message ?? e));

/** The filesystem refused: EPERM (1) or EACCES (13), read from the error's
 *  own shape, never from text that may hold a filename (CWE-20).
 *  - bromure-agentd.py's file ops end in `except Exception as e: return
 *    {"error": str(e)}`, so an OSError arrives as Python's own text, which
 *    STARTS with its errno: `[Errno 13] Permission denied: '/d/.f…'`. The
 *    path after it is quoted with ' or " (Python picks " when the name holds
 *    an apostrophe) and may say anything, "permission denied" included.
 *  - A Sidecar Mac (HostExec.swift) answers a refused write with strerror's
 *    text alone, `Permission denied` / `Operation not permitted`, no path.
 *  (A Mac host relays the guest's message as is; an older one wrapped it in
 *  an enum dump, whose fixed prefix is skipped.)
 *  Anything else (ENOSPC on a file named `permission denied's.txt`, an
 *  exception that merely mentions a path) is not a refusal: the direct-write
 *  fallback truncates the destination, so it must never run on a guess.
 *  Mirrors FolderUpload.refusedByFilesystem in Swift; keep the two in step. */
export const permissionDenied = (e: unknown) => {
  const text = String((e as any)?.message ?? e).trim();
  // A Mac host older than this check relays a VM guest's error as a Swift
  // enum dump, `commandFailed(exitCode: 1, stderr: "[Errno 13] …")`: a fixed
  // prefix, after which the guest's message starts as above.
  const guest = text.replace(GUEST_ERROR_DUMP, '');
  return /^\[errno (1|13)\] /i.test(guest) || /^(permission denied|operation not permitted)$/i.test(text);
};
const GUEST_ERROR_DUMP = /^commandFailed\(exitCode: -?\d+, stderr: "/;

/** Copy a dropped file OVER `dest` without ever leaving it half-written: the
 *  bytes go to a hidden temp file beside it, which replaces `dest` in one
 *  atomic step (`rename`) only once the whole source was read and written. A
 *  copy that fails part-way — the source became unreadable, a write was
 *  refused — leaves `dest` exactly as it was and removes the temp file.
 *  A guest too old for `rename` is refused (GuestTooOld) with `dest` never
 *  touched; a destination whose DIRECTORY we may not write gets a direct
 *  write — see below. */
export async function replaceGuestFile(open: () => ReadableStream<Uint8Array>, dest: string, chunk: number,
                                       fileOp: GuestFileOp, encode: (b: Uint8Array) => string,
                                       progress?: (sent: number) => void): Promise<number> {
  const cut = dest.lastIndexOf('/');
  // Fixed length, whatever the destination's name: a name near the 255-byte
  // component limit is valid, and must not become an invalid temp name.
  const tmp = `${dest.slice(0, cut + 1)}.bromure-${crypto.randomUUID()}.part`;
  let sent: number;
  // Did the guest accept a write to `tmp`? Only a write that SUCCEEDED counts,
  // so a refusal of the very first one — the create — leaves this false.
  let tmpCreated = false;
  try {
    // Owner-only while it fills (CWE-200): `dest` may be private. `rename`
    // gives it its final mode.
    sent = await writeGuestFile(open(), tmp, chunk, async (o, timeoutSec) => {
      const r = await fileOp(o, timeoutSec);
      if (o.op === 'write') tmpCreated = true;
      return r;
    }, encode, progress, true);
  } catch (e) {
    // Writing a file does not require write access to its directory, but
    // CREATING a sibling of it does. A group-writable file in someone else's
    // directory is the ordinary case: the direct write this replaced worked
    // there, so refusing the upload would be a regression.
    //
    // Narrow on purpose. Only when the guest refused AND nothing was written:
    // a denial part-way through must never become a direct write, because
    // writeGuestFile removes the file it created on failure — and on this
    // path that file is `dest` itself, so the user's existing file would be
    // deleted rather than left alone.
    if (tmpCreated || !permissionDenied(e)) throw e;
    console.warn(
      `[upload] ${dest}: cannot create a temp file in its directory (${
        String((e as any)?.message ?? e)}), so writing straight to it. ` +
      'This is NOT atomic: if the copy fails part-way the destination is lost.',
    );
    // Straight onto `dest`, and NOT through writeGuestFile: its clean-up on a
    // failed copy removes the file it wrote, which here is the user's own.
    return writeDirect(open(), dest, chunk, fileOp, encode, progress);
  }
  try {
    await fileOp({ op: 'rename', path: tmp, dest });
    return sent;
  } catch (e) {
    await fileOp({ op: 'remove', path: tmp }).catch(() => {});
    if (!unknownOp(e)) throw e;
  }
  throw new GuestTooOld(dest);
}

/** A guest without `rename` (its agent predates it: a Bromure host older
 *  than 2026-11-25 serves it): the upload is refused before anything is
 *  written to `dest`. Such a guest can only write `dest` in place, and a copy
 *  that failed part-way would leave a truncated file under the final name
 *  that looks like a finished upload (CWE-459); its path-only `remove` can't
 *  clean that up safely either, since another drop may have finished at the
 *  same name meanwhile (CWE-362). So it is never written: the user is told to
 *  update Bromure where the VM runs (its agent is re-staged at each start).
 *  Mirrors FolderUpload.guestTooOld. */
export class GuestTooOld extends Error {
  constructor(dest: string) {
    super(`Couldn't upload ${dest.slice(dest.lastIndexOf('/') + 1)}: the Bromure running this workspace is too old to replace files safely, so nothing was changed. Update Bromure on that Mac, restart the workspace's VM, and try again.`);
    this.name = 'GuestTooOld';
  }
}
