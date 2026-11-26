// Pure helpers of the built-in browser (electron/browser.ts): the PAC, the
// SOCKS5 handshake, the address bar's text → URL. No Electron here, so the
// unit tests can load it.

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

/** FatClientPAC.script: the subnet to our SOCKS server, the rest DIRECT. */
export function pacScript(subnet: string, socksPort: number): string {
  if (!validSubnet(subnet) || !socksPort) return 'function FindProxyForURL(url, host) { return "DIRECT"; }';
  const [net4, bits] = subnet.split('/');
  const m = bits === '0' ? 0 : (~0 << (32 - +bits)) >>> 0;
  const mask = [24, 16, 8, 0].map(s => (m >>> s) & 255).join('.');
  return `function FindProxyForURL(url, host) {\n  if (isInNet(host, "${net4}", "${mask}")) return "SOCKS5 127.0.0.1:${socksPort}";\n  return "DIRECT";\n}\n`;
}

/** SOCKS5 (RFC 1928), no authentication, CONNECT only; IPv4 or a domain
 *  that is an IPv4 literal. `onTarget` gets ip/port and answers yes/no. */
export function socksHandshake(sock: net.Socket, onTarget: (ip: string, port: number, rest: Buffer) => void) {
  let buf = Buffer.alloc(0), stage = 0;
  const fail = (code: number) => { try { sock.end(Buffer.from([5, code, 0, 1, 0, 0, 0, 0, 0, 0])); } catch {} };
  const onData = (d: Buffer) => {
    buf = Buffer.concat([buf, d]);
    if (buf.length > 600) { sock.destroy(); return; }
    if (stage === 0) {
      if (buf.length < 2 || buf.length < 2 + buf[1]) return;
      if (buf[0] !== 5 || !buf.subarray(2, 2 + buf[1]).includes(0)) { sock.end(Buffer.from([5, 0xff])); return; }
      sock.write(Buffer.from([5, 0]));
      buf = buf.subarray(2 + buf[1]); stage = 1;
    }
    if (buf.length < 5) return;
    if (buf[0] !== 5) { sock.destroy(); return; }
    if (buf[1] !== 1) { sock.off('data', onData); fail(7); return; }   // CONNECT only
    let ip = '', end = 0;
    if (buf[3] === 1) { if (buf.length < 10) return; ip = [...buf.subarray(4, 8)].join('.'); end = 8; }
    else if (buf[3] === 3) { const n = buf[4]; if (buf.length < 5 + n + 2) return; ip = buf.subarray(5, 5 + n).toString('latin1'); end = 5 + n; }
    else { sock.off('data', onData); fail(8); return; }
    const p = buf.readUInt16BE(end);
    sock.off('data', onData);
    sock.pause();
    onTarget(ip, p, buf.subarray(end + 2));
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

