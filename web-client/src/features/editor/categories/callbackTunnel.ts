// Electron only: answer a model sign-in's loopback callback on THIS computer
// (127.0.0.1:<port>) and splice each connection to the same port inside the
// host's sign-in VM — the macOS client's RegistrationCallbackTunnel.

import { electron } from '../../../platform';
import { ElectronTcpStream } from '../../../core/net/stream';
import type { RemoteHost } from '../../../core/remote/host';

const handlers = new Map<number, (socketID: number) => void>();
/** Channel queue (bytes the VM's window hasn't taken yet): acks wait above
 *  QUEUE_HIGH; past QUEUE_MAX the connection is closed. */
const QUEUE_HIGH = 1 << 20;
const QUEUE_MAX = 8 << 20;
let wired = false;

/** Whether this client can listen on loopback (the desktop app). */
export const canListenLoopback = () => !!electron?.tcpListen;

/** Listen on 127.0.0.1:<port>; resolves to a stop function, or throws (port
 *  in use…). */
export async function startCallbackTunnel(host: RemoteHost, vmIP: string, port: number): Promise<() => void> {
  const bridge = electron!;
  if (!wired) {
    wired = true;
    bridge.onTcpAccept!((lid, id) => {
      const h = handlers.get(lid);
      if (h) h(id); else ElectronTcpStream.adopt(bridge, id).close();
    });
  }
  const lid = await bridge.tcpListen!(port);
  handlers.set(lid, id => {
    const local = ElectronTcpStream.adopt(bridge, id);
    host.openForward(`forward ${vmIP} ${port}`).then(ch => {
      // Flow control both ways (any local process may connect while a
      // sign-in listens): bytes from the local side are acked to main only
      // once the channel's queue is short (main stops reading with ~1 MB
      // unacked); when the local side is full, the channel is held (its SSH
      // window then holds the VM). A queue past the cap closes the connection.
      let unacked = 0;
      local.onData = d => {
        ch.write(d);
        unacked += d.length;
        if (ch.queuedBytes > QUEUE_MAX) { ch.close(); local.close(); return; }
        if (ch.queuedBytes < QUEUE_HIGH) { local.ack(unacked); unacked = 0; }
      };
      ch.onDrain = () => { if (unacked) { local.ack(unacked); unacked = 0; } };
      local.onPause = paused => { if (paused) ch.pause(); else ch.resume(); };
      local.onClose = () => ch.close();
      ch.onData = d => local.write(d);
      ch.onEOF = () => local.close();
      ch.onClose = () => local.close();
      ch.resume();
      local.start();
    }).catch(() => local.close());
  });
  return () => { handlers.delete(lid); bridge.tcpUnlisten!(lid); };
}
