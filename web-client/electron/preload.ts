// The narrow bridge the renderer gets (window.bromureElectron) — see
// src/platform.ts ElectronAPI. No Node in the page.
import { contextBridge, ipcRenderer } from 'electron';

const tcpListeners: Array<(id: number, kind: string, data?: Uint8Array, message?: string) => void> = [];
ipcRenderer.on('tcp:event', (_e, id, kind, data, message) => { for (const l of tcpListeners) l(id, kind, data, message); });

contextBridge.exposeInMainWorld('bromureElectron', {
  platform: process.platform,
  appVersion: process.env.npm_package_version ?? '',
  tcpOpen: (host: string, port: number) => ipcRenderer.invoke('tcp:open', host, port),
  tcpWrite: (id: number, data: Uint8Array) => ipcRenderer.send('tcp:write', id, data),
  tcpClose: (id: number) => ipcRenderer.send('tcp:close', id),
  onTcpEvent: (cb: any) => { tcpListeners.push(cb); },
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
  // Screenshot/smoke-test runs only (BROMURE_SHOT set): connect to this host
  // unattended — trust its key, answer one password prompt (e.g. a one-time
  // code), which enrolls this run's key. Never present in a normal launch.
  shotTest: process.env.BROMURE_SHOT && process.env.BROMURE_TEST_HOST ? {
    host: process.env.BROMURE_TEST_HOST, port: +(process.env.BROMURE_TEST_PORT || 2222),
    user: process.env.BROMURE_TEST_USER || '', password: process.env.BROMURE_TEST_PASSWORD || '',
  } : undefined,
});
