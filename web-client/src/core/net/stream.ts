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
}

export class ElectronTcpStream implements ByteStream {
  onData: (data: Uint8Array) => void = () => {};
  onClose: (err?: Error) => void = () => {};
  private static streams = new Map<number, ElectronTcpStream>();
  private static wired = false;
  private closed = false;

  private constructor(private bridge: ElectronNetBridge, private id: number) {}

  static async open(bridge: ElectronNetBridge, host: string, port: number): Promise<ElectronTcpStream> {
    if (!ElectronTcpStream.wired) {
      ElectronTcpStream.wired = true;
      bridge.onTcpEvent((id, kind, data, message) => {
        const s = ElectronTcpStream.streams.get(id);
        if (!s) return;
        if (kind === 'data' && data) s.onData(data);
        else if (kind === 'close') s.finish();
        else if (kind === 'error') s.finish(new Error(message || 'connection error'));
      });
    }
    const id = await bridge.tcpOpen(host, port);
    const s = new ElectronTcpStream(bridge, id);
    ElectronTcpStream.streams.set(id, s);
    return s;
  }
  write(data: Uint8Array): void { if (!this.closed) this.bridge.tcpWrite(this.id, data); }
  close(): void { if (!this.closed) { this.bridge.tcpClose(this.id); this.finish(); } }
  private finish(err?: Error) {
    if (this.closed) return;
    this.closed = true;
    ElectronTcpStream.streams.delete(this.id);
    this.onClose(err);
  }
}
