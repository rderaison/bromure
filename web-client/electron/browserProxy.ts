// Pure helpers of the built-in browser (electron/browser.ts): the PAC, the
// authenticated proxy's request parsing, the address bar's text → URL. No
// Electron here, so the unit tests can load it.

import type net from 'node:net';

const isIPv4 = (s: string) => /^\d{1,3}(\.\d{1,3}){3}$/.test(s) && s.split('.').every(o => +o <= 255);
export function cidrMatch(ip: string, c: string): boolean {
  if (!c || !isIPv4(ip)) return false;
  const toNum = (s: string) => s.split('.').reduce((a, o) => (a << 8) + +o, 0) >>> 0;
  const [net4, bits] = c.split('/');
  const mask = bits === '0' ? 0 : (~0 << (32 - +bits)) >>> 0;
  return ((toNum(ip) & mask) >>> 0) === ((toNum(net4) & mask) >>> 0);
}
/** A /16–/30 IPv4 subnet, as /state's `vmnetSubnet` reports it — anything
 *  else (it comes from the remote) is ignored. */
export function validSubnet(c: string): boolean {
  const m = /^(\d{1,3}(?:\.\d{1,3}){3})\/(\d{1,2})$/.exec(c);
  return !!m && isIPv4(m[1]) && +m[2] >= 16 && +m[2] <= 30;
}

/** FatClientPAC.script: the subnet to our proxy, the rest DIRECT. */
export function pacScript(subnet: string, proxyPort: number): string {
  if (!validSubnet(subnet) || !proxyPort) return 'function FindProxyForURL(url, host) { return "DIRECT"; }';
  const [net4, bits] = subnet.split('/');
  const m = bits === '0' ? 0 : (~0 << (32 - +bits)) >>> 0;
  const mask = [24, 16, 8, 0].map(s => (m >>> s) & 255).join('.');
  return `function FindProxyForURL(url, host) {\n  if (isInNet(host, "${net4}", "${mask}")) return "PROXY 127.0.0.1:${proxyPort}";\n  return "DIRECT";\n}\n`;
}

// ── The loopback HTTP proxy (CWE-306) ──────────────────────────────────────
// It was SOCKS5, which Chromium can only speak unauthenticated: any process
// on the machine — another local user's included — could CONNECT through it
// and reach the workspace VMs with this user's SSH identity. An HTTP proxy
// can demand credentials: every request must carry Proxy-Authorization with
// a random per-session secret that only main knows and only the browser
// page's session answers (its `login` event).

export const PROXY_USER = 'bromure';

export type ProxyRequest =
  | { kind: 'denied'; reply: string }                       // answer it and close
  | { kind: 'connect' | 'http'; ip: string; port: number; initial: Buffer };

const reply = (status: string, extra = '') =>
  `HTTP/1.1 ${status}\r\n${extra}Content-Length: 0\r\nConnection: close\r\n\r\n`;
export const PROXY_407 = reply('407 Proxy Authentication Required', `Proxy-Authenticate: Basic realm="${PROXY_USER}"\r\n`);
export const PROXY_403 = reply('403 Forbidden');
export const PROXY_400 = reply('400 Bad Request');
export const PROXY_502 = reply('502 Bad Gateway');
export const PROXY_200 = 'HTTP/1.1 200 Connection established\r\n\r\n';

/** Constant-time string comparison. */
function same(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

/** Parse one proxy request head (`head` = bytes up to and including the
 *  blank line, `rest` = what followed). Authorizes it against `secret`, then:
 *  CONNECT ip:port → a tunnel; `METHOD http://ip[:port]/path` → the request
 *  rewritten to origin form for the server, proxy headers stripped and
 *  `Connection: close` (each proxy connection then carries one request to
 *  one host — Chromium reuses proxy connections across hosts otherwise),
 *  except for an Upgrade (WebSocket) request, which keeps its Connection. */
export function parseProxyRequest(head: string, rest: Buffer, secret: string): ProxyRequest {
  const lines = head.split('\r\n');
  const [method = '', target = '', version = ''] = (lines[0] ?? '').split(' ');
  if (!/^HTTP\/1\.[01]$/.test(version) || !/^[A-Z]+$/.test(method)) return { kind: 'denied', reply: PROXY_400 };
  const headers = lines.slice(1).filter(l => l !== '');
  const get = (name: string) => headers.find(h => h.toLowerCase().startsWith(name + ':'))?.slice(name.length + 1).trim();
  const auth = get('proxy-authorization') ?? '';
  const want = 'Basic ' + Buffer.from(`${PROXY_USER}:${secret}`).toString('base64');
  if (!secret || !same(auth, want)) return { kind: 'denied', reply: PROXY_407 };
  if (method === 'CONNECT') {
    const m = /^(\d{1,3}(?:\.\d{1,3}){3}):(\d{1,5})$/.exec(target);
    if (!m) return { kind: 'denied', reply: PROXY_403 };
    return { kind: 'connect', ip: m[1], port: +m[2], initial: rest };
  }
  const u = /^http:\/\/(\d{1,3}(?:\.\d{1,3}){3})(?::(\d{1,5}))?(\/[^ ]*)?$/.exec(target);
  if (!u) return { kind: 'denied', reply: PROXY_403 };
  const upgrade = !!get('upgrade');
  const kept = headers.filter(h => {
    const n = h.slice(0, h.indexOf(':')).trim().toLowerCase();
    if (n === 'proxy-authorization' || n === 'proxy-connection') return false;
    if (!upgrade && (n === 'connection' || n === 'keep-alive')) return false;
    return true;
  });
  if (!upgrade) kept.push('Connection: close');
  const out = [`${method} ${u[3] ?? '/'} ${version}`, ...kept, '', ''].join('\r\n');
  return { kind: 'http', ip: u[1], port: u[2] ? +u[2] : 80, initial: Buffer.concat([Buffer.from(out, 'latin1'), rest]) };
}

/** Read a request head off `sock` (≤ 32 KiB), then hand it over. */
export function readProxyHead(sock: net.Socket, done: (head: string, rest: Buffer) => void) {
  let buf = Buffer.alloc(0);
  const onData = (d: Buffer) => {
    buf = Buffer.concat([buf, d]);
    const end = buf.indexOf('\r\n\r\n');
    if (end < 0) { if (buf.length > 32 * 1024) { sock.off('data', onData); sock.destroy(); } return; }
    sock.off('data', onData);
    sock.pause();
    done(buf.subarray(0, end + 4).toString('latin1'), buf.subarray(end + 4));
  };
  sock.on('data', onData);
}

/** What the address bar's text means: a URL, a host[:port] (http), or a search. */
export function toURL(text: string): string {
  const t = text.trim();
  if (!t) return 'about:blank';
  if (/^(https?|about):/i.test(t)) return t;
  if (/^[\w.-]+(:\d{1,5})?(\/.*)?$/.test(t) && (t.includes('.') || t.includes(':') || /^localhost\b/.test(t))) return 'http://' + t;
  return 'https://duckduckgo.com/?q=' + encodeURIComponent(t);
}

