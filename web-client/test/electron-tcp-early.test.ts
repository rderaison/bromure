import { describe, it, expect } from 'vitest';
import { ElectronTcpStream, type ElectronNetBridge } from '../src/core/net/stream';

// Regression: main sends a socket's first bytes (an SSH server's banner) as
// soon as it connects, and that IPC event can beat tcpOpen's reply. They
// were dropped (no stream for the id yet), so the SSH client waited 25 s for
// a banner that had already come — the browser's / tunnel's forward lane
// failed with "no SSH banner".

// One bridge for the file: the stream wires its event handler once.
let emitter: (id: number, kind: any, data?: Uint8Array, message?: string) => void = () => {};
let nextOpen: { id: number; before: [string, Uint8Array?][] } = { id: 0, before: [] };
const bridge = {
  onTcpEvent: (cb: any) => { emitter = cb; },
  tcpOpen: async () => { const { id, before } = nextOpen; for (const [k, d] of before) emitter(id, k, d); return id; },
  tcpWrite: () => {},
  tcpClose: (id: number) => { calls.push(`close ${id}`); },
  tcpResume: (id: number) => { calls.push(`resume ${id}`); },
} as unknown as ElectronNetBridge;
const calls: string[] = [];
function fakeBridge(id: number, before: [string, Uint8Array?][]) {
  nextOpen = { id, before };
  return { bridge, emit: (k: string, d?: Uint8Array) => emitter(id, k as any, d) };
}

describe('ElectronTcpStream', () => {
  it('delivers bytes that arrived before tcpOpen resolved, in order, then the rest', async () => {
    const enc = (t: string) => new TextEncoder().encode(t);
    const { bridge, emit } = fakeBridge(901, [['data', enc('SSH-2.0-x\r\n')], ['data', enc('A')]]);
    const s = await ElectronTcpStream.open(bridge, '127.0.0.1', 22);
    const got: string[] = [];
    s.onData = d => got.push(new TextDecoder().decode(d));
    emit('data', enc('B'));                 // arrives while the early ones wait
    await new Promise(r => setTimeout(r, 5));
    emit('data', enc('C'));
    expect(got.join('')).toBe('SSH-2.0-x\r\nABC');
  });
  it('an early close still closes', async () => {
    const { bridge } = fakeBridge(902, [['data', new Uint8Array([1])], ['close']]);
    const s = await ElectronTcpStream.open(bridge, '127.0.0.1', 22);
    let closed = false; s.onClose = () => { closed = true; };
    await new Promise(r => setTimeout(r, 5));
    expect(closed).toBe(true);
  });

  // Main holds a new socket's bytes until the stream is claimed: the
  // renderer resumes it once its handlers are set.
  it('resumes the socket only after open() returned and the handlers are set', async () => {
    calls.length = 0;
    const { bridge } = fakeBridge(903, []);
    const s = await ElectronTcpStream.open(bridge, '127.0.0.1', 22);
    expect(calls).toEqual([]);                       // not yet: the caller is still wiring
    s.onData = () => {};
    await new Promise(r => setTimeout(r, 5));
    expect(calls).toEqual(['resume 903']);
  });

  // Regression: past 1,024 early events the rest — data, error, close — were
  // silently dropped, so SSH saw a truncated stream or waited forever for a
  // close. Now an overflow fails the stream and closes the socket.
  it('more early events than it keeps fails the stream loudly instead of truncating it', async () => {
    calls.length = 0;
    const many: [string, Uint8Array?][] = Array.from({ length: 5000 }, () => ['data', new Uint8Array([1])]);
    many.push(['close']);
    const { bridge } = fakeBridge(904, many);
    const s = await ElectronTcpStream.open(bridge, '127.0.0.1', 22);
    let bytes = 0, err: Error | undefined, closed = false;
    s.onData = d => { bytes += d.length; };
    s.onClose = e => { closed = true; err = e; };
    await new Promise(r => setTimeout(r, 5));
    expect(closed).toBe(true);
    expect(err?.message).toMatch(/too much arrived/);
    expect(bytes).toBe(0);                            // nothing partial handed on as if live
    expect(calls).toEqual(['close 904']);             // and never resumed
  });
});

