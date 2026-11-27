// A socket's events for the renderer, held until it has claimed the socket.
//
// A socket from tcp:open or an accepted loopback connection reaches the
// renderer as an id before its stream exists. Its bytes are held by not
// reading the socket (no 'data' listener until tcp:resume); this holds the
// rest — a close or error that comes first — and sends it on resume, in order.
// So the renderer never sees an event for an id it doesn't know yet, needs no
// early-event store, and can drop anything for an unknown id (the close that
// follows a stream it already finished) instead of keeping it forever.

export type TcpEventSend = (kind: 'data' | 'close' | 'error', data?: Uint8Array | null, message?: string) => void;

export function heldEvents(send: TcpEventSend) {
  let open = false;
  const held: Parameters<TcpEventSend>[] = [];
  return {
    /** Send now if the renderer has resumed the socket, else hold it. */
    emit: (...ev: Parameters<TcpEventSend>) => { if (open) send(...ev); else held.push(ev); },
    /** The renderer claimed the socket: what was held, then live. */
    resume: () => { if (open) return; open = true; for (const ev of held.splice(0)) send(...ev); },
  };
}
