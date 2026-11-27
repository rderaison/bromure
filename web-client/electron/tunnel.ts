// The Linux network tunnel's main-process half (see web-client/tunnel/ for the
// rest): a connected remote's workspace subnet (e.g. 192.168.64.0/24) made
// reachable at its literal addresses from any of the user's programs, as the
// macOS fat client's utun tunnel does.
//
//   bromure-client-tunnel forward  (spawned here, runs as the user): gets a
//     TUN from the root helper (systemd socket bromure-client-tunnel.socket,
//     from the .deb) and runs the userspace TCP/UDP stack on it; each flow it
//     opens is a connection to OUR socket carrying one line, `forward <ip>
//     <port>` or `forward-udp <ip>`, then raw bytes.
//   here: each flow goes to the renderer, which owns the SSH connection and
//     the device key (non-extractable); it opens `bromure-fatclient/1 <verb>`
//     on its forward connection and the bytes flow through IPC.
//
// Backpressure, both hops, bounded: local → remote, at most FLOW_HIGH bytes
// are in flight to the renderer before the local socket is paused (the
// renderer acks what its SSH channel took); remote → local, when the local
// socket's buffer is full the renderer pauses the channel (its SSH window then
// stops the server).

import { BrowserWindow, ipcMain, type WebContents } from 'electron';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const HELPER_SOCKET = '/run/bromure-client-tunnel.sock';
const FLOW_HIGH = 1 << 20;   // pause a local socket with this much unacked
const FLOW_LOW = 256 << 10;  // and resume below this

/** One start of the tunnel: its forwarder, its flow socket, its flows. A
 *  newer start (or a stop) ends it; everything an attempt set up is cleaned up
 *  by that attempt's own session, so a late answer from an older forwarder
 *  never touches the newer tunnel. */
interface Session {
  owner: WebContents;
  cidr: string;
  sockPath: string;
  server: net.Server;
  child: ChildProcessWithoutNullStreams | null;
  stopped: boolean;
}
interface Flow { s: Session; sock: net.Socket; inflight: number; paused: boolean; opened: boolean }

let current: Session | null = null;
let attempts = 0;
const flows = new Map<number, Flow>();
let nextFlow = 1;

/** The forwarder binary: next to the app's resources (packaged), or
 *  BROMURE_TUNNEL_BIN (dev). */
export function tunnelBinary(): string {
  return process.env.BROMURE_TUNNEL_BIN || path.join(process.resourcesPath ?? '', 'bromure-client-tunnel');
}

function availability(): { ok: boolean; reason?: string } {
  if (process.platform !== 'linux') return { ok: false, reason: 'The network tunnel is available in the Linux app.' };
  const bin = tunnelBinary();
  let st: fs.Stats;
  try { st = fs.statSync(bin); } catch { return { ok: false, reason: 'This copy of Bromure Client has no tunnel program.' }; }
  if (!fs.existsSync(HELPER_SOCKET)) {
    return { ok: false, reason: 'The tunnel needs its system helper, installed with the .deb package (sudo apt install bromure-client).' };
  }
  // The helper serves only its own installed, root-owned program.
  if (!process.env.BROMURE_TUNNEL_BIN && st.uid !== 0) {
    return { ok: false, reason: 'Use the installed Bromure Client (/opt/bromure-client) for the tunnel; this copy isn\'t the one the helper trusts.' };
  }
  return { ok: true };
}

function cidrMatch(ip: string, c: string): boolean {
  const toNum = (s: string) => s.split('.').reduce((a, o) => (a << 8) + +o, 0) >>> 0;
  const [net4, bits] = c.split('/');
  const mask = bits === '0' ? 0 : (~0 << (32 - +bits)) >>> 0;
  return ((toNum(ip) & mask) >>> 0) === ((toNum(net4) & mask) >>> 0);
}

const VERB = /^(forward (\d{1,3}(?:\.\d{1,3}){3}) (\d{1,5})|forward-udp (\d{1,3}(?:\.\d{1,3}){3}))$/;

/** One flow from session `s`'s forwarder: its verb line, then raw bytes. */
function acceptFlow(s: Session, sock: net.Socket) {
  if (s.stopped || s.owner.isDestroyed()) { sock.destroy(); return; }
  let head = Buffer.alloc(0);
  const fail = (why: string) => { try { sock.end(`ERR ${why}\n`); } catch {} };
  sock.setTimeout(10000, () => sock.destroy());
  const onHead = (d: Buffer) => {
    head = Buffer.concat([head, d]);
    const nl = head.indexOf(10);
    if (nl < 0) { if (head.length > 128) { sock.off('data', onHead); fail('bad request'); } return; }
    sock.off('data', onHead);
    sock.pause();
    const line = head.subarray(0, nl).toString('latin1');
    const rest = head.subarray(nl + 1);
    const m = VERB.exec(line);
    const ip = m?.[2] ?? m?.[4];
    if (!m || !ip || ip.split('.').some(o => +o > 255) || (m[3] && (+m[3] < 1 || +m[3] > 65535)) || !cidrMatch(ip, s.cidr)) {
      fail('bad request'); return;
    }
    const id = nextFlow++;
    const flow: Flow = { s, sock, inflight: 0, paused: false, opened: false };
    flows.set(id, flow);
    if (rest.length) sock.unshift(rest);
    sock.on('close', () => { if (flows.delete(id)) send(s, 'tunnel:flow-close', id); });
    sock.on('error', () => {});
    send(s, 'tunnel:flow', id, line);
  };
  sock.on('data', onHead);
}

function send(s: Session, channel: string, ...args: unknown[]) {
  if (!s.owner.isDestroyed()) s.owner.send(channel, ...args);
}

/** The flow's SSH channel is open (or not): data starts flowing. */
function flowOpened(id: number, ok: boolean, error?: string) {
  const f = flows.get(id);
  if (!f) return;
  if (!ok) { flows.delete(id); try { f.sock.end(`ERR ${(error ?? 'failed').replace(/\n/g, ' ')}\n`); } catch {} return; }
  f.opened = true;
  f.sock.setTimeout(0);
  f.sock.write('OK\n');
  f.sock.on('data', (d: Buffer) => {
    send(f.s, 'tunnel:flow-data', id, new Uint8Array(d.buffer, d.byteOffset, d.length));
    f.inflight += d.length;
    if (f.inflight > FLOW_HIGH && !f.paused) { f.paused = true; f.sock.pause(); }
  });
  f.sock.on('end', () => send(f.s, 'tunnel:flow-end', id));
  f.sock.on('drain', () => send(f.s, 'tunnel:flow-pause', id, false));
  f.sock.resume();
}

/** Ends session `s` and only what it owns (idempotent). */
function stopSession(s: Session) {
  if (s.stopped) return;
  s.stopped = true;
  if (current === s) current = null;
  for (const [id, f] of flows) if (f.s === s) { flows.delete(id); f.sock.destroy(); }
  if (s.child) { try { s.child.stdin.end(); } catch {} s.child.kill('SIGTERM'); s.child = null; }
  s.server.close();
  try { fs.unlinkSync(s.sockPath); } catch {}
}

/** Stops the current tunnel (a start still under way included). */
function stopTunnel() {
  if (current) stopSession(current);
}

const SUPERSEDED = { ok: false, error: 'superseded by a newer start' };

async function startTunnel(wc: WebContents, wanted: string): Promise<{ ok: boolean; ifname?: string; error?: string }> {
  if (!/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.0\/24$/.test(wanted)) return { ok: false, error: `not a /24 subnet: ${wanted}` };
  const a = availability();
  if (!a.ok) return { ok: false, error: a.reason };
  stopTunnel();
  // The flow socket: owner-only, in an owner-only directory, one per attempt
  // (an older attempt's cleanup must not unlink a newer one's).
  const dir = path.join(process.env.XDG_RUNTIME_DIR || os.tmpdir(), `bromure-client-${process.getuid?.() ?? 'u'}`);
  const s: Session = {
    owner: wc, cidr: wanted, sockPath: path.join(dir, `tunnel-${process.pid}-${++attempts}.sock`),
    // Half-open: a flow's local side may finish sending (the client's FIN)
    // while the remote's answer still flows back.
    server: net.createServer({ allowHalfOpen: true }, sock => acceptFlow(s, sock)),
    child: null, stopped: false,
  };
  current = s;
  try {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dir, 0o700);
    try { fs.unlinkSync(s.sockPath); } catch {}
    await new Promise<void>((resolve, reject) => { s.server.once('error', reject); s.server.listen(s.sockPath, () => resolve()); });
    if (s.stopped) return SUPERSEDED;
    fs.chmodSync(s.sockPath, 0o600);
  } catch (e: any) {
    stopSession(s);
    return { ok: false, error: `the tunnel's socket: ${e?.message ?? e}` };
  }

  const proc = spawn(tunnelBinary(), ['forward', '--cidr', s.cidr, '--app-socket', s.sockPath], { stdio: ['pipe', 'pipe', 'pipe'] });
  s.child = proc;
  let stderr = '';
  proc.stderr.on('data', d => { stderr = (stderr + d.toString()).slice(-2000); });
  const status = await new Promise<string>(resolve => {
    let out = '';
    const timer = setTimeout(() => resolve('ERR the tunnel program didn\'t answer'), 20000);
    proc.stdout.on('data', d => {
      out += d.toString();
      const nl = out.indexOf('\n');
      if (nl >= 0) { clearTimeout(timer); resolve(out.slice(0, nl)); }
    });
    proc.once('exit', () => { clearTimeout(timer); resolve(out.split('\n')[0] || `ERR ${stderr.trim().split('\n').pop() || 'the tunnel program stopped'}`); });
    proc.once('error', e => { clearTimeout(timer); resolve(`ERR ${e.message}`); });
  });
  // Stopped meanwhile (a stop, or a newer start): this attempt's own
  // resources are already gone, and nothing else is ours to touch.
  if (s.stopped) return SUPERSEDED;
  if (!status.startsWith('OK ')) {
    stopSession(s);
    return { ok: false, error: status.replace(/^ERR /, '') };
  }
  proc.once('exit', () => {
    if (s.stopped) return;
    const why = stderr.trim().split('\n').pop() || 'the tunnel stopped';
    stopSession(s);
    send(s, 'tunnel:exit', why.replace(/^bromure-client-tunnel: /, ''));
  });
  return { ok: true, ifname: status.slice(3).trim() };
}

/** Wires the IPC. Only the main window's renderer may drive the tunnel. */
export function setupTunnel(mainWindow: () => BrowserWindow | null) {
  const fromMain = (e: Electron.IpcMainEvent | Electron.IpcMainInvokeEvent) => e.sender === mainWindow()?.webContents;
  ipcMain.handle('tunnel:available', e => (fromMain(e) ? availability() : { ok: false }));
  ipcMain.handle('tunnel:start', (e, c: string) => (fromMain(e) ? startTunnel(e.sender, String(c)) : { ok: false }));
  ipcMain.on('tunnel:stop', e => { if (fromMain(e)) stopTunnel(); });
  ipcMain.on('tunnel:flow-opened', (e, id: number, ok: boolean, error?: string) => { if (fromMain(e)) flowOpened(id, !!ok, error); });
  ipcMain.on('tunnel:flow-ack', (e, id: number, n: number) => {
    const f = fromMain(e) ? flows.get(id) : undefined;
    if (!f) return;
    f.inflight = Math.max(0, f.inflight - (+n || 0));
    if (f.paused && f.inflight < FLOW_LOW) { f.paused = false; f.sock.resume(); }
  });
  ipcMain.on('tunnel:flow-recv', (e, id: number, data: Uint8Array) => {
    const f = fromMain(e) ? flows.get(id) : undefined;
    if (!f || !f.opened) return;
    if (!f.sock.write(data)) send(f.s, 'tunnel:flow-pause', id, true);
  });
  ipcMain.on('tunnel:flow-eof', (e, id: number) => { const f = fromMain(e) ? flows.get(id) : undefined; f?.sock.end(); });
  // The remote side closed: finish gracefully (what's buffered still goes
  // out to the local program), never hold a socket past half a minute.
  ipcMain.on('tunnel:flow-destroy', (e, id: number) => {
    const f = fromMain(e) ? flows.get(id) : undefined;
    if (!f) return;
    flows.delete(id);
    f.sock.end();
    setTimeout(() => f.sock.destroy(), 30000).unref();
  });
}

export { stopTunnel };
