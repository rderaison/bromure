// The narrow bridge the renderer gets (window.bromureElectron) — see
// src/platform.ts ElectronAPI. No Node in the page.
import { contextBridge, ipcRenderer } from 'electron';

const tcpListeners: Array<(id: number, kind: string, data?: Uint8Array, message?: string) => void> = [];
ipcRenderer.on('tcp:event', (_e, id, kind, data, message) => { for (const l of tcpListeners) l(id, kind, data, message); });
const acceptListeners: Array<(listenerID: number, socketID: number) => void> = [];
ipcRenderer.on('tcp:accept', (_e, lid, id) => { for (const l of acceptListeners) l(lid, id); });

contextBridge.exposeInMainWorld('bromureElectron', {
  platform: process.platform,
  appVersion: process.env.npm_package_version ?? '',
  tcpOpen: (host: string, port: number) => ipcRenderer.invoke('tcp:open', host, port),
  tcpWrite: (id: number, data: Uint8Array) => ipcRenderer.send('tcp:write', id, data),
  tcpClose: (id: number) => ipcRenderer.send('tcp:close', id),
  onTcpEvent: (cb: any) => { tcpListeners.push(cb); },
  tcpListen: (port: number) => ipcRenderer.invoke('tcp:listen', port),
  tcpUnlisten: (id: number) => ipcRenderer.send('tcp:unlisten', id),
  tcpResume: (id: number) => ipcRenderer.send('tcp:resume', id),
  tcpAck: (id: number, n: number) => ipcRenderer.send('tcp:ack', id, n),
  onTcpAccept: (cb: any) => { acceptListeners.push(cb); },
  http: (url: string, init: any) => ipcRenderer.invoke('http', url, init),
  openExternal: (url: string) => ipcRenderer.send('open-external', url),
  onDeepLink: (cb: (url: string) => void) => {
    ipcRenderer.on('deeplink', (_e, url) => cb(url));
    ipcRenderer.invoke('deeplink:pending').then(u => { if (u) cb(u); });
  },
  windowControl: (a: string) => ipcRenderer.send('win', a),
  onWindowState: (cb: any) => ipcRenderer.on('win:state', (_e, s) => cb(s)),
  saveFile: (name: string, data: Uint8Array) => ipcRenderer.invoke('save-file', name, data),
  setTitle: (t: string) => ipcRenderer.send('set-title', t),
  // The network tunnel: Linux only (the helper and forwarder are Linux
  // programs); the renderer hides the toggle when this is absent.
  tunnel: process.platform === 'linux' ? {
    available: () => ipcRenderer.invoke('tunnel:available'),
    start: (cidr: string) => ipcRenderer.invoke('tunnel:start', cidr),
    stop: () => ipcRenderer.send('tunnel:stop'),
    onExit: (cb: (why: string) => void) => { ipcRenderer.on('tunnel:exit', (_e, why) => cb(why)); },
    onFlow: (cb: any) => { ipcRenderer.on('tunnel:flow', (_e, id, verb) => cb(id, verb)); },
    flowOpened: (id: number, ok: boolean, error?: string) => ipcRenderer.send('tunnel:flow-opened', id, ok, error),
    onFlowData: (cb: any) => { ipcRenderer.on('tunnel:flow-data', (_e, id, data) => cb(id, data)); },
    flowAck: (id: number, n: number) => ipcRenderer.send('tunnel:flow-ack', id, n),
    flowData: (id: number, data: Uint8Array) => ipcRenderer.send('tunnel:flow-recv', id, data),
    onFlowPause: (cb: any) => { ipcRenderer.on('tunnel:flow-pause', (_e, id, p) => cb(id, p)); },
    onFlowEnd: (cb: any) => { ipcRenderer.on('tunnel:flow-end', (_e, id) => cb(id)); },
    flowEnd: (id: number) => ipcRenderer.send('tunnel:flow-eof', id),
    onFlowClose: (cb: any) => { ipcRenderer.on('tunnel:flow-close', (_e, id) => cb(id)); },
    flowClose: (id: number) => ipcRenderer.send('tunnel:flow-destroy', id),
  } : undefined,
  // The built-in browser window (electron/browser.ts): its page reaches the
  // workspace subnet through flows this renderer carries over SSH.
  browser: {
    toggle: (subnet: string, title: string) => ipcRenderer.invoke('browser:toggle', subnet, title),
    setSubnet: (subnet: string) => ipcRenderer.send('browser:subnet', subnet),
    onFlow: (cb: any) => { ipcRenderer.on('browser:flow', (_e, id, verb) => cb(id, verb)); },
    flowOpened: (id: number, ok: boolean, error?: string) => ipcRenderer.send('browser:flow-opened', id, ok, error),
    onFlowData: (cb: any) => { ipcRenderer.on('browser:flow-data', (_e, id, data) => cb(id, data)); },
    flowAck: (id: number, n: number) => ipcRenderer.send('browser:flow-ack', id, n),
    flowData: (id: number, data: Uint8Array) => ipcRenderer.send('browser:flow-recv', id, data),
    onFlowPause: (cb: any) => { ipcRenderer.on('browser:flow-pause', (_e, id, p) => cb(id, p)); },
    onFlowEnd: (cb: any) => { ipcRenderer.on('browser:flow-end', (_e, id) => cb(id)); },
    flowEnd: (id: number) => ipcRenderer.send('browser:flow-eof', id),
    onFlowClose: (cb: any) => { ipcRenderer.on('browser:flow-close', (_e, id) => cb(id)); },
    flowClose: (id: number) => ipcRenderer.send('browser:flow-destroy', id),
  },
  // Screenshot/smoke-test runs only (BROMURE_SHOT set): connect to this host
  // unattended — trust its key, answer one password prompt (e.g. a one-time
  // code), which enrolls this run's key. Never present in a normal launch.
  shotTest: process.env.BROMURE_SHOT && process.env.BROMURE_TEST_HOST ? {
    host: process.env.BROMURE_TEST_HOST, port: +(process.env.BROMURE_TEST_PORT || 2222),
    user: process.env.BROMURE_TEST_USER || '', password: process.env.BROMURE_TEST_PASSWORD || '',
  } : undefined,
});
