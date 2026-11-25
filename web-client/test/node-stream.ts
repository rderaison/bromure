// Node-only ByteStream over net.Socket — for tests and live probes.
import net from 'node:net';
import type { ByteStream } from '../src/core/net/stream';

export function nodeTcp(host: string, port: number): Promise<ByteStream> {
  return new Promise((resolve, reject) => {
    const sock = net.connect({ host, port });
    const s: ByteStream = {
      onData: () => {}, onClose: () => {},
      write: d => { sock.write(d); },
      close: () => sock.destroy(),
    };
    sock.on('data', (d: Buffer) => s.onData(new Uint8Array(d)));
    sock.on('close', () => s.onClose());
    sock.on('error', e => s.onClose(e));
    sock.once('connect', () => resolve(s));
    sock.once('error', reject);
  });
}
