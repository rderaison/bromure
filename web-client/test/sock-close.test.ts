import { describe, it, expect } from 'vitest';
import net from 'node:net';
import { closeGracefully } from '../electron/sockClose';

// Regression: the renderer's tcp:close destroyed the socket, discarding writes
// still queued for a slow reader (a browser reading an OAuth callback's
// answer got it truncated, or a reset). Closing now flushes them first.

/** Server writes `size` bytes then closes with `close`; a paused client
 *  reads only after the close was issued. Resolves to the bytes it got. */
function transfer(close: (s: net.Socket) => void, size: number): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = net.createServer(s => {
      s.write(Buffer.alloc(size, 0x61));
      close(s);                                  // immediately: most bytes are still queued
    });
    srv.listen(0, '127.0.0.1', () => {
      const c = net.connect((srv.address() as net.AddressInfo).port, '127.0.0.1');
      let got = 0;
      c.pause();                                 // a slow reader
      setTimeout(() => { c.on('data', d => { got += d.length; }); c.resume(); }, 200);
      c.on('end', () => { srv.close(); resolve(got); });
      c.on('error', () => { srv.close(); resolve(got); });
      c.on('close', () => { srv.close(); resolve(got); });
      setTimeout(() => reject(new Error('timeout')), 10000);
    });
  });
}

describe('closeGracefully', () => {
  const SIZE = 16 * 1024 * 1024;                 // well past the kernel's socket buffers

  it('delivers every queued byte before closing', async () => {
    expect(await transfer(s => closeGracefully(s), SIZE)).toBe(SIZE);
  });

  it('(what destroy() did: the reader loses the tail)', async () => {
    expect(await transfer(s => s.destroy(), SIZE)).toBeLessThan(SIZE);
  });

  it('still destroys a peer that never finishes', async () => {
    await new Promise<void>((resolve, reject) => {
      const srv = net.createServer(s => {
        closeGracefully(s, 300);
        s.once('close', () => { srv.close(); resolve(); });
      });
      srv.listen(0, '127.0.0.1', () => {
        const c = net.connect({ port: (srv.address() as net.AddressInfo).port, host: '127.0.0.1', allowHalfOpen: true });
        c.on('error', () => {});
        setTimeout(() => reject(new Error('not destroyed')), 5000);
      });
    });
  });
});
