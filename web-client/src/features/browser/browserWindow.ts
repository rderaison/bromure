// The globe (⌃⌘B) in the desktop app: the built-in browser window
// (electron/browser.ts). Its page reaches the remote's workspace VMs at their
// own addresses: each connection into the workspace subnet arrives here as a
// flow, rides this window's SSH forward connection (RemoteHost.openForward),
// and its bytes go back and forth through main. The hosted app has no globe.

import { electron, type BrowserBridge } from '../../platform';
import type { RemoteHost } from '../../core/remote/host';
import type { SSHChannel } from '../../core/ssh/client';

const bridge: BrowserBridge | undefined = electron?.browser;
/** Ack page → remote bytes at once while the channel's queue is below this. */
const QUEUE_HIGH = 1 << 20;

/** The host whose SSH carries the browser's flows (this window's). */
let current: RemoteHost | null = null;
let offState: (() => void) | null = null;

export const hasBrowser = !!bridge;

/** Open or focus the browser window for `host` (close it if it's in front). */
export async function toggleBrowser(host: RemoteHost) {
  if (!bridge) return;
  if (current !== host) {
    offState?.();
    current = host;
    let last = host.state?.vmnetSubnet ?? '';
    offState = host.onState(() => {
      const s = host.state?.vmnetSubnet ?? '';
      if (s !== last) { last = s; bridge.setSubnet(s); }
    });
  }
  await bridge.toggle(host.state?.vmnetSubnet ?? '', host.target.name);
}

interface Flow { ch: SSHChannel | null; unacked: number; closed: boolean; paused: boolean; closePending: boolean }
const flows = new Map<number, Flow>();
const finish = (id: number, f: Flow) => { f.closed = true; flows.delete(id); bridge?.flowClose(id); };

if (bridge) {
  bridge.onFlow((id, verb) => {
    const host = current;
    if (!host) { bridge.flowOpened(id, false, 'no server'); return; }
    const f: Flow = { ch: null, unacked: 0, closed: false, paused: false, closePending: false };
    flows.set(id, f);
    host.openForward(verb).then(ch => {
      if (f.closed) { ch.close(); return; }
      f.ch = ch;
      ch.onData = d => bridge.flowData(id, d);
      ch.onEOF = () => bridge.flowEnd(id);
      ch.onClose = () => {
        if (f.closed) return;
        if (f.paused) { f.closePending = true; return; }
        finish(id, f);
      };
      ch.onDrain = () => { if (f.unacked) { bridge.flowAck(id, f.unacked); f.unacked = 0; } };
      ch.resume();
      bridge.flowOpened(id, true);
    }, (e: any) => { flows.delete(id); bridge.flowOpened(id, false, String(e?.message ?? e)); });
  });
  bridge.onFlowData((id, data) => {
    const f = flows.get(id);
    if (!f?.ch) return;
    f.ch.write(data);
    f.unacked += data.length;
    if (f.ch.queuedBytes < QUEUE_HIGH) { bridge.flowAck(id, f.unacked); f.unacked = 0; }
  });
  bridge.onFlowPause((id, paused) => {
    const f = flows.get(id);
    if (!f?.ch) return;
    f.paused = paused;
    if (paused) { f.ch.pause(); return; }
    f.ch.resume();
    if (f.closePending) finish(id, f);
  });
  bridge.onFlowEnd(id => flows.get(id)?.ch?.eof());
  bridge.onFlowClose(id => {
    const f = flows.get(id);
    if (!f) return;
    f.closed = true; flows.delete(id); f.ch?.close();
  });
}
