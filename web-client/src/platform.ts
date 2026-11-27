// What differs between the two shells — and nothing else. The UI above this
// is byte-for-byte the same in Electron and in the hosted app.
//
//   Electron (Linux/Windows): direct TCP to `address:port` hosts through the
//     main process; bromure.io calls from the main process (no CORS); peer
//     servers via the bromure.io ws-relay; `bromure://enroll` deep links.
//   Hosted (https://bromure.io/client/): no raw sockets — every server is a
//     bromure.io peer reached through the ws-relay; same-origin API calls;
//     enrollment returns to `/client/#enroll?…`.
//   Dev (vite / ?dev=…): a local ws→tcp relay (scripts/dev-relay.mjs) stands in
//     for bromure.io so the page can reach the demo server.

import { ElectronTcpStream, WebSocketStream, type ByteStream, type ElectronNetBridge } from './core/net/stream';
import { defaultHttp, type HttpFn } from './core/cloud/controlPlane';

export interface ElectronAPI extends ElectronNetBridge {
  platform: 'linux' | 'win32' | 'darwin';
  http: HttpFn;
  openExternal(url: string): void;
  onDeepLink(cb: (url: string) => void): void;
  windowControl(action: 'close' | 'minimize' | 'maximize'): void;
  onWindowState(cb: (s: { maximized: boolean; focused: boolean }) => void): void;
  saveFile(name: string, data: Uint8Array): Promise<boolean>;
  setTitle(t: string): void;
  appVersion: string;
  /** The system-wide network tunnel (Linux desktop app only; absent on
   *  Windows and in the hosted app): the remote's workspace subnet routed
   *  from this machine, each flow carried over the window's SSH. */
  tunnel?: TunnelBridge;
  /** The built-in browser window (desktop app): see electron/browser.ts. */
  browser?: BrowserBridge;
  /** Smoke-test hook, only in Electron screenshot runs (see preload.ts). */
  shotTest?: { host: string; port: number; user: string; password: string };
}

/** Main process ⇄ renderer for the tunnel (electron/main.ts). The forwarder
 *  (bromure-client-tunnel) opens one local stream per flow; main hands each
 *  to the renderer as `onFlow(id, verb)`, the renderer opens the SSH channel
 *  and answers `flowOpened`. Bytes: local → remote via `onFlowData` (acked
 *  with `flowAck` once the channel took them), remote → local via
 *  `flowData` (main says `onFlowPause` while the local side is full). */
export interface TunnelBridge {
  /** Whether the tunnel can run here, and if not, why (one line). */
  available(): Promise<{ ok: boolean; reason?: string }>;
  start(cidr: string): Promise<{ ok: boolean; ifname?: string; error?: string }>;
  stop(): void;
  /** The forwarder stopped on its own (the helper went away, a crash). */
  onExit(cb: (why: string) => void): void;
  onFlow(cb: (id: number, verb: string) => void): void;
  flowOpened(id: number, ok: boolean, error?: string): void;
  onFlowData(cb: (id: number, data: Uint8Array) => void): void;
  flowAck(id: number, bytes: number): void;
  flowData(id: number, data: Uint8Array): void;
  onFlowPause(cb: (id: number, paused: boolean) => void): void;
  /** The local side finished sending (half-close) / the remote side did. */
  onFlowEnd(cb: (id: number) => void): void;
  flowEnd(id: number): void;
  onFlowClose(cb: (id: number) => void): void;
  flowClose(id: number): void;
}

/** Main process ⇄ renderer for the built-in browser: its loopback proxy hands
 *  each connection into the workspace subnet over as a flow, exactly like
 *  TunnelBridge's (open the SSH channel, answer `flowOpened`, then bytes). */
export interface BrowserBridge {
  /** Open (or focus) the browser window; close it if it's the focused one. */
  toggle(subnet: string, title: string): Promise<{ ok: boolean; open?: boolean }>;
  setSubnet(subnet: string): void;
  onFlow(cb: (id: number, verb: string) => void): void;
  flowOpened(id: number, ok: boolean, error?: string): void;
  onFlowData(cb: (id: number, data: Uint8Array) => void): void;
  flowAck(id: number, bytes: number): void;
  flowData(id: number, data: Uint8Array): void;
  onFlowPause(cb: (id: number, paused: boolean) => void): void;
  onFlowEnd(cb: (id: number) => void): void;
  flowEnd(id: number): void;
  onFlowClose(cb: (id: number) => void): void;
  flowClose(id: number): void;
}

declare global { interface Window { bromureElectron?: ElectronAPI } }

export type Shell = 'electron' | 'web';

export const electron = typeof window !== 'undefined' ? window.bromureElectron : undefined;
export const shell: Shell = electron ? 'electron' : 'web';

const params = typeof location !== 'undefined' ? new URLSearchParams(location.search) : new URLSearchParams();
/** Dev relay base (ws://127.0.0.1:5179) when running against the demo server. */
export const devRelay: string | null = params.get('devRelay') ?? (import.meta.env?.DEV ? 'ws://127.0.0.1:5179' : null);

export const http: HttpFn = electron ? electron.http : defaultHttp;

/** Direct TCP is only possible in Electron (and, in dev, through the relay). */
export const canDialDirect = !!electron || !!devRelay;

export async function dialDirect(address: string, port: number): Promise<ByteStream> {
  if (electron) return ElectronTcpStream.open(electron, address, port);
  if (devRelay) return WebSocketStream.open(`${devRelay}/ssh?host=${encodeURIComponent(address)}&port=${port}`);
  throw new Error('Direct connections need the desktop app. Connect through your bromure.io account instead.');
}

export function openExternal(url: string) {
  if (electron) electron.openExternal(url);
  else window.open(url, '_blank', 'noopener,noreferrer');
}

/** Save bytes as a file (Export… buttons). */
export async function saveFile(name: string, data: Uint8Array | string, mime = 'application/octet-stream') {
  const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : data;
  if (electron) return electron.saveFile(name, bytes);
  const url = URL.createObjectURL(new Blob([bytes as BlobPart], { type: mime }));
  const a = document.createElement('a');
  a.href = url; a.download = name; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 5000);
  return true;
}

export const isMac = electron ? electron.platform === 'darwin' : (navigator.platform || '').toLowerCase().includes('mac');
/** ⌘ on macOS, Ctrl elsewhere — shortcuts display the platform's modifier. */
export const modKey = isMac ? '⌘' : 'Ctrl+';
export function isMod(e: KeyboardEvent | React.KeyboardEvent) { return isMac ? e.metaKey : e.ctrlKey; }

export const API_BASE = (import.meta.env?.VITE_BROMURE_API as string | undefined) ?? 'https://bromure.io/api';
export const SITE_BASE = (import.meta.env?.VITE_BROMURE_SITE as string | undefined) ?? 'https://bromure.io';
