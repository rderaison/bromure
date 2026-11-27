// A raw, reliable, ordered byte stream to an SSH server — the only thing the
// SSH client needs from the network. Implementations:
//   - WebSocketStream: browser (hosted) → bromure.io ws-relay → server sshd
//   - ElectronTcpStream: Electron renderer → main-process net.Socket (IPC)
// SSH runs end to end on top; whatever carries the bytes never sees plaintext.

export interface ByteStream {
  write(data: Uint8Array): void;
  close(): void;
  /** Bytes from the peer, in order. Set before data flows. */
  onData: (data: Uint8Array) => void;
  /** Called once when the stream ends (err set on failure). */
  onClose: (err?: Error) => void;
}

export class WebSocketStream implements ByteStream {
  onData: (data: Uint8Array) => void = () => {};
  onClose: (err?: Error) => void = () => {};
  private ws: WebSocket;
  private closed = false;

  private constructor(ws: WebSocket) {
    this.ws = ws;
    ws.binaryType = 'arraybuffer';
    ws.onmessage = ev => {
      if (ev.data instanceof ArrayBuffer) this.onData(new Uint8Array(ev.data));
    };
    ws.onclose = ev => this.finish(ev.code === 1000 ? undefined : new Error(`relay closed (${ev.code}${ev.reason ? ': ' + ev.reason : ''})`));
    ws.onerror = () => this.finish(new Error('relay connection failed'));
  }

  /** Opens and resolves once the socket is open. `protocols` carries the bearer
   *  (browsers can't set headers on a WebSocket upgrade). */
  static open(url: string, protocols?: string[], timeoutMs = 20000): Promise<WebSocketStream> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url, protocols);
      const timer = setTimeout(() => { try { ws.close(); } catch {} reject(new Error('relay connection timed out')); }, timeoutMs);
      ws.onopen = () => { clearTimeout(timer); resolve(new WebSocketStream(ws)); };
      ws.onerror = () => { clearTimeout(timer); reject(new Error('relay connection failed')); };
      ws.onclose = ev => { clearTimeout(timer); reject(new Error(`relay refused (${ev.code}${ev.reason ? ': ' + ev.reason : ''})`)); };
    });
  }

  write(data: Uint8Array): void {
    if (this.closed) return;
    this.ws.send(data);
  }
  /** A text frame (the JSON signaling channel). */
  sendText(s: string): void { if (!this.closed) this.ws.send(s); }
  close(): void { try { this.ws.close(1000); } catch {} this.finish(); }
  private finish(err?: Error) {
    if (this.closed) return;
    this.closed = true;
    this.onClose(err);
  }
}

/** Electron: the main process owns the TCP socket; bytes cross IPC. */
export interface ElectronNetBridge {
  tcpOpen(host: string, port: number): Promise<number>;
  tcpWrite(id: number, data: Uint8Array): void;
  tcpClose(id: number): void;
  onTcpEvent(cb: (id: number, kind: 'data' | 'close' | 'error', data?: Uint8Array, message?: string) => void): void;
  /** Listen on 127.0.0.1:<port> (≥ 1024); connections arrive via onTcpAccept. */
  tcpListen?(port: number): Promise<number>;
  tcpUnlisten?(listenerID: number): void;
  /** Start delivering an accepted socket's data (once its stream is wired). */
  tcpResume?(socketID: number): void;
  onTcpAccept?(cb: (listenerID: number, socketID: number) => void): void;
}

type TcpEvent = [kind: string, data?: Uint8Array, message?: string];

export class ElectronTcpStream implements ByteStream {
  private dataHandler: (data: Uint8Array) => void = () => {};
  private closeHandler: (err?: Error) => void = () => {};
  /** Setting a handler releases what arrived early (see `open`). */
  get onData() { return this.dataHandler; }
  set onData(f: (data: Uint8Array) => void) { this.dataHandler = f; this.releaseBacklog(); }
  get onClose() { return this.closeHandler; }
  set onClose(f: (err?: Error) => void) { this.closeHandler = f; this.releaseBacklog(); }
  private static streams = new Map<number, ElectronTcpStream>();
  private static wired = false;
  private closed = false;

  private constructor(private bridge: ElectronNetBridge, private id: number) {}

  /** An accepted loopback connection (see ElectronNetBridge.tcpListen). */
  static adopt(bridge: ElectronNetBridge, id: number): ElectronTcpStream {
    ElectronTcpStream.wire(bridge);
    const s = new ElectronTcpStream(bridge, id);
    ElectronTcpStream.streams.set(id, s);
    return s;
  }
  /** Begin delivering data once onData/onClose are set. */
  start(): void { this.bridge.tcpResume?.(this.id); }

  /** Events for an id `open` hasn't returned yet: main sends the socket's
   *  first bytes (the SSH server's banner) as soon as it connects, which can
   *  beat tcpOpen's reply. Kept until `open` claims them, never dropped. */
  private static early = new Map<number, TcpEvent[]>();
  /** While set, events queue here (behind the early ones) instead of firing. */
  private backlog: TcpEvent[] | null = null;

  private static wire(bridge: ElectronNetBridge) {
    if (!ElectronTcpStream.wired) {
      ElectronTcpStream.wired = true;
      bridge.onTcpEvent((id, kind, data, message) => {
        const ev: TcpEvent = [kind, data, message];
        const s = ElectronTcpStream.streams.get(id);
        if (!s) {
          const q = ElectronTcpStream.early.get(id) ?? [];
          if (q.length < 1024) q.push(ev);
          ElectronTcpStream.early.set(id, q);
          return;
        }
        if (s.backlog) s.backlog.push(ev); else s.deliver(ev);
      });
    }
  }
  private deliver([kind, data, message]: TcpEvent) {
    if (kind === 'data' && data) this.onData(data);
    else if (kind === 'close') this.finish();
    else if (kind === 'error') this.finish(new Error(message || 'connection error'));
  }

  static async open(bridge: ElectronNetBridge, host: string, port: number): Promise<ElectronTcpStream> {
    ElectronTcpStream.wire(bridge);
    const id = await bridge.tcpOpen(host, port);
    const s = new ElectronTcpStream(bridge, id);
    ElectronTcpStream.streams.set(id, s);
    const early = ElectronTcpStream.early.get(id);
    ElectronTcpStream.early.delete(id);
    // Held until the caller sets its handlers — however long that takes
    // (a timer guessed "right after this returns" and lost the banner when
    // the caller awaited something first) — then delivered in order, ahead
    // of anything that arrives meanwhile.
    if (early) s.backlog = early;
    return s;
  }
  private releaseBacklog() {
    if (!this.backlog || this.releasing) return;
    this.releasing = true;
    // A microtask: the caller sets onData and onClose together.
    queueMicrotask(() => {
      this.releasing = false;
      const q = this.backlog ?? [];
      this.backlog = null;
      for (const ev of q) this.deliver(ev);
    });
  }
  private releasing = false;
  write(data: Uint8Array): void { if (!this.closed) this.bridge.tcpWrite(this.id, data); }
  close(): void { if (!this.closed) { this.bridge.tcpClose(this.id); this.finish(); } }
  private finish(err?: Error) {
    if (this.closed) return;
    this.closed = true;
    ElectronTcpStream.streams.delete(this.id);
    this.onClose(err);
  }
}
