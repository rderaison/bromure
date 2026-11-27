// src/features/editor/categories/callbackTunnel.ts: the OAuth callback splice
// acks bytes only as its SSH channel takes them, holds the channel while the
// local side is full, and closes a connection whose queue passes the cap
// (CWE-400: a local process could grow the renderer's memory without bound).

import { describe, it, expect } from 'vitest';
import { SSHChannel, type SSHConnection } from '../src/core/ssh/client';

type Ev = (id: number, kind: string, data?: Uint8Array) => void;
let onEvent: Ev = () => {};
let onAccept: (lid: number, id: number) => void = () => {};
const acks: number[] = [];
const closed: number[] = [];
const bridge = {
  platform: 'linux',
  tcpOpen: async () => 0, tcpWrite: () => {}, tcpClose: (id: number) => { closed.push(id); },
  onTcpEvent: (cb: Ev) => { onEvent = cb; },
  tcpListen: async () => 1, tcpUnlisten: () => {}, tcpResume: () => {},
  tcpAck: (_id: number, n: number) => { acks.push(n); },
  onTcpAccept: (cb: any) => { onAccept = cb; },
};
(globalThis as any).window = { bromureElectron: bridge };
const { startCallbackTunnel } = await import('../src/features/editor/categories/callbackTunnel');

const conn = { sendPacket: () => {}, finishChannel: (ch: SSHChannel) => { ch.closed = true; ch.onClose(); } } as unknown as SSHConnection;
let ch!: SSHChannel;
const host: any = { openForward: async () => { ch = new SSHChannel(conn, 0); ch.remoteWindow = 0; ch.pause(); return ch; } };
const settle = () => new Promise(r => setTimeout(r, 0));
const sum = (a: number[]) => a.reduce((x, y) => x + y, 0);

describe('OAuth callback tunnel flow control', () => {
  it('acks only what the channel took, holds it while the local side is full, caps its queue', async () => {
    await startCallbackTunnel(host, '192.168.64.5', 8085);
    onAccept(1, 42);
    await settle();
    // The VM's window is shut: bytes queue in the channel.
    const chunk = new Uint8Array(256 << 10);
    for (let i = 0; i < 3; i++) onEvent(42, 'data', chunk);          // 768 KiB queued: acked
    expect(sum(acks)).toBe(3 * chunk.length);
    for (let i = 0; i < 4; i++) onEvent(42, 'data', chunk);          // 1 MiB queued and more: held
    expect(sum(acks)).toBe(3 * chunk.length);
    const before = sum(acks);
    ch.remoteWindow = 64 << 20; ch.flush();                          // the VM reads: drain → the rest acked
    expect(ch.queuedBytes).toBe(0);
    expect(sum(acks)).toBe(7 * chunk.length);
    expect(sum(acks)).toBeGreaterThan(before);

    // The local side full / drained: the channel is held / released.
    onEvent(42, 'pause');
    expect(ch.paused).toBe(true);
    onEvent(42, 'resume');
    expect(ch.paused).toBe(false);

    // A queue past the cap (the VM never reads) closes the connection.
    ch.remoteWindow = 0;
    for (let i = 0; i < 40 && !ch.closed; i++) onEvent(42, 'data', chunk);
    expect(ch.closed).toBe(true);
    expect(closed).toContain(42);
  });
});
