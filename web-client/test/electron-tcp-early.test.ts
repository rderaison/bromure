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
  tcpWrite: () => {}, tcpClose: () => {},
} as unknown as ElectronNetBridge;
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
  it('holds early bytes until the caller sets onData, however long it awaits first', async () => {
    // The tunnel's forward lane awaited the device key between the dial and
    // handing the stream to the SSH client: a replay timer fired in that gap
    // and the banner went to the default no-op handler.
    const enc = (t: string) => new TextEncoder().encode(t);
    const { bridge } = fakeBridge(903, [['data', enc('SSH-2.0-y\r\n')]]);
    const s = await ElectronTcpStream.open(bridge, '127.0.0.1', 22);
    await new Promise(r => setTimeout(r, 30));   // e.g. loading a key from IndexedDB
    const got: string[] = [];
    s.onData = d => got.push(new TextDecoder().decode(d));
    await new Promise(r => setTimeout(r, 5));
    expect(got.join('')).toBe('SSH-2.0-y\r\n');
  });
  it('an early close still closes', async () => {
    const { bridge } = fakeBridge(902, [['data', new Uint8Array([1])], ['close']]);
    const s = await ElectronTcpStream.open(bridge, '127.0.0.1', 22);
    let closed = false; s.onClose = () => { closed = true; };
    await new Promise(r => setTimeout(r, 5));
    expect(closed).toBe(true);
  });
});
