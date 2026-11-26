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
 *  folder's half-written /tmp archive or a truncated file never stays behind.
 *  A copy that failed before its first write touched nothing, so nothing is
 *  removed (a file already there stays). */
export async function writeGuestFile(stream: ReadableStream<Uint8Array>, path: string, chunk: number,
                                     fileOp: GuestFileOp, encode: (b: Uint8Array) => string,
                                     progress?: (sent: number) => void): Promise<number> {
  let created = false;
  try {
    return await writeStreamChunked(stream, chunk, async (bytes, append) => {
      await fileOp({ op: 'write', path, data: encode(bytes), append }, 60);
      created = true;
    }, progress);
  } catch (e) {
    if (created) await fileOp({ op: 'remove', path }).catch(() => {});
    throw e;
  }
}

/** The guest agent's answer when it predates an op (bromure-agentd.py). */
const unknownOp = (e: unknown) => /unknown file op/i.test(String((e as any)?.message ?? e));

/** The filesystem refused. bromure-agentd.py's file ops end in
 *  `except Exception as e: return {"error": str(e)}`, so an OSError arrives as
 *  Python's own text — `[Errno 13] Permission denied: '/path/.f.bromure-…'`.
 *  Only the text before the path counts: a file named `permission-denied`
 *  that failed for another reason isn't a refusal. Mirrors
 *  FolderUpload.refusedByFilesystem in Swift; keep the two in step. */
export const permissionDenied = (e: unknown) =>
  /\[errno (1|13)\]|permission denied|operation not permitted/i
    .test(String((e as any)?.message ?? e).split(": '")[0]);

/** Copy a dropped file OVER `dest` without ever leaving it half-written: the
 *  bytes go to a hidden temp file beside it, which replaces `dest` in one
 *  atomic step (`rename`) only once the whole source was read and written. A
 *  copy that fails part-way — the source became unreadable, a write was
 *  refused — leaves `dest` exactly as it was and removes the temp file.
 *  A guest too old for `rename` gets the direct write it always had
 *  (`open` is called again for that: a File can be read twice), and so does a
 *  destination whose DIRECTORY we may not write — see below. */
export async function replaceGuestFile(open: () => ReadableStream<Uint8Array>, dest: string, chunk: number,
                                       fileOp: GuestFileOp, encode: (b: Uint8Array) => string,
                                       progress?: (sent: number) => void): Promise<number> {
  const cut = dest.lastIndexOf('/');
  const tmp = `${dest.slice(0, cut + 1)}.${dest.slice(cut + 1)}.bromure-${crypto.randomUUID()}.part`;
  let sent: number;
  // Did the guest accept a write to `tmp`? Only a write that SUCCEEDED counts,
  // so a refusal of the very first one — the create — leaves this false.
  let tmpCreated = false;
  try {
    sent = await writeGuestFile(open(), tmp, chunk, async (o, timeoutSec) => {
      const r = await fileOp(o, timeoutSec);
      if (o.op === 'write') tmpCreated = true;
      return r;
    }, encode, progress);
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
    return writeStreamChunked(open(), chunk, (bytes, append) =>
      fileOp({ op: 'write', path: dest, data: encode(bytes), append }, 60).then(() => {}), progress);
  }
  try {
    await fileOp({ op: 'rename', path: tmp, dest });
    return sent;
  } catch (e) {
    await fileOp({ op: 'remove', path: tmp }).catch(() => {});
    if (!unknownOp(e)) throw e;
  }
  return writeGuestFile(open(), dest, chunk, fileOp, encode, progress);
}
