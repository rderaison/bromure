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
