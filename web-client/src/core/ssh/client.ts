// Minimal SSH-2 client over an arbitrary ByteStream, built on WebCrypto so the
// same code runs in a browser tab and in Electron's renderer.
//
// Scope is exactly what a Bromure server (swift-nio-ssh, RemoteAccessServer)
// speaks: kex curve25519-sha256, host key ssh-ed25519, cipher
// aes128/256-gcm@openssh.com, no compression; user auth publickey (ssh-ed25519)
// and password; session channels with `exec`. Rekeying initiated by the server
// is supported (same kex path). Many channels multiplex over one connection —
// every control request is its own exec channel, like the iOS client.

import type { ByteStream } from '../net/stream';
import { Reader, Writer, concat, utf8, fromUtf8, equalBytes, toBase64 } from './wire';

const MSG = {
  DISCONNECT: 1, IGNORE: 2, UNIMPLEMENTED: 3, DEBUG: 4, SERVICE_REQUEST: 5, SERVICE_ACCEPT: 6, EXT_INFO: 7,
  KEXINIT: 20, NEWKEYS: 21, KEX_ECDH_INIT: 30, KEX_ECDH_REPLY: 31,
  USERAUTH_REQUEST: 50, USERAUTH_FAILURE: 51, USERAUTH_SUCCESS: 52, USERAUTH_BANNER: 53,
  GLOBAL_REQUEST: 80, REQUEST_SUCCESS: 81, REQUEST_FAILURE: 82,
  CHANNEL_OPEN: 90, CHANNEL_OPEN_CONFIRMATION: 91, CHANNEL_OPEN_FAILURE: 92, CHANNEL_WINDOW_ADJUST: 93,
  CHANNEL_DATA: 94, CHANNEL_EXTENDED_DATA: 95, CHANNEL_EOF: 96, CHANNEL_CLOSE: 97,
  CHANNEL_REQUEST: 98, CHANNEL_SUCCESS: 99, CHANNEL_FAILURE: 100,
} as const;

const CLIENT_VERSION = 'SSH-2.0-BromureClient_1.0';
const BANNER_TIMEOUT_MS = 25_000;
const KEX_ALGS = ['curve25519-sha256', 'curve25519-sha256@libssh.org'];
const HOSTKEY_ALGS = ['ssh-ed25519'];
const CIPHERS = ['aes128-gcm@openssh.com', 'aes256-gcm@openssh.com'];
const MACS = ['hmac-sha2-256'];          // ignored with AEAD ciphers, but must intersect
const WINDOW = 4 * 1024 * 1024;
const MAX_PACKET = 32768;

const subtle = globalThis.crypto.subtle;

export class SSHError extends Error {
  constructor(message: string, readonly code: 'auth' | 'hostkey' | 'protocol' | 'closed' | 'channel' | 'nobanner' = 'protocol') { super(message); }
}

/** The client's identity: an Ed25519 key pair held as WebCrypto keys. */
export interface ClientKey {
  privateKey: CryptoKey;
  /** 32 raw public key bytes. */
  publicRaw: Uint8Array;
}

export interface HostKeyInfo {
  /** ssh-ed25519 public key blob (as in known_hosts). */
  blob: Uint8Array;
  /** "SHA256:…" (OpenSSH style, unpadded base64). */
  fingerprint: string;
}

export interface ConnectOptions {
  username: string;
  /** Called with the server's host key after its signature verified. Resolve
   *  true to trust it (TOFU / pin match), false to abort. */
  verifyHostKey: (info: HostKeyInfo) => Promise<boolean>;
  key?: ClientKey;
  /** Asked only after publickey auth failed (or when no key). Return null to give up. */
  password?: () => Promise<string | null>;
}

export function ed25519Blob(publicRaw: Uint8Array): Uint8Array {
  return new Writer().string('ssh-ed25519').string(publicRaw).bytes();
}

export async function fingerprintOf(blob: Uint8Array): Promise<string> {
  const h = new Uint8Array(await subtle.digest('SHA-256', blob as BufferSource));
  return 'SHA256:' + toBase64(h).replace(/=+$/, '');
}

interface Cipher {
  key: CryptoKey;
  iv: Uint8Array;  // 12 bytes; low 8 bytes are the invocation counter
}

function bumpIV(iv: Uint8Array) {
  for (let i = 11; i >= 4; i--) { iv[i] = (iv[i] + 1) & 0xff; if (iv[i] !== 0) break; }
}

type Pending = { resolve: (r: Reader) => void; reject: (e: Error) => void; types: number[] };

export class SSHChannel {
  onData: (data: Uint8Array) => void = () => {};
  onExtendedData: (data: Uint8Array) => void = () => {};
  onEOF: () => void = () => {};
  onClose: () => void = () => {};
  exitStatus: number | null = null;
  remoteId = 0;
  remoteWindow = 0;
  remoteMaxPacket = MAX_PACKET;
  localWindow = WINDOW;
  closed = false;
  private eofSent = false;
  private outQueue: Uint8Array[] = [];
  private buffered: Uint8Array[] = [];
  private eofSeen = false;
  private delivering = false;
  /** Set when the receiver isn't ready yet; data queues meanwhile. */
  paused = false;
  /** Called when everything written has gone out (the peer's window took
   *  it): a producer that stopped on `queuedBytes` resumes. */
  onDrain: () => void = () => {};

  constructor(readonly conn: SSHConnection, readonly localId: number) {}

  write(data: Uint8Array) {
    if (this.closed || this.eofSent) return;
    this.outQueue.push(data);
    this.flush();
  }
  /** Bytes written but not yet sent (waiting for the peer's window). */
  get queuedBytes(): number {
    let n = 0;
    for (const c of this.outQueue) n += c.length;
    return n;
  }
  /** @internal */
  flush() {
    const had = this.outQueue.length > 0;
    this.flushQueue();
    if (had && !this.outQueue.length && !this.closed) this.onDrain();
  }
  private flushQueue() {
    while (this.outQueue.length && this.remoteWindow > 0 && !this.closed) {
      let chunk = this.outQueue[0];
      const n = Math.min(chunk.length, this.remoteWindow, this.remoteMaxPacket - 64);
      if (n < chunk.length) { this.outQueue[0] = chunk.subarray(n); chunk = chunk.subarray(0, n); }
      else this.outQueue.shift();
      this.remoteWindow -= n;
      this.conn.sendPacket(new Writer().byte(MSG.CHANNEL_DATA).u32(this.remoteId).string(chunk).bytes());
    }
  }
  eof() {
    if (this.closed || this.eofSent) return;
    this.eofSent = true;
    this.conn.sendPacket(new Writer().byte(MSG.CHANNEL_EOF).u32(this.remoteId).bytes());
  }
  close() {
    if (this.closed) return;
    this.conn.sendPacket(new Writer().byte(MSG.CHANNEL_CLOSE).u32(this.remoteId).bytes());
    this.conn.finishChannel(this);
  }
  /** @internal Queue bytes ahead of anything buffered (stream handoff). */
  prepend(d: Uint8Array) { this.buffered.unshift(d); }
  /** Hold incoming data until `resume()` (used while a consumer is attaching). */
  pause() { this.paused = true; }
  resume() {
    this.paused = false;
    const b = this.buffered; this.buffered = [];
    for (const d of b) this.deliver(d);
    if (this.eofSeen) this.onEOF();
  }
  /** @internal */
  /** @internal Bytes from the peer: counted against our window on ARRIVAL
   *  (a paused channel buffers them, it doesn't grow the window); the window
   *  reopens only as the consumer takes them. Returns false when the peer
   *  overran the window it was given — a protocol violation. */
  receive(d: Uint8Array): boolean {
    if (d.length > this.localWindow) return false;
    this.localWindow -= d.length;
    this.deliver(d);
    return true;
  }
  private consumed = 0;
  /** @internal */
  deliver(d: Uint8Array) {
    if (this.paused) { this.buffered.push(d); return; }
    this.onData(d);
    this.consumed += d.length;
    // (Not for a channel the peer already closed: data it buffered is still
    // delivered, but no window adjust goes out for a dead channel.)
    if (!this.closed && this.localWindow < WINDOW / 2 && this.consumed > 0) {
      const add = this.consumed;
      this.consumed = 0;
      this.localWindow += add;
      this.conn.sendPacket(new Writer().byte(MSG.CHANNEL_WINDOW_ADJUST).u32(this.remoteId).u32(add).bytes());
    }
  }
  /** @internal */
  deliverEOF() { this.eofSeen = true; if (!this.paused) this.onEOF(); }
}

export class SSHConnection {
  onClose: (err?: Error) => void = () => {};
  hostKey: HostKeyInfo | null = null;
  /** Which auth method succeeded. */
  authMethod: 'publickey' | 'password' | null = null;

  private inbuf: Uint8Array = new Uint8Array(0);
  private versionDone = false;
  private serverVersion = '';
  private incoming: Cipher | null = null;
  private outgoing: Cipher | null = null;
  private pendingIncoming: Cipher | null = null;
  /** Resolves with the next inbound cipher once this kex derived it: the
   *  server's NEWKEYS often lands before our derivation finished. */
  private incomingReady: Promise<Cipher> | null = null;
  private resolveIncoming: ((c: Cipher) => void) | null = null;
  private seqIn = 0;
  private seqOut = 0;
  private sessionId: Uint8Array | null = null;
  private clientKexInit: Uint8Array | null = null;
  private serverKexInit: Uint8Array | null = null;
  private kexInProgress = false;
  private kexDone: (() => void) | null = null;
  private heldOutbound: Uint8Array[] = [];
  private sendChain: Promise<void> = Promise.resolve();
  private recvChain: Promise<void> = Promise.resolve();
  private waiters: Pending[] = [];
  private queued: Reader[] = [];
  private channels = new Map<number, SSHChannel>();
  private nextChannelId = 0;
  private openWaiters = new Map<number, { resolve: (c: SSHChannel) => void; reject: (e: Error) => void }>();
  private requestWaiters = new Map<number, Array<{ resolve: (ok: boolean) => void }>>();
  private dead: Error | null = null;
  private authenticated = false;
  private keepalive: ReturnType<typeof setInterval> | null = null;
  lastActivity = Date.now();

  private constructor(private stream: ByteStream) {
    stream.onData = d => this.onBytes(d);
    stream.onClose = err => this.fail(err ?? new SSHError('connection closed', 'closed'));
  }

  get isOpen() { return !this.dead; }

  static async connect(stream: ByteStream, opts: ConnectOptions): Promise<SSHConnection> {
    const c = new SSHConnection(stream);
    try {
      await c.handshake(opts);
      return c;
    } catch (e) {
      c.fail(e instanceof Error ? e : new Error(String(e)));
      throw e;
    }
  }

  close() {
    if (this.dead) return;
    try {
      this.sendPacket(new Writer().byte(MSG.DISCONNECT).u32(11).string('bye').string('').bytes());
    } catch {}
    setTimeout(() => this.stream.close(), 50);
    this.fail(new SSHError('closed by client', 'closed'));
  }

  // ── handshake ──────────────────────────────────────────────────────────

  private async handshake(opts: ConnectOptions) {
    this.stream.write(utf8(CLIENT_VERSION + '\r\n'));
    await this.waitVersion();
    await this.keyExchange(opts, null);
    // Service request → userauth
    this.sendPacket(new Writer().byte(MSG.SERVICE_REQUEST).string('ssh-userauth').bytes());
    await this.expect([MSG.SERVICE_ACCEPT]);
    await this.authenticate(opts);
    this.authenticated = true;
    this.keepalive = setInterval(() => {
      if (Date.now() - this.lastActivity > 20000) {
        this.sendPacket(new Writer().byte(MSG.IGNORE).string(new Uint8Array(0)).bytes());
      }
    }, 15000);
  }

  private versionResolve: (() => void) | null = null;
  private waitVersion(): Promise<void> {
    return new Promise((resolve, reject) => {
      // A transport that opens but never carries the server's banner (a relay
      // whose other end never joins) would otherwise hang the connect forever.
      const timer = setTimeout(() => {
        if (!this.versionDone) this.fail(new SSHError(`no SSH banner from the server after ${BANNER_TIMEOUT_MS / 1000} s`, 'nobanner'));
      }, BANNER_TIMEOUT_MS);
      this.versionResolve = () => { clearTimeout(timer); resolve(); };
      this.waiters.push({ resolve: () => {}, reject, types: [-1] });
      this.tryVersion();
    });
  }
  private tryVersion() {
    while (!this.versionDone) {
      const nl = this.inbuf.indexOf(10);
      if (nl < 0) { if (this.inbuf.length > 8192) this.fail(new SSHError('bad server banner')); return; }
      const line = fromUtf8(this.inbuf.subarray(0, nl)).replace(/\r$/, '');
      this.inbuf = this.inbuf.slice(nl + 1);
      if (line.startsWith('SSH-')) {
        if (!line.startsWith('SSH-2.0-') && !line.startsWith('SSH-1.99-')) { this.fail(new SSHError('unsupported SSH version: ' + line)); return; }
        this.serverVersion = line;
        this.versionDone = true;
        this.waiters = this.waiters.filter(w => !w.types.includes(-1));
        this.versionResolve?.();
      }
    }
  }

  private buildKexInit(): Uint8Array {
    const cookie = crypto.getRandomValues(new Uint8Array(16));
    return new Writer().byte(MSG.KEXINIT).raw(cookie)
      .nameList(KEX_ALGS).nameList(HOSTKEY_ALGS)
      .nameList(CIPHERS).nameList(CIPHERS)
      .nameList(MACS).nameList(MACS)
      .nameList(['none']).nameList(['none'])
      .nameList([]).nameList([])
      .bool(false).u32(0).bytes();
  }

  /** Runs a full key exchange. `serverInit` is set when the server started a
   *  rekey (its KEXINIT already arrived). */
  private async keyExchange(opts: ConnectOptions | null, serverInit: Uint8Array | null) {
    this.kexInProgress = true;
    this.incomingReady = new Promise(res => { this.resolveIncoming = res; });
    this.clientKexInit = this.buildKexInit();
    this.sendPacketNow(this.clientKexInit);
    let sInit = serverInit;
    if (!sInit) sInit = (await this.expect([MSG.KEXINIT])).buf;
    this.serverKexInit = sInit;
    const r = new Reader(sInit); r.byte(); r.raw(16);
    const sKex = r.nameList(), sHost = r.nameList(), sEncC2S = r.nameList(), sEncS2C = r.nameList();
    const pick = (mine: string[], theirs: string[], what: string) => {
      const m = mine.find(a => theirs.includes(a));
      if (!m) throw new SSHError(`no common ${what} algorithm (server offers: ${theirs.join(', ')})`);
      return m;
    };
    pick(KEX_ALGS, sKex, 'key-exchange');
    pick(HOSTKEY_ALGS, sHost, 'host-key');
    const encC2S = pick(CIPHERS, sEncC2S, 'cipher');
    const encS2C = pick(CIPHERS, sEncS2C, 'cipher');
    r.nameList(); r.nameList(); r.nameList(); r.nameList(); r.nameList(); r.nameList();
    const firstFollows = r.bool();
    if (firstFollows) throw new SSHError('server sent a guessed kex packet (unsupported)');

    // X25519 ephemeral
    const eph = await subtle.generateKey({ name: 'X25519' } as any, true, ['deriveBits']) as CryptoKeyPair;
    const qc = new Uint8Array(await subtle.exportKey('raw', eph.publicKey));
    this.sendPacketNow(new Writer().byte(MSG.KEX_ECDH_INIT).string(qc).bytes());
    const reply = await this.expect([MSG.KEX_ECDH_REPLY]);
    reply.byte();
    const hostBlob = reply.string();
    const qs = reply.string();
    const sigBlob = reply.string();
    const serverPub = await subtle.importKey('raw', qs as BufferSource, { name: 'X25519' } as any, false, []);
    const shared = new Uint8Array(await subtle.deriveBits({ name: 'X25519', public: serverPub } as any, eph.privateKey, 256));
    if (shared.every(b => b === 0)) throw new SSHError('invalid key exchange (all-zero secret)');
    const K = new Writer().mpint(shared).bytes();
    const hashInput = new Writer()
      .string(CLIENT_VERSION).string(this.serverVersion)
      .string(this.clientKexInit).string(this.serverKexInit)
      .string(hostBlob).string(qc).string(qs).raw(K).bytes();
    const H = new Uint8Array(await subtle.digest('SHA-256', hashInput as BufferSource));

    // Verify the host signature over H
    const hb = new Reader(hostBlob);
    if (hb.text() !== 'ssh-ed25519') throw new SSHError('unexpected host key type', 'hostkey');
    const hostRaw = hb.string();
    const sb = new Reader(sigBlob);
    if (sb.text() !== 'ssh-ed25519') throw new SSHError('unexpected host signature type', 'hostkey');
    const sig = sb.string();
    const hostKey = await subtle.importKey('raw', hostRaw as BufferSource, { name: 'Ed25519' } as any, false, ['verify']);
    const ok = await subtle.verify({ name: 'Ed25519' } as any, hostKey, sig as BufferSource, H as BufferSource);
    if (!ok) throw new SSHError('host key signature did not verify', 'hostkey');

    const info: HostKeyInfo = { blob: hostBlob, fingerprint: await fingerprintOf(hostBlob) };
    if (this.hostKey) {
      // Rekey: the host key must not change mid-connection.
      if (!equalBytes(this.hostKey.blob, hostBlob)) throw new SSHError('host key changed during rekey', 'hostkey');
    } else {
      this.hostKey = info;
      if (opts && !(await opts.verifyHostKey(info))) throw new SSHError('host key not trusted', 'hostkey');
    }
    if (!this.sessionId) this.sessionId = H;

    const derive = async (letter: string, len: number) => {
      let out: Uint8Array = new Uint8Array(await subtle.digest('SHA-256', concat(K, H, utf8(letter), this.sessionId!) as BufferSource));
      while (out.length < len) {
        const more = new Uint8Array(await subtle.digest('SHA-256', concat(K, H, out) as BufferSource));
        out = concat(out, more);
      }
      return out.slice(0, len);
    };
    const keyLen = (c: string) => c.startsWith('aes256') ? 32 : 16;
    const mk = async (ivL: string, keyL: string, cipher: string): Promise<Cipher> => ({
      iv: await derive(ivL, 12),
      key: await subtle.importKey('raw', (await derive(keyL, keyLen(cipher))) as BufferSource, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']),
    });
    const out = await mk('A', 'C', encC2S);
    const inn = await mk('B', 'D', encS2C);

    this.sendPacketNow(new Uint8Array([MSG.NEWKEYS]));
    this.outgoing = out;
    this.pendingIncoming = inn;
    this.resolveIncoming?.(inn);
    await this.expect([MSG.NEWKEYS]);
    this.kexInProgress = false;
    const held = this.heldOutbound; this.heldOutbound = [];
    for (const p of held) this.sendPacket(p);
    this.kexDone?.(); this.kexDone = null;
  }

  private async authenticate(opts: ConnectOptions) {
    const user = opts.username;
    let methods: string[] = ['publickey', 'password'];
    if (opts.key) {
      const blob = ed25519Blob(opts.key.publicRaw);
      const signed = new Writer()
        .string(this.sessionId!).byte(MSG.USERAUTH_REQUEST).string(user).string('ssh-connection')
        .string('publickey').bool(true).string('ssh-ed25519').string(blob).bytes();
      const sig = new Uint8Array(await subtle.sign({ name: 'Ed25519' } as any, opts.key.privateKey, signed as BufferSource));
      const sigBlob = new Writer().string('ssh-ed25519').string(sig).bytes();
      this.sendPacket(new Writer().byte(MSG.USERAUTH_REQUEST).string(user).string('ssh-connection')
        .string('publickey').bool(true).string('ssh-ed25519').string(blob).string(sigBlob).bytes());
      const r = await this.expect([MSG.USERAUTH_SUCCESS, MSG.USERAUTH_FAILURE]);
      if (r.buf[0] === MSG.USERAUTH_SUCCESS) { this.authMethod = 'publickey'; return; }
      r.byte(); methods = r.nameList();
    }
    if (opts.password && methods.includes('password')) {
      for (let attempt = 0; attempt < 3; attempt++) {
        const pw = await opts.password();
        if (pw == null) break;
        this.sendPacket(new Writer().byte(MSG.USERAUTH_REQUEST).string(user).string('ssh-connection')
          .string('password').bool(false).string(pw).bytes());
        const r = await this.expect([MSG.USERAUTH_SUCCESS, MSG.USERAUTH_FAILURE]);
        if (r.buf[0] === MSG.USERAUTH_SUCCESS) { this.authMethod = 'password'; return; }
      }
    }
    throw new SSHError(methods.includes('publickey') && !methods.includes('password')
      ? 'This device\'s key isn\'t authorized on the server.'
      : 'Authentication failed.', 'auth');
  }

  // ── channels ───────────────────────────────────────────────────────────

  /** Opens a session channel and runs `command` on it. Resolves once the
   *  server accepted the exec request. */
  async exec(command: string): Promise<SSHChannel> {
    if (this.dead) throw this.dead;
    const id = this.nextChannelId++;
    const ch = new SSHChannel(this, id);
    this.channels.set(id, ch);
    const opened = new Promise<SSHChannel>((resolve, reject) => this.openWaiters.set(id, { resolve, reject }));
    this.sendPacket(new Writer().byte(MSG.CHANNEL_OPEN).string('session').u32(id).u32(WINDOW).u32(MAX_PACKET).bytes());
    await opened;
    ch.pause();
    const accepted = new Promise<boolean>(resolve => {
      const list = this.requestWaiters.get(id) ?? [];
      list.push({ resolve });
      this.requestWaiters.set(id, list);
    });
    this.sendPacket(new Writer().byte(MSG.CHANNEL_REQUEST).u32(ch.remoteId).string('exec').bool(true).string(command).bytes());
    if (!(await accepted)) { ch.close(); throw new SSHError('server refused the request', 'channel'); }
    return ch;
  }

  /** @internal */
  finishChannel(ch: SSHChannel) {
    if (ch.closed) return;
    ch.closed = true;
    this.channels.delete(ch.localId);
    ch.onClose();
  }

  // ── packet I/O ─────────────────────────────────────────────────────────

  /** Queue a packet for sending, in order. Held while a key exchange runs
   *  (only kex packets may go out then). */
  sendPacket(payload: Uint8Array) {
    if (this.dead) return;
    if (this.kexInProgress && payload[0] >= 50) { this.heldOutbound.push(payload); return; }
    this.sendPacketNow(payload);
  }

  private sendPacketNow(payload: Uint8Array) {
    this.lastActivity = Date.now();
    const cipher = this.outgoing;
    this.sendChain = this.sendChain.then(async () => {
      if (this.dead) return;
      const block = cipher ? 16 : 8;
      // GCM: the length field isn't encrypted, so padding aligns (1 + payload + pad).
      const base = cipher ? 1 + payload.length : 5 + payload.length;
      let pad = block - (base % block);
      if (pad < 4) pad += block;
      const padding = crypto.getRandomValues(new Uint8Array(pad));
      const body = concat(new Uint8Array([pad]), payload, padding);
      const len = new Writer().u32(body.length).bytes();
      let wire: Uint8Array;
      if (cipher) {
        const iv = cipher.iv.slice();
        bumpIV(cipher.iv);
        const ct = new Uint8Array(await subtle.encrypt({ name: 'AES-GCM', iv: iv as BufferSource, additionalData: len as BufferSource, tagLength: 128 }, cipher.key, body as BufferSource));
        wire = concat(len, ct);
      } else {
        wire = concat(len, body);
      }
      this.seqOut = (this.seqOut + 1) >>> 0;
      this.stream.write(wire);
    }).catch(e => this.fail(e));
  }

  private onBytes(d: Uint8Array) {
    this.lastActivity = Date.now();
    this.inbuf = this.inbuf.length ? concat(this.inbuf, d) : d.slice();
    if (!this.versionDone) { this.tryVersion(); if (!this.versionDone) return; }
    this.recvChain = this.recvChain.then(() => this.drainPackets()).catch(e => this.fail(e));
  }

  private async drainPackets() {
    while (!this.dead) {
      if (this.inbuf.length < 4) return;
      const len = ((this.inbuf[0] << 24) | (this.inbuf[1] << 16) | (this.inbuf[2] << 8) | this.inbuf[3]) >>> 0;
      if (len > 256 * 1024 + 64) throw new SSHError('packet too large');
      const cipher = this.incoming;
      const total = 4 + len + (cipher ? 16 : 0);
      if (this.inbuf.length < total) return;
      const pkt = this.inbuf.subarray(0, total);
      this.inbuf = this.inbuf.slice(total);
      let body: Uint8Array;
      if (cipher) {
        const iv = cipher.iv.slice();
        bumpIV(cipher.iv);
        try {
          body = new Uint8Array(await subtle.decrypt({ name: 'AES-GCM', iv: iv as BufferSource, additionalData: pkt.slice(0, 4) as BufferSource, tagLength: 128 }, cipher.key, pkt.subarray(4) as BufferSource));
        } catch { throw new SSHError('packet authentication failed'); }
      } else {
        body = pkt.subarray(4);
      }
      this.seqIn = (this.seqIn + 1) >>> 0;
      const padLen = body[0];
      if (padLen < 4 || padLen >= body.length) throw new SSHError('malformed packet padding');
      const payload = body.subarray(1, body.length - padLen);
      if (payload.length === 0) continue;
      if (payload[0] === MSG.NEWKEYS) {
        this.incoming = this.pendingIncoming ?? (this.incomingReady ? await this.incomingReady : null);
        this.pendingIncoming = null;
        this.incomingReady = null;
      }
      this.dispatch(payload);
    }
  }

  private expect(types: number[]): Promise<Reader> {
    const i = this.queued.findIndex(r => types.includes(r.buf[0]));
    if (i >= 0) { const r = this.queued.splice(i, 1)[0]; return Promise.resolve(r); }
    if (this.dead) return Promise.reject(this.dead);
    return new Promise((resolve, reject) => this.waiters.push({ resolve, reject, types }));
  }

  private dispatch(payload: Uint8Array) {
    const type = payload[0];
    const r = new Reader(payload);
    switch (type) {
      case MSG.IGNORE: case MSG.DEBUG: case MSG.UNIMPLEMENTED: case MSG.EXT_INFO: case MSG.USERAUTH_BANNER:
        return;
      case MSG.DISCONNECT: {
        r.byte(); r.u32();
        const why = r.text();
        this.fail(new SSHError('server disconnected' + (why ? ': ' + why : ''), 'closed'));
        return;
      }
      case MSG.KEXINIT:
        if (this.authenticated && !this.kexInProgress) {
          this.keyExchange(null, payload).catch(e => this.fail(e));
          return;
        }
        break;
      case MSG.GLOBAL_REQUEST: {
        r.byte(); r.text();
        if (r.bool()) this.sendPacket(new Uint8Array([MSG.REQUEST_FAILURE]));
        return;
      }
    }
    if (type >= MSG.CHANNEL_OPEN && type <= MSG.CHANNEL_FAILURE && this.authenticated) {
      this.handleChannel(type, r);
      return;
    }
    const wi = this.waiters.findIndex(w => w.types.includes(type));
    if (wi >= 0) { const w = this.waiters.splice(wi, 1)[0]; w.resolve(new Reader(payload)); return; }
    this.queued.push(new Reader(payload));
  }

  private handleChannel(type: number, r: Reader) {
    r.byte();
    if (type === MSG.CHANNEL_OPEN) {
      // We never accept server-initiated channels.
      r.text(); const sender = r.u32();
      this.sendPacket(new Writer().byte(MSG.CHANNEL_OPEN_FAILURE).u32(sender).u32(1).string('prohibited').string('').bytes());
      return;
    }
    const id = r.u32();
    const ch = this.channels.get(id);
    switch (type) {
      case MSG.CHANNEL_OPEN_CONFIRMATION: {
        if (!ch) return;
        ch.remoteId = r.u32(); ch.remoteWindow = r.u32(); ch.remoteMaxPacket = r.u32();
        const w = this.openWaiters.get(id); this.openWaiters.delete(id);
        w?.resolve(ch);
        return;
      }
      case MSG.CHANNEL_OPEN_FAILURE: {
        const reason = r.u32(); const desc = r.text();
        const w = this.openWaiters.get(id); this.openWaiters.delete(id);
        this.channels.delete(id);
        w?.reject(new SSHError(`channel open failed (${reason}${desc ? ': ' + desc : ''})`, 'channel'));
        return;
      }
      case MSG.CHANNEL_WINDOW_ADJUST:
        if (!ch) return;
        ch.remoteWindow += r.u32();
        ch.flush();
        return;
      case MSG.CHANNEL_DATA:
        if (ch && !ch.receive(r.string().slice())) throw new SSHError('peer exceeded the channel window');
        return;
      case MSG.CHANNEL_EXTENDED_DATA:
        if (!ch) return;
        r.u32(); ch.onExtendedData(r.string().slice());
        return;
      case MSG.CHANNEL_EOF:
        ch?.deliverEOF();
        return;
      case MSG.CHANNEL_CLOSE:
        if (!ch) return;
        if (!ch.closed) this.sendPacket(new Writer().byte(MSG.CHANNEL_CLOSE).u32(ch.remoteId).bytes());
        // Deliver anything still buffered before reporting the close.
        if (ch.paused) ch.resume();
        this.finishChannel(ch);
        return;
      case MSG.CHANNEL_REQUEST: {
        const req = r.text(); const wantReply = r.bool();
        if (req === 'exit-status' && ch) ch.exitStatus = r.u32();
        if (wantReply && ch) this.sendPacket(new Writer().byte(MSG.CHANNEL_FAILURE).u32(ch.remoteId).bytes());
        return;
      }
      case MSG.CHANNEL_SUCCESS: case MSG.CHANNEL_FAILURE: {
        const list = this.requestWaiters.get(id);
        const w = list?.shift();
        if (list && !list.length) this.requestWaiters.delete(id);
        w?.resolve(type === MSG.CHANNEL_SUCCESS);
        return;
      }
    }
  }

  private fail(err: Error) {
    if (this.dead) return;
    this.dead = err;
    if (this.keepalive) clearInterval(this.keepalive);
    for (const w of this.waiters) w.reject(err);
    this.waiters = [];
    for (const [, w] of this.openWaiters) w.reject(err);
    this.openWaiters.clear();
    for (const [, list] of this.requestWaiters) for (const w of list) w.resolve(false);
    this.requestWaiters.clear();
    for (const ch of [...this.channels.values()]) this.finishChannel(ch);
    try { this.stream.close(); } catch {}
    this.onClose(err);
  }
}
