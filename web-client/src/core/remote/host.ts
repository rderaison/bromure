// A live link to one remote Bromure (the fat-client "RemoteHostController"
// counterpart): owns the SSH connection, mirrors the server's /state via the
// push stream (deltas) with a poll fallback, and exposes the control API the
// UI calls. Everything rides one SSH connection; every request is its own
// exec channel.

import { SSHConnection, type ConnectOptions, type HostKeyInfo, type ClientKey } from '../ssh/client';
export type { HostKeyInfo } from '../ssh/client';
import type { ByteStream } from '../net/stream';
import { controlRequest, controlOpenStream, inflateRaw, ControlError, type RequestOptions } from '../control/http';
import { concat, fromUtf8, utf8 } from '../ssh/wire';
import type { RemoteState } from './types';

export type LinkStatus = 'connecting' | 'connected' | 'reconnecting' | 'failed' | 'closed';

export interface HostTarget {
  id: string;            // stable id (saved host uuid or peer device id)
  name: string;          // display name ("ark", "macdev")
  username: string;
  /** Opens a fresh byte stream to the server's sshd. */
  dial: () => Promise<ByteStream>;
  /** Pinned host key fingerprint, if any. */
  pinnedFingerprint?: string;
}

export interface HostCallbacks {
  /** First connect to an unpinned host: ask the user. */
  confirmHostKey: (info: HostKeyInfo, host: HostTarget) => Promise<boolean>;
  /** The pinned key changed: warn loudly. Return true only on explicit override. */
  hostKeyChanged: (info: HostKeyInfo, host: HostTarget) => Promise<boolean>;
  /** Key auth failed: the macOS-password fallback (enrolls our key on success). */
  askPassword?: (host: HostTarget, attempt: number) => Promise<string | null>;
  /** Persist a newly-trusted host key. */
  pin: (host: HostTarget, fingerprint: string) => void;
  clientKey: () => Promise<ClientKey>;
  publicKeyLine: () => Promise<string>;
}

type Listener = () => void;

export const seg = (s: string) => encodeURIComponent(s);

export class RemoteHost {
  status: LinkStatus = 'connecting';
  statusDetail = '';
  state: RemoteState | null = null;
  /** True while the push stream is live (poll drops to a slow heartbeat). */
  pushActive = false;
  connectedAt = 0;
  /** Smoothed round-trip of cheap requests, ms. */
  rttMs = 0;
  private conn: SSHConnection | null = null;
  private listeners = new Set<Listener>();
  private stateListeners = new Set<Listener>();
  private stopped = false;
  private pollTimer: ReturnType<typeof setTimeout> | null = null;
  private streamGen = 0;
  private connecting: Promise<SSHConnection> | null = null;
  private backoff = 1000;

  constructor(readonly target: HostTarget, private cb: HostCallbacks) {}

  // ── subscription (React hooks use these) ───────────────────────────────

  onChange(l: Listener): () => void { this.listeners.add(l); return () => this.listeners.delete(l); }
  onState(l: Listener): () => void { this.stateListeners.add(l); return () => this.stateListeners.delete(l); }
  private emit() { for (const l of [...this.listeners]) l(); }
  private emitState() { for (const l of [...this.stateListeners]) l(); this.emit(); }

  private setStatus(s: LinkStatus, detail = '') {
    this.status = s; this.statusDetail = detail; this.emit();
  }

  // ── lifecycle ──────────────────────────────────────────────────────────

  async start(): Promise<void> {
    this.stopped = false;
    await this.ensureConnection();
    this.startStateFeed();
  }

  stop() {
    this.stopped = true;
    if (this.pollTimer) clearTimeout(this.pollTimer);
    this.streamGen++;
    this.conn?.close();
    this.conn = null;
    this.setStatus('closed');
  }

  private async ensureConnection(): Promise<SSHConnection> {
    if (this.conn?.isOpen) return this.conn;
    if (this.connecting) return this.connecting;
    this.connecting = (async () => {
      this.setStatus(this.connectedAt ? 'reconnecting' : 'connecting');
      const key = await this.cb.clientKey();
      let passwordAttempts = 0;
      const opts: ConnectOptions = {
        username: this.target.username,
        key,
        verifyHostKey: async info => {
          const pin = this.target.pinnedFingerprint;
          if (pin) {
            if (pin === info.fingerprint) return true;
            const ok = await this.cb.hostKeyChanged(info, this.target);
            if (ok) { this.target.pinnedFingerprint = info.fingerprint; this.cb.pin(this.target, info.fingerprint); }
            return ok;
          }
          const ok = await this.cb.confirmHostKey(info, this.target);
          if (ok) { this.target.pinnedFingerprint = info.fingerprint; this.cb.pin(this.target, info.fingerprint); }
          return ok;
        },
        password: this.cb.askPassword ? () => this.cb.askPassword!(this.target, ++passwordAttempts) : undefined,
      };
      try {
        const conn = await SSHConnection.connect(await this.target.dial(), opts);
        this.conn = conn;
        this.connectedAt = Date.now();
        this.backoff = 1000;
        conn.onClose = err => {
          if (this.conn !== conn) return;
          this.conn = null;
          this.pushActive = false;
          if (!this.stopped) {
            this.setStatus('reconnecting', err?.message ?? '');
            this.scheduleReconnect();
          }
        };
        if (conn.authMethod === 'password') {
          // A correct password enrolls this device's key: next time is passwordless.
          const line = await this.cb.publicKeyLine();
          controlRequest(conn, 'POST', '/remote/keys', { body: { key: line } }).catch(() => {});
        }
        this.setStatus('connected');
        return conn;
      } finally {
        this.connecting = null;
      }
    })();
    return this.connecting;
  }

  private scheduleReconnect() {
    const delay = this.backoff;
    this.backoff = Math.min(this.backoff * 2, 15000);
    setTimeout(async () => {
      if (this.stopped || this.conn) return;
      try { await this.ensureConnection(); this.startStateFeed(); }
      catch (e: any) {
        if (e?.code === 'hostkey' || e?.code === 'auth') { this.setStatus('failed', e.message); return; }
        this.scheduleReconnect();
      }
    }, delay);
  }

  // ── requests ───────────────────────────────────────────────────────────

  /** One control request. Resolves with the parsed JSON; rejects on a
   *  transport failure or (unless `allowError`) a non-2xx status. */
  async request<T = any>(method: string, path: string, body?: unknown,
                         opts: Omit<RequestOptions, 'body'> & { allowError?: boolean } = {}): Promise<T> {
    const conn = await this.ensureConnection();
    const t0 = performance.now();
    const r = await controlRequest(conn, method, path, { ...opts, body });
    if (method === 'GET' && (path === '/state' || path === '/health')) {
      const ms = performance.now() - t0;
      this.rttMs = this.rttMs ? this.rttMs * 0.8 + ms * 0.2 : ms;
    }
    if (!opts.allowError && (r.status < 200 || r.status >= 300)) {
      throw new ControlError(r.json?.error ?? `request failed (HTTP ${r.status})`, r.status);
    }
    return r.json as T;
  }

  /** Fire-and-forget mutation; refreshes state right after (like `send`). */
  send(method: string, path: string, body?: unknown) {
    this.request(method, path, body).then(() => this.refreshSoon()).catch(e => console.warn('send', path, e));
  }

  async openStream(method: string, path: string, body: unknown = {}, headers: Record<string, string> = {}) {
    const conn = await this.ensureConnection();
    return controlOpenStream(conn, method, path, body, headers);
  }

  /** Run a shell command in a workspace guest (transcript reads etc). */
  async guestExec(workspaceID: string, command: string, timeout = 20): Promise<string> {
    const r = await this.request<any>('POST', `/vms/${seg(workspaceID)}/exec`, { command, timeout },
      { timeoutMs: (timeout + 15) * 1000, allowError: true });
    if ((r.exitCode ?? 1) !== 0 || r.error) throw new ControlError(r.stderr || r.error || 'exec failed');
    return r.stdout ?? '';
  }

  async guestFileOp(workspaceID: string, op: Record<string, unknown>, timeout = 30): Promise<any> {
    return this.request('POST', `/vms/${seg(workspaceID)}/file`, { op, timeout }, { timeoutMs: (timeout + 15) * 1000 });
  }

  // ── state feed ─────────────────────────────────────────────────────────

  private applyState(s: RemoteState) {
    this.state = s;
    this.emitState();
  }

  /** Re-fetch /state soon (after a mutation) unless the push stream will. */
  refreshSoon() {
    if (this.pushActive) return;
    setTimeout(() => this.pollOnce(), 150);
  }

  private async pollOnce() {
    try { this.applyState(await this.request<RemoteState>('GET', '/state')); } catch {}
  }

  private startStateFeed() {
    const gen = ++this.streamGen;
    this.pollOnce();
    const loop = async () => {
      if (this.stopped || gen !== this.streamGen) return;
      if (!this.pushActive) await this.pollOnce();
      this.pollTimer = setTimeout(loop, this.pushActive ? 5000 : 750);
    };
    this.pollTimer = setTimeout(loop, 750);
    this.runPushStream(gen);
  }

  private async runPushStream(gen: number) {
    let backoff = 1000;
    while (!this.stopped && gen === this.streamGen) {
      let connected = false;
      try {
        const ch = await this.openStream('GET', '/state/subscribe', {}, { 'X-Bromure-State-Delta': '1' });
        connected = true;
        this.pushActive = true; this.emit();
        await new Promise<void>(resolve => {
          let buf: Uint8Array = new Uint8Array(0);
          let base: any = null;
          let idle: ReturnType<typeof setTimeout>;
          const arm = () => { clearTimeout(idle); idle = setTimeout(() => { ch.close(); }, 45000); };
          arm();
          let chain = Promise.resolve();
          ch.onData = d => {
            arm();
            buf = buf.length ? concat(buf, d) : d;
            const frames: { compressed: boolean; delta: boolean; payload: Uint8Array }[] = [];
            let at = 0;
            while (buf.length - at >= 4) {
              const len = ((buf[at] << 24) | (buf[at + 1] << 16) | (buf[at + 2] << 8) | buf[at + 3]) >>> 0;
              if (len < 1 || len > 32 * 1024 * 1024) { ch.close(); return; }
              if (buf.length - at < 4 + len) break;
              const flag = buf[at + 4];
              frames.push({ compressed: !!(flag & 1), delta: !!(flag & 2), payload: buf.slice(at + 5, at + 4 + len) });
              at += 4 + len;
            }
            if (at) buf = buf.slice(at);
            if (!frames.length) return;
            const lastWhole = frames.map(f => f.delta).lastIndexOf(false);
            const use = lastWhole >= 0 ? frames.slice(lastWhole) : frames;
            chain = chain.then(async () => {
              let changed = false;
              for (const f of use) {
                let data: Uint8Array = f.payload;
                if (f.compressed) { try { data = await inflateRaw(data); } catch { continue; } }
                let obj: any;
                try { obj = JSON.parse(fromUtf8(data)); } catch { continue; }
                if (f.delta) {
                  if (!base) { ch.close(); return; }
                  base = { ...base };
                  for (const [k, v] of Object.entries(obj.set ?? {})) base[k] = v;
                  for (const k of obj.unset ?? []) delete base[k];
                } else base = obj;
                changed = true;
              }
              if (changed && gen === this.streamGen) this.applyState(base);
            });
          };
          ch.onClose = () => { clearTimeout(idle); resolve(); };
          ch.onEOF = () => { clearTimeout(idle); ch.close(); };
          ch.resume();
        });
      } catch { /* older server or link down */ }
      this.pushActive = false; this.emit();
      if (this.stopped || gen !== this.streamGen) return;
      backoff = connected ? 1000 : Math.min(backoff * 2, 30000);
      await new Promise(r => setTimeout(r, backoff));
    }
  }
}

// ── terminal attach (framed PTY over an exec stream) ─────────────────────

export const PTY = { data: 0, resize: 1, exit: 2, eof: 3 } as const;

export function ptyFrame(type: number, payload: Uint8Array): Uint8Array {
  const out = new Uint8Array(5 + payload.length);
  out[0] = type;
  out[1] = (payload.length >>> 24) & 0xff; out[2] = (payload.length >>> 16) & 0xff;
  out[3] = (payload.length >>> 8) & 0xff;  out[4] = payload.length & 0xff;
  out.set(payload, 5);
  return out;
}

export interface TerminalSink {
  write(data: Uint8Array): void;
  exited(code: number | null): void;
  disconnected(err?: Error): void;
}

/** One interactive terminal on a workspace tmux window. */
export class TerminalAttach {
  private ch: Awaited<ReturnType<RemoteHost['openStream']>> | null = null;
  private closed = false;
  constructor(private host: RemoteHost, readonly vmID: string, readonly windowIndex: number) {}

  async open(cols: number, rows: number, sink: TerminalSink) {
    const ch = await this.host.openStream('POST', `/vms/${seg(this.vmID)}/exec`, {
      command: '', interactive: true, cols, rows,
      view: crypto.randomUUID().toUpperCase(), window: this.windowIndex, guiConsent: true,
    });
    if (this.closed) { ch.close(); return; }
    this.ch = ch;
    let buf: Uint8Array = new Uint8Array(0);
    ch.onData = d => {
      buf = buf.length ? concat(buf, d) : d;
      let at = 0;
      while (buf.length - at >= 5) {
        const type = buf[at];
        const len = ((buf[at + 1] << 24) | (buf[at + 2] << 16) | (buf[at + 3] << 8) | buf[at + 4]) >>> 0;
        if (len > 16 * 1024 * 1024) { ch.close(); return; }   // no PTY frame is this big: a broken stream
        if (buf.length - at < 5 + len) break;
        const payload = buf.subarray(at + 5, at + 5 + len);
        if (type === PTY.data && len) sink.write(payload.slice());
        else if (type === PTY.exit) {
          const code = len >= 4 ? ((payload[0] << 24) | (payload[1] << 16) | (payload[2] << 8) | payload[3]) : null;
          sink.exited(code);
        }
        at += 5 + len;
      }
      if (at) buf = buf.slice(at);
    };
    ch.onClose = () => { this.ch = null; if (!this.closed) sink.disconnected(); };
    ch.resume();
  }
  input(data: string | Uint8Array) {
    this.ch?.write(ptyFrame(PTY.data, typeof data === 'string' ? utf8(data) : data));
  }
  resize(cols: number, rows: number) {
    const p = new Uint8Array([(cols >> 8) & 0xff, cols & 0xff, (rows >> 8) & 0xff, rows & 0xff]);
    this.ch?.write(ptyFrame(PTY.resize, p));
  }
  close() { this.closed = true; this.ch?.close(); this.ch = null; }
}
