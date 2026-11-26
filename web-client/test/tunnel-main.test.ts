// electron/tunnel.ts: overlapping starts (a subnet change, a quick off/on)
// must never let an older attempt tear down the newer tunnel (CWE-362).
// Electron's IPC and the forwarder processes are fakes; the flow sockets are
// real.

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

const handlers = new Map<string, (...a: any[]) => any>();
vi.mock('electron', () => ({
  ipcMain: {
    handle: (ch: string, fn: any) => handlers.set(ch, fn),
    on: (ch: string, fn: any) => handlers.set(ch, fn),
  },
}));

class FakeProc extends EventEmitter {
  stdin = new PassThrough(); stdout = new PassThrough(); stderr = new PassThrough();
  killed = false;
  constructor(readonly args: string[]) { super(); }
  kill() { this.killed = true; return true; }      // exits when the test says so
  answer(line: string) { this.stdout.write(line + '\n'); }
  exit() { this.emit('exit', 0); }
}
const procs: FakeProc[] = [];
vi.mock('node:child_process', () => ({
  spawn: (_bin: string, args: string[]) => { const p = new FakeProc(args); procs.push(p); return p; },
}));

const { setupTunnel, stopTunnel } = await import('../electron/tunnel');

const sent: unknown[][] = [];
const wc = { isDestroyed: () => false, send: (...a: unknown[]) => sent.push(a) };
setupTunnel(() => ({ webContents: wc }) as any);
const ev = { sender: wc };
const start = (cidr: string) => handlers.get('tunnel:start')!(ev, cidr) as Promise<{ ok: boolean; error?: string }>;
const sockOf = (p: FakeProc) => p.args[p.args.indexOf('--app-socket') + 1];
const until = async (cond: () => boolean) => { for (let i = 0; i < 200 && !cond(); i++) await new Promise(r => setTimeout(r, 5)); expect(cond()).toBe(true); };
const listening = (p: string) => new Promise<boolean>(resolve => {
  const c = net.connect(p, () => { c.destroy(); resolve(true); });
  c.on('error', () => resolve(false));
});

let tmp: string;
beforeEach(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'bct-main-'));
  process.env.XDG_RUNTIME_DIR = tmp;
  process.env.BROMURE_TUNNEL_BIN = path.join(tmp, 'bromure-client-tunnel');
  fs.writeFileSync(process.env.BROMURE_TUNNEL_BIN, '');
  const real = fs.existsSync;
  vi.spyOn(fs, 'existsSync').mockImplementation(p => p === '/run/bromure-client-tunnel.sock' || real(p));
  procs.length = 0; sent.length = 0;
});
afterEach(() => { stopTunnel(); vi.restoreAllMocks(); fs.rmSync(tmp, { recursive: true, force: true }); });

describe.runIf(process.platform === 'linux')('tunnel starts in the main process', () => {
  it('a newer start survives the older one failing late', async () => {
    const a = start('192.168.64.0/24');
    await until(() => procs.length === 1);
    const b = start('192.168.65.0/24');           // A is still waiting on its status
    await until(() => procs.length === 2);
    const [pa, pb] = procs;
    expect(pa.killed).toBe(true);                 // the newer start ended A
    expect(sockOf(pa)).not.toBe(sockOf(pb));      // each attempt its own socket
    pb.answer('OK brc1');
    expect(await b).toEqual({ ok: true, ifname: 'brc1' });
    pa.exit();                                    // A's forwarder goes away late
    expect((await a).ok).toBe(false);
    // B is untouched: its forwarder alive, its socket served, no exit event.
    expect(pb.killed).toBe(false);
    expect(await listening(sockOf(pb))).toBe(true);
    expect(fs.existsSync(sockOf(pa))).toBe(false);
    expect(sent.filter(m => m[0] === 'tunnel:exit')).toEqual([]);
  });

  it('a stop during a start, then a new start: the late exit of the first leaves the second', async () => {
    const a = start('192.168.64.0/24');
    await until(() => procs.length === 1);
    handlers.get('tunnel:stop')!(ev);
    const b = start('192.168.64.0/24');
    await until(() => procs.length === 2);
    procs[1].answer('OK brc0');
    expect((await b).ok).toBe(true);
    procs[0].answer('OK brc9');                   // too late: A was stopped
    procs[0].exit();
    expect((await a).ok).toBe(false);
    expect(procs[1].killed).toBe(false);
    expect(await listening(sockOf(procs[1]))).toBe(true);
    // The live tunnel's own exit is still reported.
    procs[1].exit();
    await until(() => sent.some(m => m[0] === 'tunnel:exit'));
    expect(await listening(sockOf(procs[1]))).toBe(false);
  });

  it('a failed start cleans up only itself', async () => {
    const a = start('192.168.64.0/24');
    await until(() => procs.length === 1);
    procs[0].answer('ERR the tunnel helper refused: route taken');
    expect(await a).toEqual({ ok: false, error: 'the tunnel helper refused: route taken' });
    expect(fs.existsSync(sockOf(procs[0]))).toBe(false);
  });
});
