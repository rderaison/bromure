// Electron only: answer a model sign-in's loopback callback on THIS computer
// (127.0.0.1:<port>) and splice each connection to the same port inside the
// host's sign-in VM — the macOS client's RegistrationCallbackTunnel.

import { electron } from '../../../platform';
import { ElectronTcpStream } from '../../../core/net/stream';
import type { RemoteHost } from '../../../core/remote/host';

const handlers = new Map<number, (socketID: number) => void>();
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
      local.onData = d => ch.write(d);
      local.onClose = () => ch.close();
      ch.onData = d => local.write(d);
      // The VM's answer is complete: close our side (main flushes what we
      // wrote first — see electron/sockClose.ts — never drops it).
      ch.onEOF = () => local.close();
      ch.onClose = () => local.close();
      ch.resume();
      local.start();
    }).catch(() => local.close());
  });
  return () => { handlers.delete(lid); bridge.tcpUnlisten!(lid); };
}
