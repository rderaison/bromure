// electron/acceptedFlow.ts: an accepted loopback connection (the OAuth
// callback listener) is flow-controlled both ways (CWE-400): a local process
// can't make the app buffer without bound.

import { describe, it, expect } from 'vitest';
import net from 'node:net';
import { acceptedFlow, FLOW_HIGH, MAX_BUFFERED, type FlowEvent } from '../electron/acceptedFlow';

async function pair(): Promise<{ server: net.Socket; client: net.Socket; close: () => void }> {
  const srv = net.createServer();
  await new Promise<void>(r => srv.listen(0, '127.0.0.1', () => r()));
  const port = (srv.address() as net.AddressInfo).port;
  const accepted = new Promise<net.Socket>(r => srv.once('connection', r));
  const client = net.connect(port, '127.0.0.1');
  const server = await accepted;
  return { server, client, close: () => { client.destroy(); server.destroy(); srv.close(); } };
}
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

describe('accepted connection flow control', () => {
  it('stops reading with ~1 MB unacked, and passes everything once acked', async () => {
    const { server, client, close } = await pair();
    let got = 0;
    const flow = acceptedFlow(server, e => { if (e.kind === 'data') got += e.data.length; });
    flow.start();
    const total = 6 << 20;
    client.write(Buffer.alloc(total, 7));                  // a local process sending a big body
    await sleep(300);
    // No acks (the SSH channel isn't taking it): reading stopped near HIGH.
    expect(got).toBeGreaterThan(0);
    expect(got).toBeLessThanOrEqual(FLOW_HIGH + (256 << 10));
    // Acking what arrives lets all of it through.
    let acked = got;
    flow.ack(acked);
    for (let i = 0; i < 200 && got < total; i++) { await sleep(10); flow.ack(got - acked); acked = got; }
    expect(got).toBe(total);
    close();
  });

  it('tells the renderer to pause while the local side is full, resume once it reads', async () => {
    const { server, client, close } = await pair();
    const events: FlowEvent['kind'][] = [];
    const flow = acceptedFlow(server, e => { if (e.kind !== 'data') events.push(e.kind); });
    flow.start();
    client.pause();                                         // the local program doesn't read
    for (let i = 0; i < 64 && !events.includes('pause'); i++) { flow.write(new Uint8Array(64 << 10)); await sleep(1); }
    expect(events).toEqual(['pause']);
    client.resume();                                        // now it reads
    for (let i = 0; i < 100 && !events.includes('resume'); i++) await sleep(10);
    expect(events).toEqual(['pause', 'resume']);
    close();
  });

  it('closes a local side that holds more than MAX_BUFFERED unread', async () => {
    const { server, client, close } = await pair();
    const flow = acceptedFlow(server, () => {});
    flow.start();
    client.pause();
    const chunk = new Uint8Array(1 << 20);
    for (let i = 0; i < (MAX_BUFFERED >> 20) + 64 && !server.destroyed; i++) flow.write(chunk);
    expect(server.destroyed).toBe(true);
    close();
  });
});
