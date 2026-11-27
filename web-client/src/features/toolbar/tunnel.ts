// The network tunnel toggle's model (Linux desktop app only) — the
// counterpart of the Mac's FatClientController tunnel state machine
// (setTunnelEnabled / startTunnelIfNeeded): direct access to the remote's
// workspace VMs (192.168.x.x) from any local program.
//
// The opt-in is per server and persists. Once on, the tunnel starts as soon
// as the remote reports its workspace subnet (/state `vmnetSubnet`, present
// once a workspace VM has booted) and follows it if it changes. The flows
// themselves come from the main process (electron/tunnel.ts) and ride this
// window's SSH forward connection (RemoteHost.openForward).

import { electron, type TunnelBridge } from '../../platform';
import type { RemoteHost } from '../../core/remote/host';
import type { SSHChannel } from '../../core/ssh/client';
import { showAlert } from '../sidebar/Dialogs';

export type TunnelState = 'off' | 'unavailable' | 'waiting-subnet' | 'starting' | 'active' | 'failed';

const bridge: TunnelBridge | undefined = electron?.tunnel;
/** Ack local → remote bytes at once while the channel's queue is below this;
 *  above it, when the channel drains (main pauses the local socket meanwhile). */
const QUEUE_HIGH = 1 << 20;

export class TunnelController {
  state: TunnelState = 'off';
  /** Why it's unavailable or failed (one line). */
  reason = '';
  private cidr: string | null = null;
  private listeners = new Set<() => void>();
  private offState: (() => void) | null = null;
  private gen = 0;

  constructor(readonly host: RemoteHost) {}

  private get key() { return `bromure.tunnel.${this.host.target.id}`; }
  get enabled(): boolean { try { return localStorage.getItem(this.key) === '1'; } catch { return false; } }
  private set enabled(on: boolean) { try { localStorage.setItem(this.key, on ? '1' : '0'); } catch {} }

  subscribe(l: () => void) { this.listeners.add(l); return () => { this.listeners.delete(l); }; }
  private set(state: TunnelState, reason = '') {
    this.state = state; this.reason = reason;
    for (const l of [...this.listeners]) l();
  }

  /** The window opened: check the helper, then resume an opt-in. */
  async attach() {
    if (!bridge) return;
    // A main process without the tunnel's handlers (screenshot runs) or any
    // other failure: unavailable, not an unhandled rejection.
    const a = await bridge.available().catch((e: any) => ({ ok: false, reason: String(e?.message ?? e) }));
    if (!a.ok) { this.set('unavailable', a.reason ?? ''); return; }
    this.offState = this.host.onState(() => this.followSubnet());
    if (this.enabled) this.startIfNeeded(false);
  }

  /** The window closed: the tunnel goes with it. */
  detach() {
    this.offState?.(); this.offState = null;
    if (active === this) this.stopTunnel();
  }

  /** The toolbar toggle (Mac: on when off or failed, else off). */
  toggle() {
    if (this.state === 'unavailable') return;
    const on = this.state === 'off' || this.state === 'failed';
    this.enabled = on;
    if (on) this.startIfNeeded(true);
    else { this.stopTunnel(); this.set('off'); }
  }

  private followSubnet() {
    const subnet = this.host.state?.vmnetSubnet ?? null;
    if (!this.enabled || subnet === this.cidr) return;
    if (this.state === 'active' || this.state === 'starting') this.stopTunnel();
    this.startIfNeeded(false);
  }

  private async startIfNeeded(interactive: boolean) {
    if (!bridge || !this.enabled || this.state === 'unavailable') return;
    const subnet = this.host.state?.vmnetSubnet;
    if (!subnet) {
      this.cidr = null;
      this.set('waiting-subnet');
      if (interactive) {
        showAlert('Waiting for the remote\'s network info',
          'The remote hasn\'t reported its workspace subnet yet — it does so once a workspace VM is running. The tunnel connects automatically as soon as the subnet arrives; start (or resume) a workspace on the remote to trigger it.',
          [{ label: 'OK', value: 'ok', default: true }]);
      }
      return;
    }
    const gen = ++this.gen;
    this.cidr = subnet;
    this.set('starting');
    if (active && active !== this) active.stopTunnel();
    active = this;
    const r = await bridge.start(subnet);
    if (gen !== this.gen) return;
    if (r.ok) { this.set('active'); return; }
    active = null;
    this.set('failed', r.error ?? '');
    console.warn('tunnel start failed:', r.error);
    if (interactive) {
      showAlert('Couldn\'t start the network tunnel',
        `${r.error ?? 'Unknown error.'}\n\nBromure keeps working without it — the tunnel only adds direct access to the remote's VMs from other local apps.`,
        [{ label: 'OK', value: 'ok', default: true }]);
    }
  }

  private stopTunnel() {
    this.gen++;
    this.cidr = null;
    if (active === this) { active = null; bridge?.stop(); closeAllFlows(); }
  }

  /** The forwarder stopped by itself (helper gone, crash): failed, click retries. */
  onExited(why: string) {
    if (active !== this) return;
    active = null;
    this.cidr = null;
    closeAllFlows();
    this.set('failed', why);
  }
}

// ── flows (one bridge for the app; the active controller's host carries them) ──

let active: TunnelController | null = null;
interface Flow {
  ch: SSHChannel | null; unacked: number; closed: boolean;
  /** Held by main (the local program isn't reading). */
  paused: boolean;
}
const flows = new Map<number, Flow>();

function finishFlow(id: number, f: Flow) {
  f.closed = true;
  flows.delete(id);
  bridge?.flowClose(id);
}

function closeAllFlows() {
  for (const f of flows.values()) { f.closed = true; f.ch?.close(); }
  flows.clear();
}

if (bridge) {
  bridge.onExit(why => active?.onExited(why));
  bridge.onFlow((id, verb) => {
    const c = active;
    if (!c) { bridge.flowOpened(id, false, 'the tunnel is off'); return; }
    const f: Flow = { ch: null, unacked: 0, closed: false, paused: false };
    flows.set(id, f);
    c.host.openForward(verb).then(ch => {
      if (f.closed) { ch.close(); return; }
      f.ch = ch;
      ch.onData = d => bridge.flowData(id, d);
      ch.onEOF = () => bridge.flowEnd(id);
      // A channel closed while held (the server finished, or the SSH
      // connection failed) still has the bytes it buffered and its EOF. They
      // go to main now, then the close, in that order: main ends the local
      // socket after them, and destroys it if the program never reads them.
      // Not waiting for a drain that may never come (the flow, its socket
      // and the forwarder's flow would stay open for good). What's handed
      // over is bounded by the channel's window.
      ch.onClose = () => {
        if (f.closed) return;
        if (f.paused) { f.paused = false; ch.resume(); }
        finishFlow(id, f);
      };
      ch.onDrain = () => { if (f.unacked) { bridge.flowAck(id, f.unacked); f.unacked = 0; } };
      ch.resume();
      bridge.flowOpened(id, true);
    }, (e: any) => {
      flows.delete(id);
      bridge.flowOpened(id, false, e?.message ?? 'couldn\'t reach the remote');
    });
  });
  bridge.onFlowData((id, data) => {
    const f = flows.get(id);
    if (!f?.ch) return;
    f.ch.write(data);
    f.unacked += data.length;
    if (f.ch.queuedBytes < QUEUE_HIGH) { bridge.flowAck(id, f.unacked); f.unacked = 0; }
  });
  // The local program isn't reading: hold the channel (its SSH window then
  // holds the server), resume when main's socket drains.
  bridge.onFlowPause((id, paused) => {
    const f = flows.get(id);
    if (!f?.ch) return;
    f.paused = paused;
    if (paused) { f.ch.pause(); return; }
    f.ch.resume();   // delivers what was held, then its EOF
  });
  bridge.onFlowEnd(id => flows.get(id)?.ch?.eof());
  bridge.onFlowClose(id => {
    const f = flows.get(id);
    if (!f) return;
    f.closed = true; flows.delete(id); f.ch?.close();
  });
}

const controllers = new WeakMap<RemoteHost, TunnelController>();
/** This host's tunnel model; undefined where there's no tunnel (hosted app,
 *  Windows). */
export function tunnelFor(host: RemoteHost): TunnelController | undefined {
  if (!bridge) return undefined;
  let c = controllers.get(host);
  if (!c) { c = new TunnelController(host); controllers.set(host, c); }
  return c;
}
