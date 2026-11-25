// The control-socket HTTP API, spoken over SSH exec channels
// (`bromure-fatclient/1 control`) — the exact contract of the Swift
// ControlClient: one request per channel, `Connection: close`, an optional
// raw-DEFLATE body (`X-Bromure-Gzip: 1`, Apple's NSData `.zlib`).

import type { SSHChannel, SSHConnection } from '../ssh/client';
import { concat, utf8, fromUtf8 } from '../ssh/wire';

export const CONTROL_VERB = 'bromure-fatclient/1 control';

export interface ControlResponse<T = any> { status: number; json: T; raw: Uint8Array; headers: Record<string, string> }

export class ControlError extends Error {
  constructor(message: string, readonly status = 0) { super(message); }
}

export async function inflateRaw(data: Uint8Array): Promise<Uint8Array> {
  const ds = new DecompressionStream('deflate-raw' as CompressionFormat);
  const out = new Blob([data as BlobPart]).stream().pipeThrough(ds);
  return new Uint8Array(await new Response(out).arrayBuffer());
}

function findHeaderEnd(b: Uint8Array): number {
  for (let i = 3; i < b.length; i++) {
    if (b[i - 3] === 13 && b[i - 2] === 10 && b[i - 1] === 13 && b[i] === 10) return i + 1;
  }
  return -1;
}

function parseHead(head: string): { status: number; headers: Record<string, string> } {
  const lines = head.split('\r\n');
  const status = parseInt(lines[0]?.split(' ')[1] ?? '0', 10) || 0;
  const headers: Record<string, string> = {};
  for (const l of lines.slice(1)) {
    const i = l.indexOf(':');
    if (i > 0) headers[l.slice(0, i).trim().toLowerCase()] = l.slice(i + 1).trim();
  }
  return { status, headers };
}

function buildRequest(method: string, path: string, body: Uint8Array, headers: Record<string, string>): Uint8Array {
  let head = `${method} ${path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\n`;
  for (const [k, v] of Object.entries(headers)) head += `${k}: ${v}\r\n`;
  head += 'Connection: close\r\n\r\n';
  return concat(utf8(head), body);
}

export interface RequestOptions {
  body?: unknown;
  headers?: Record<string, string>;
  timeoutMs?: number;
  /** Return the body as bytes without JSON parsing. */
  rawBody?: boolean;
}

/** One HTTP request over a fresh exec channel. */
export async function controlRequest(conn: SSHConnection, method: string, path: string, opts: RequestOptions = {}): Promise<ControlResponse> {
  const ch = await conn.exec(CONTROL_VERB);
  const body = opts.body === undefined ? new Uint8Array(0) : utf8(JSON.stringify(opts.body));
  return new Promise<ControlResponse>((resolve, reject) => {
    let buf: Uint8Array = new Uint8Array(0);
    let expected = -2; // -2 = header not parsed; -1 = to EOF
    let done = false;
    const timeout = setTimeout(() => finish(new ControlError(`request timed out: ${method} ${path}`)), opts.timeoutMs ?? 30000);
    const finish = async (err?: Error) => {
      if (done) return;
      done = true;
      clearTimeout(timeout);
      try { ch.close(); } catch {}
      if (err) { reject(err); return; }
      const he = findHeaderEnd(buf);
      if (he < 0) { reject(new ControlError('Invalid HTTP response from agent')); return; }
      const { status, headers } = parseHead(fromUtf8(buf.subarray(0, he - 4)));
      let raw: Uint8Array = buf.subarray(he);
      if (expected >= 0) raw = raw.subarray(0, expected - he);
      if (headers['x-bromure-gzip'] === '1') {
        try { raw = await inflateRaw(raw); } catch { /* not compressed after all */ }
      }
      let json: any = {};
      if (!opts.rawBody && raw.length) { try { json = JSON.parse(fromUtf8(raw)); } catch { json = {}; } }
      resolve({ status, json, raw, headers });
    };
    ch.onData = d => {
      buf = buf.length ? concat(buf, d) : d;
      if (expected === -2) {
        const he = findHeaderEnd(buf);
        if (he >= 0) {
          const { headers } = parseHead(fromUtf8(buf.subarray(0, he - 4)));
          const cl = headers['content-length'];
          expected = cl !== undefined ? he + parseInt(cl, 10) : -1;
        }
      }
      if (expected >= 0 && buf.length >= expected) finish();
    };
    ch.onEOF = () => finish();
    ch.onClose = () => finish();
    ch.resume();
    ch.write(buildRequest(method, path, body, opts.headers ?? {}));
  });
}

/** Open a streaming request: resolves with the channel positioned just after
 *  the response header (status 200), for bidirectional raw streaming. */
export async function controlOpenStream(conn: SSHConnection, method: string, path: string, body: unknown = {},
                                        headers: Record<string, string> = {}): Promise<SSHChannel> {
  const ch = await conn.exec(CONTROL_VERB);
  return new Promise<SSHChannel>((resolve, reject) => {
    let buf: Uint8Array = new Uint8Array(0);
    let settled = false;
    const timer = setTimeout(() => fail(new ControlError('Agent closed during handshake')), 15000);
    const fail = (e: Error) => { if (settled) return; settled = true; clearTimeout(timer); try { ch.close(); } catch {} reject(e); };
    ch.onData = d => {
      if (settled) return;
      buf = buf.length ? concat(buf, d) : d;
      const he = findHeaderEnd(buf);
      if (he < 0) { if (buf.length > 16384) fail(new ControlError('Oversized response header')); return; }
      const { status } = parseHead(fromUtf8(buf.subarray(0, he - 4)));
      if (status !== 200) {
        // Collect the error body.
        let rest: Uint8Array = buf.subarray(he);
        ch.onData = more => { rest = concat(rest, more); };
        const report = () => {
          let msg = `request failed (HTTP ${status})`;
          try { msg = JSON.parse(fromUtf8(rest)).error ?? msg; } catch {}
          fail(new ControlError(msg, status));
        };
        ch.onEOF = report; ch.onClose = report;
        return;
      }
      settled = true;
      clearTimeout(timer);
      const leftover = buf.subarray(he);
      ch.pause();
      ch.onData = () => {};
      ch.onEOF = () => {};
      ch.onClose = () => {};
      // Bytes that came with the header reach the consumer first, on resume().
      if (leftover.length) ch.prepend(leftover.slice());
      resolve(ch);
    };
    ch.onEOF = () => fail(new ControlError('Agent closed during handshake'));
    ch.onClose = () => fail(new ControlError('Agent closed during handshake'));
    ch.resume();
    ch.write(buildRequest(method, path, utf8(JSON.stringify(body)), headers));
  });
}
