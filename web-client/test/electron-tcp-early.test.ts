import { describe, it, expect } from 'vitest';
import { ElectronTcpStream, type ElectronNetBridge } from '../src/core/net/stream';
import { heldEvents } from '../electron/tcpEvents';

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
