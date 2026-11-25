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
