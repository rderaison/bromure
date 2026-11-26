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
                                     progress?: (sent: number) => void): Promise<number> {
  let created = false;
  try {
    return await writeDirect(stream, path, chunk, fileOp, encode, progress, () => { created = true; });
  } catch (e) {
    if (created) await fileOp({ op: 'remove', path }).catch(() => {});
    throw e;
  }
}

/** The chunked writes alone — no cleanup: for a path this copy doesn't own. */
function writeDirect(stream: ReadableStream<Uint8Array>, path: string, chunk: number,
                     fileOp: GuestFileOp, encode: (b: Uint8Array) => string,
                     progress?: (sent: number) => void, wrote?: () => void): Promise<number> {
  return writeStreamChunked(stream, chunk, async (bytes, append) => {
    await fileOp({ op: 'write', path, data: encode(bytes), append }, 60);
    wrote?.();
  }, progress);
}

/** The guest agent's answer when it predates an op (bromure-agentd.py). */
const unknownOp = (e: unknown) => /unknown file op/i.test(String((e as any)?.message ?? e));

/** Copy a dropped file OVER `dest` without ever leaving it half-written: the
 *  bytes go to a hidden temp file beside it, which replaces `dest` in one
 *  atomic step (`rename`) only once the whole source was read and written. A
 *  copy that fails part-way — the source became unreadable, a write was
 *  refused — leaves `dest` exactly as it was and removes the temp file.
 *  A guest too old for `rename` gets the direct write it always had, with no
 *  cleanup (`open` is called again for that: a File can be read twice). */
export async function replaceGuestFile(open: () => ReadableStream<Uint8Array>, dest: string, chunk: number,
                                       fileOp: GuestFileOp, encode: (b: Uint8Array) => string,
                                       progress?: (sent: number) => void): Promise<number> {
  const cut = dest.lastIndexOf('/');
  const tmp = `${dest.slice(0, cut + 1)}.${dest.slice(cut + 1)}.bromure-${crypto.randomUUID()}.part`;
  const sent = await writeGuestFile(open(), tmp, chunk, fileOp, encode, progress);
  try {
    await fileOp({ op: 'rename', path: tmp, dest });
    return sent;
  } catch (e) {
    await fileOp({ op: 'remove', path: tmp }).catch(() => {});
    if (!unknownOp(e)) throw e;
  }
  // Straight onto `dest`, as such a guest always got it — and without the
  // cleanup: `dest` isn't this copy's to delete (another drop of the same
  // name may have finished there meanwhile), as FolderUpload.write on macOS.
  return writeDirect(open(), dest, chunk, fileOp, encode, progress);
}
