// src/features/toolbar/tunnel.ts: a tunnel flow whose SSH channel closes
// while main holds it (the local program isn't reading) must still finish —
// not wait for a drain that never comes (CWE-772: the flow, main's socket and
// the forwarder's flow stayed open for good after an SSH connection failure).

import { describe, it, expect, vi } from 'vitest';
import { SSHChannel, type SSHConnection } from '../src/core/ssh/client';

type Fn = (...a: any[]) => void;
const on: Record<string, Fn> = {};
const calls: [string, ...unknown[]][] = [];
const record = (name: string) => (...a: unknown[]) => { calls.push([name, ...a]); };
const bridge = {
  available: async () => ({ ok: true }),
  start: async () => ({ ok: true, ifname: 'brc0' }),
  stop: record('stop'),
  onExit: (cb: Fn) => { on.exit = cb; },
  onFlow: (cb: Fn) => { on.flow = cb; },
  flowOpened: record('flowOpened'),
  onFlowData: (cb: Fn) => { on.data = cb; },
  flowAck: record('flowAck'),
  flowData: record('flowData'),
  onFlowPause: (cb: Fn) => { on.pause = cb; },
  onFlowEnd: (cb: Fn) => { on.end = cb; },
  flowEnd: record('flowEnd'),
  onFlowClose: (cb: Fn) => { on.close = cb; },
  flowClose: record('flowClose'),
};
const store = new Map<string, string>();
(globalThis as any).localStorage = { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => store.set(k, v) };
(globalThis as any).window = { bromureElectron: { platform: 'linux', tunnel: bridge } };
vi.mock('../src/features/sidebar/Dialogs', () => ({ showAlert: vi.fn() }));

const { tunnelFor } = await import('../src/features/toolbar/tunnel');

// The SSH side: real channels on a fake connection. A connection failure is
// what SSHConnection.fail() does to each channel: finishChannel → onClose.
const conn = {
  sendPacket: () => {},
  finishChannel: (ch: SSHChannel) => { if (ch.closed) return; ch.closed = true; ch.onClose(); },
} as unknown as SSHConnection;
let nextChannel = 0;
const channels: SSHChannel[] = [];
const host: any = {
  target: { id: 'h1' },
  state: { vmnetSubnet: '192.168.64.0/24' },
  onState: () => () => {},
  openForward: async () => {
    const ch = new SSHChannel(conn, nextChannel++);
    ch.remoteWindow = 1 << 20;
    ch.pause();                       // exec() hands channels back paused
    channels.push(ch);
    return ch;
  },
};
store.set('bromure.tunnel.h1', '1');
const t = tunnelFor(host)!;
await t.attach();
const settle = () => new Promise(r => setTimeout(r, 0));
const callsFor = (id: number) => calls.filter(c => c[1] === id).map(c => c[0]);

describe('tunnel flows whose SSH channel closes while held', () => {
  it('reaches the active state', () => { expect(t.state).toBe('active'); });

  it('the connection fails while main holds the flow: buffered bytes, EOF, then close', async () => {
    on.flow(1, 'forward 192.168.64.5 80');
    await settle();
    const ch = channels[0];
    expect(callsFor(1)).toEqual(['flowOpened']);
    on.pause(1, true);                                  // the local program stopped reading
    ch.receive(new Uint8Array([1, 2, 3]));              // held by the paused channel
    ch.deliverEOF();
    expect(callsFor(1)).toEqual(['flowOpened']);
    (conn as any).finishChannel(ch);                    // SSH connection failure
    // No drain ever comes: the flow still finishes, with the held data first.
    expect(callsFor(1)).toEqual(['flowOpened', 'flowData', 'flowEnd', 'flowClose']);
    expect(calls.find(c => c[0] === 'flowData' && c[1] === 1)?.[2]).toEqual(new Uint8Array([1, 2, 3]));
    on.pause(1, false);                                 // a late drain is harmless
    expect(callsFor(1).filter(n => n === 'flowClose')).toHaveLength(1);
  });

  it('closed while held with nothing buffered: closes at once', async () => {
    on.flow(2, 'forward 192.168.64.5 81');
    await settle();
    on.pause(2, true);
    (conn as any).finishChannel(channels[1]);
    expect(callsFor(2)).toEqual(['flowOpened', 'flowClose']);
  });

  it('closed while flowing: closes at once (unchanged)', async () => {
    on.flow(3, 'forward 192.168.64.5 82');
    await settle();
    channels[2].receive(new Uint8Array([9]));
    (conn as any).finishChannel(channels[2]);
    expect(callsFor(3)).toEqual(['flowOpened', 'flowData', 'flowClose']);
  });
});
