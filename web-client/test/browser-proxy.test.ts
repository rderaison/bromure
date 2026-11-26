import { describe, it, expect } from 'vitest';
import net from 'node:net';
import { cidrMatch, validSubnet, pacScript, socksHandshake, toURL } from '../electron/browserProxy';

// The desktop app's built-in browser: only the workspace subnet goes to the
// SOCKS proxy (and from there over SSH); the PAC, the SOCKS handshake and
// the address bar's parsing are checked here.

describe('PAC', () => {
  it('sends only the workspace subnet to the proxy', () => {
    const pac = pacScript('192.168.64.0/24', 4242);
    expect(pac).toContain('isInNet(host, "192.168.64.0", "255.255.255.0")');
    expect(pac).toContain('SOCKS5 127.0.0.1:4242');
    expect(pac).toContain('return "DIRECT"');
  });
  it('a subnet from the remote that is not a plain IPv4 CIDR gives an all-DIRECT PAC', () => {
    for (const bad of ['', '192.168.64.0/8', '1.2.3.4/24"); alert(1); ("', '999.1.1.0/24', '10.0.0.0'])
      expect(pacScript(bad, 4242)).not.toContain('SOCKS5');
    expect(validSubnet('10.20.0.0/16')).toBe(true);
  });
  it('matches addresses inside the subnet only', () => {
    expect(cidrMatch('192.168.64.7', '192.168.64.0/24')).toBe(true);
    expect(cidrMatch('192.168.65.7', '192.168.64.0/24')).toBe(false);
    expect(cidrMatch('example.com', '192.168.64.0/24')).toBe(false);
  });
});

/** Runs the handshake on a local socket pair; resolves to what the
 *  server-side callback saw and the bytes the client got back. */
function handshake(request: Buffer): Promise<{ target?: [string, number]; reply: Buffer }> {
  return new Promise((resolve, reject) => {
    let target: [string, number] | undefined;
    const srv = net.createServer(s => {
      socksHandshake(s, (ip, port) => { target = [ip, port]; s.end(Buffer.from([5, 0, 0, 1, 0, 0, 0, 0, 0, 0])); });
    });
    srv.listen(0, '127.0.0.1', () => {
      const c = net.connect((srv.address() as net.AddressInfo).port, '127.0.0.1');
      const chunks: Buffer[] = [];
      c.on('data', (d: Buffer) => chunks.push(d));
      c.on('end', () => { srv.close(); resolve({ target, reply: Buffer.concat(chunks) }); });
      c.on('error', reject);
      c.write(Buffer.from([5, 1, 0]));
      c.write(request);
    });
  });
}

describe('SOCKS5 handshake', () => {
  it('passes an IPv4 CONNECT through', async () => {
    const r = await handshake(Buffer.from([5, 1, 0, 1, 192, 168, 64, 7, 0x1f, 0x90]));
    expect(r.target).toEqual(['192.168.64.7', 8080]);
    expect([...r.reply.subarray(0, 2)]).toEqual([5, 0]);
  });
  it('passes a domain CONNECT (an IPv4 literal) through as text', async () => {
    const host = Buffer.from('192.168.64.9');
    const r = await handshake(Buffer.concat([Buffer.from([5, 1, 0, 3, host.length]), host, Buffer.from([0, 80])]));
    expect(r.target).toEqual(['192.168.64.9', 80]);
  });
  it('refuses anything but CONNECT', async () => {
    const r = await handshake(Buffer.from([5, 2, 0, 1, 192, 168, 64, 7, 0, 80]));
    expect(r.target).toBeUndefined();
    expect([...r.reply.subarray(2, 4)]).toEqual([5, 7]);   // after the method reply: command not supported
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
