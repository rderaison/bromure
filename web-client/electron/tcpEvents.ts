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

/** The sockets main handed to a renderer as an id and that are still
 *  waiting for its tcp:resume, each with its owner (a document id).
 *
 *  Kept apart from the live-socket table on purpose: a socket that closes
 *  (a peer reset, a local client gone) before the renderer resumes it has
 *  left that table, but its held close / error must still reach the
 *  renderer, or its stream never ends (CWE-362). An entry goes once claimed,
 *  dropped by its owner, or when its owner (a document: documents()) is
 *  gone. */
export function resumeTable() {
  const pending = new Map<number, { owner: number; resume: () => void }>();
  return {
    hold(id: number, owner: number, resume: () => void) { pending.set(id, { owner, resume }); },
    /** The owner's tcp:resume: send what was held, then live. */
    claim(id: number, owner: number) {
      const p = pending.get(id);
      if (!p || p.owner !== owner) return false;
      pending.delete(id);
      p.resume();
      return true;
    },
    drop(id: number, owner: number) { if (pending.get(id)?.owner === owner) pending.delete(id); },
    dropOwner(owner: number) { for (const [id, p] of pending) if (p.owner === owner) pending.delete(id); },
    get size() { return pending.size; },
  };
}

/** Which document each webContents shows, as the owner of its sockets.
 *
 *  A reload or a renderer restart replaces the document but keeps the
 *  webContents (and its id), so owning by webContents kept the old
 *  document's sockets, listeners and pending resumes for the window's life:
 *  nothing left could claim or close them (CWE-401). The preload starts each
 *  document with tcp:reset (before any page script, on the same channel as
 *  its tcp calls), which gives it a new id and hands back the old one to
 *  release. */
export function documents() {
  const current = new Map<number, number>();
  let next = 1;
  return {
    /** The document `wc` shows now. */
    of(wc: number) {
      let d = current.get(wc);
      if (d === undefined) { d = next++; current.set(wc, d); }
      return d;
    },
    /** Whether `doc` is still the document `wc` shows. Checked when a
     *  socket arrives (a connect, an accept) or a listen completes for it:
     *  one that outlived its document is destroyed, not handed over. */
    isCurrent(wc: number, doc: number) { return current.get(wc) === doc; },
    /** `wc` started a new document: the one it replaces, if any. */
    reset(wc: number) { const old = current.get(wc); current.set(wc, next++); return old; },
    /** `wc` is destroyed: its last document, if any. */
    forget(wc: number) { const d = current.get(wc); current.delete(wc); return d; },
  };
}
