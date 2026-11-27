import { describe, it, expect } from 'vitest';
import { ElectronTcpStream, type ElectronNetBridge } from '../src/core/net/stream';
import { documents, heldEvents, resumeTable } from '../electron/tcpEvents';

// The renderer learns a socket's id from tcpOpen's reply (or tcp:accept)
// before its stream exists. Main holds the socket's bytes AND its close /
// error until the renderer resumes it, so the renderer never needs to store
// events for an id it doesn't know.
//
// Regressions: a renderer-side early-event store dropped events past 1,024
// (a truncated stream, a lost close), and stored main's close that follows a
// stream it had already finished — one entry per connection, forever (CWE-401).

// One bridge for the file: the stream wires its event handler once.
let emitter: (id: number, kind: any, data?: Uint8Array, message?: string) => void = () => {};
let nextID = 0;
const calls: string[] = [];
const bridge = {
  onTcpEvent: (cb: any) => { emitter = cb; },
  tcpOpen: async () => nextID,
  tcpWrite: () => {},
  tcpClose: (id: number) => { calls.push(`close ${id}`); },
  tcpResume: (id: number) => { calls.push(`resume ${id}`); },
} as unknown as ElectronNetBridge;
const tick = () => new Promise(r => setTimeout(r, 5));

describe('ElectronTcpStream', () => {
  it('resumes the socket only after open() returned and the handlers are set', async () => {
    calls.length = 0; nextID = 903;
    const s = await ElectronTcpStream.open(bridge, '127.0.0.1', 22);
    expect(calls).toEqual([]);                       // not yet: the caller is still wiring
    const got: number[] = [];
    s.onData = d => got.push(...d);
    await tick();
    expect(calls).toEqual(['resume 903']);
    emitter(903, 'data', new Uint8Array([1, 2]));
    expect(got).toEqual([1, 2]);
  });

  it('waits for the handlers however long the caller awaits first', async () => {
    // The tunnel's forward lane loaded the device key (IndexedDB) between the
    // dial and handing the stream to the SSH client: a resume on a timer let
    // the server's banner through to the default no-op handler.
    calls.length = 0; nextID = 905;
    const s = await ElectronTcpStream.open(bridge, '127.0.0.1', 22);
    await new Promise(r => setTimeout(r, 30));
    expect(calls).toEqual([]);                       // nothing resumed while the caller awaited
    const got: number[] = [];
    s.onData = d => got.push(...d);
    s.onClose = () => {};
    await tick();
    expect(calls).toEqual(['resume 905']);           // once, when the handlers came
    emitter(905, 'data', new Uint8Array([83, 83, 72]));
    expect(got).toEqual([83, 83, 72]);
  });

  it('events for an id with no stream are dropped, never stored (CWE-401)', async () => {
    nextID = 904;
    const s = await ElectronTcpStream.open(bridge, '127.0.0.1', 22);
    let closes = 0;
    s.onClose = () => { closes++; };
    s.close();                                       // finished on our side…
    for (let i = 0; i < 10_000; i++) emitter(904, 'close');   // …main's close(s) arrive after
    emitter(99_999, 'data', new Uint8Array([1]));    // and one for an id never opened
    expect(closes).toBe(1);
    // No store left behind on the class for stragglers to pile into.
    expect(Object.keys(ElectronTcpStream as any)).not.toContain('early');
    expect((ElectronTcpStream as any).early).toBeUndefined();
    expect((ElectronTcpStream as any).streams.has(904)).toBe(false);
  });
});

describe('heldEvents (main)', () => {
  it('holds a close or error until resume, then sends it in order; live afterwards', () => {
    const sent: string[] = [];
    const ev = heldEvents((k, d, m) => sent.push(`${k}${d ? ':' + d.length : ''}${m ? ':' + m : ''}`));
    ev.emit('error', null, 'reset');
    ev.emit('close');
    expect(sent).toEqual([]);                        // the renderer has no stream yet
    ev.resume();
    expect(sent).toEqual(['error:reset', 'close']);
    ev.emit('data', new Uint8Array(3));
    ev.resume();                                     // a second resume is a no-op
    expect(sent).toEqual(['error:reset', 'close', 'data:3']);
  });
});

// Regression (CWE-362): a socket that closed before the renderer's tcp:resume
// left main's socket table, and the resume (which required a live, owned
// socket) never ran, so its held close never reached the renderer. The
// renderer's stream stayed open forever, and so did the SSH channel of a
// loopback callback whose client gave up while the forward was opening.
describe('resumeTable (main)', () => {
  it('a close before resume is still delivered when the owner resumes', () => {
    const sent: string[] = [];
    const ev = heldEvents(k => sent.push(k));
    const t = resumeTable();
    t.hold(7, 1, () => ev.resume());
    ev.emit('error', null, 'ECONNRESET');
    ev.emit('close');                       // the socket is gone from main's table now
    expect(sent).toEqual([]);
    expect(t.claim(7, 2)).toBe(false);      // another window can't claim it
    expect(sent).toEqual([]);
    expect(t.claim(7, 1)).toBe(true);
    expect(sent).toEqual(['error', 'close']);
    expect(t.claim(7, 1)).toBe(false);      // once
    expect(t.size).toBe(0);
  });

  it('end to end: the renderer stream ends when main held the close', async () => {
    const t = resumeTable();
    const ev = heldEvents((k, d, m) => emitter(905, k, d ?? undefined, m));
    t.hold(905, 1, () => ev.resume());
    ev.emit('close');                       // peer reset before the renderer resumed
    const resumeBridge = { ...bridge, tcpResume: (id: number) => { t.claim(id, 1); } } as ElectronNetBridge;
    nextID = 905;
    const s = await ElectronTcpStream.open(resumeBridge, '127.0.0.1', 22);
    let closed = 0;
    s.onClose = () => { closed++; };
    await tick();
    expect(closed).toBe(1);
    expect((ElectronTcpStream as any).streams.has(905)).toBe(false);
  });

  it('pending entries go when dropped by their owner or when the owner is destroyed', () => {
    const t = resumeTable();
    t.hold(1, 1, () => {}); t.hold(2, 1, () => {}); t.hold(3, 2, () => {});
    t.drop(3, 1);                           // not its owner: kept
    expect(t.size).toBe(3);
    t.drop(1, 1);
    t.dropOwner(1);
    expect(t.size).toBe(1);
    expect(t.claim(3, 2)).toBe(true);
    expect(t.size).toBe(0);
  });
});

// Regression (CWE-401): sockets were owned by their webContents, and a reload
// keeps it. A socket that closed before resume kept its pending entry, which
// the new document can't know to claim or close, so each interrupted attempt
// plus a reload grew main's table for the window's life. Main now owns by
// document; the preload's tcp:reset hands back the old one to release.
describe('documents (main)', () => {
  it("a reload releases the old document's pending resumes, and repeated reloads don't grow the table", () => {
    const docs = documents(), t = resumeTable();
    for (let reload = 0; reload < 5; reload++) {
      const doc = docs.of(5);
      expect(docs.of(5)).toBe(doc);          // stable within a document
      const ev = heldEvents(() => {});
      t.hold(100 + reload, doc, () => ev.resume());
      ev.emit('close');                       // closed before its resume
      const old = docs.reset(5);              // the preload of the next document
      expect(old).toBe(doc);
      t.dropOwner(old!);
      expect(t.size).toBe(0);
      expect(t.claim(100 + reload, docs.of(5))).toBe(false);   // not the new document's
    }
  });

  // …and a socket that arrives for a released document (an accept Node had
  // already taken when release() closed the listener, a connect that
  // finished after the reload) is refused, not stored under the old id.
  it('a socket arriving after its document was released is refused', () => {
    const docs = documents();
    const before = docs.of(5);
    expect(docs.isCurrent(5, before)).toBe(true);
    docs.reset(5);                            // reload while a listen accept is in flight
    expect(docs.isCurrent(5, before)).toBe(false);
    expect(docs.isCurrent(5, docs.of(5))).toBe(true);
    const last = docs.of(5);
    docs.forget(5);                           // window closed
    expect(docs.isCurrent(5, last)).toBe(false);
  });

  it('documents are per window, and a destroyed window hands back its last one', () => {
    const docs = documents();
    const a = docs.of(1), b = docs.of(2);
    expect(a).not.toBe(b);
    expect(docs.reset(3)).toBeUndefined();    // a first document: nothing to release
    const c = docs.of(3);
    expect(docs.forget(1)).toBe(a);
    expect(docs.forget(1)).toBeUndefined();
    expect(docs.of(1)).not.toBe(a);           // ids are never reused
    expect(docs.of(3)).toBe(c);
  });
});
