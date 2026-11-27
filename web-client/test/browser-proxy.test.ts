import { describe, it, expect } from 'vitest';
import net from 'node:net';
import { cidrMatch, validSubnet, pacScript, toURL, parseProxyRequest, readProxyHead, PROXY_USER } from '../electron/browserProxy';

// The desktop app's built-in browser: only the workspace subnet goes to the
// SOCKS proxy (and from there over SSH); the PAC, the SOCKS handshake and
// the address bar's parsing are checked here.

describe('PAC', () => {
  it('sends only the workspace subnet to the proxy', () => {
    const pac = pacScript('192.168.64.0/24', 4242);
    expect(pac).toContain('isInNet(host, "192.168.64.0", "255.255.255.0")');
    expect(pac).toContain('PROXY 127.0.0.1:4242');
    expect(pac).toContain('return "DIRECT"');
  });
  it('a subnet from the remote that is not a plain IPv4 CIDR gives an all-DIRECT PAC', () => {
    for (const bad of ['', '192.168.64.0/8', '1.2.3.4/24"); alert(1); ("', '999.1.1.0/24', '10.0.0.0'])
      expect(pacScript(bad, 4242)).not.toContain('PROXY');
    expect(validSubnet('10.20.0.0/16')).toBe(true);
  });
  it('matches addresses inside the subnet only', () => {
    expect(cidrMatch('192.168.64.7', '192.168.64.0/24')).toBe(true);
    expect(cidrMatch('192.168.65.7', '192.168.64.0/24')).toBe(false);
    expect(cidrMatch('example.com', '192.168.64.0/24')).toBe(false);
  });
});

// Regression (CWE-306): the proxy was unauthenticated SOCKS5 on loopback, so
// any local process or user could CONNECT through it to the workspace VMs
// with this user's SSH identity. Now every request must carry this session's
// random credential.
const SECRET = 'f00d'.repeat(12);
const auth = (secret = SECRET) => `Proxy-Authorization: Basic ${Buffer.from(`${PROXY_USER}:${secret}`).toString('base64')}\r\n`;
const req = (s: string) => parseProxyRequest(s, Buffer.alloc(0), SECRET);

describe('loopback proxy', () => {
  it('refuses a request without the credential, or with a wrong one (407)', () => {
    for (const h of ['CONNECT 192.168.64.7:443 HTTP/1.1\r\nHost: 192.168.64.7:443\r\n\r\n',
                     `CONNECT 192.168.64.7:443 HTTP/1.1\r\n${auth('0'.repeat(48))}\r\n`,
                     'GET http://192.168.64.7:8080/ HTTP/1.1\r\nHost: 192.168.64.7:8080\r\n\r\n']) {
      const r = req(h);
      expect(r.kind).toBe('denied');
      if (r.kind === 'denied') expect(r.reply).toMatch(/^HTTP\/1\.1 407 .*Proxy-Authenticate: Basic/s);
    }
    // No secret yet (proxy stopped): nothing is authorized.
    expect(parseProxyRequest(`CONNECT 192.168.64.7:443 HTTP/1.1\r\n${auth('')}\r\n`, Buffer.alloc(0), '').kind).toBe('denied');
  });
  it('tunnels an authorized CONNECT to an IPv4 address', () => {
    const r = parseProxyRequest(`CONNECT 192.168.64.7:443 HTTP/1.1\r\n${auth()}\r\n`, Buffer.from('tls'), SECRET);
    expect(r).toMatchObject({ kind: 'connect', ip: '192.168.64.7', port: 443 });
    if (r.kind === 'connect') expect(r.initial.toString()).toBe('tls');
  });
  it('rewrites an authorized plain-http request to origin form, one request per connection', () => {
    const r = req(`GET http://192.168.64.7:8080/a?b=1 HTTP/1.1\r\nHost: 192.168.64.7:8080\r\n${auth()}Proxy-Connection: keep-alive\r\nConnection: keep-alive\r\n\r\n`);
    expect(r).toMatchObject({ kind: 'http', ip: '192.168.64.7', port: 8080 });
    if (r.kind !== 'http') return;
    const out = r.initial.toString('latin1');
    expect(out.startsWith('GET /a?b=1 HTTP/1.1\r\n')).toBe(true);
    expect(out).not.toMatch(/proxy-/i);                  // the credential never reaches the guest
    expect(out).toContain('Connection: close\r\n');
    expect(out).not.toContain('keep-alive');
  });
  it('keeps an Upgrade (WebSocket) request\'s Connection header', () => {
    const r = req(`GET http://192.168.64.7/ws HTTP/1.1\r\nHost: 192.168.64.7\r\n${auth()}Connection: Upgrade\r\nUpgrade: websocket\r\n\r\n`);
    expect(r).toMatchObject({ kind: 'http', port: 80 });
    if (r.kind === 'http') expect(r.initial.toString()).toContain('Connection: Upgrade');
  });
  it('refuses targets that are not IPv4 literals (403)', () => {
    expect(req(`CONNECT example.com:443 HTTP/1.1\r\n${auth()}\r\n`)).toMatchObject({ kind: 'denied' });
    expect(req(`GET https://192.168.64.7/ HTTP/1.1\r\n${auth()}\r\n`)).toMatchObject({ kind: 'denied' });
  });
  it('reads a request head split across packets, the rest kept', async () => {
    const got = await new Promise<[string, string]>((resolve, reject) => {
      const srv = net.createServer(s => readProxyHead(s, (h, rest) => { resolve([h, rest.toString()]); s.destroy(); srv.close(); }));
      srv.listen(0, '127.0.0.1', () => {
        const c = net.connect((srv.address() as net.AddressInfo).port, '127.0.0.1');
        c.on('error', reject);
        c.write('CONNECT 1.2.3.4:5 HTTP/1.1\r\n');
        setTimeout(() => c.write('X: y\r\n\r\nbody'), 20);
      });
    });
    expect(got).toEqual(['CONNECT 1.2.3.4:5 HTTP/1.1\r\nX: y\r\n\r\n', 'body']);
  });
});

describe('address bar', () => {
  it('turns what was typed into a URL', () => {
    expect(toURL('192.168.64.5:3000')).toBe('http://192.168.64.5:3000');
    expect(toURL('localhost:8080/x')).toBe('http://localhost:8080/x');
    expect(toURL('https://example.com')).toBe('https://example.com');
    expect(toURL('how to use rust')).toMatch(/^https:\/\/duckduckgo\.com\/\?q=how%20to%20use%20rust$/);
    expect(toURL('javascript:alert(1)')).toMatch(/^https:\/\/duckduckgo/);
  });
});
