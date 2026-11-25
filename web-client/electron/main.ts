// Electron main process (Linux / Windows). Owns what a page can't do:
// raw TCP sockets for direct `address:port` hosts, bromure.io HTTP without
// CORS, the `bromure://` deep link (enrollment), file saves, window controls.
// The renderer is the exact same bundle the hosted app serves.

import { app, BrowserWindow, ipcMain, shell, dialog, net as enet, protocol, session } from 'electron';
import net from 'node:net';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';

const DIST = process.env.BROMURE_DIST ? path.resolve(process.env.BROMURE_DIST) : path.join(__dirname, '..', 'dist');
// Its own data folder — never "Bromure", which on macOS is the Bromure web
// browser app's support directory (and on Linux/Windows would collide with it
// if both are installed).
app.setName('Bromure Client');
app.setPath('userData', path.join(app.getPath('appData'), 'Bromure Client'));

const SHOT = process.env.BROMURE_SHOT;            // screenshot mode (scripts/shot.mjs)

// A closed stdout/stderr (launched from Finder/a desktop entry, or a shot run
// whose parent pipe went away) must never surface as an "Uncaught Exception"
// dialog: logging is best-effort.
for (const s of [process.stdout, process.stderr]) s?.on?.('error', () => {});
const log = (...a: unknown[]) => { try { console.error(...a); } catch {} };
// The dev relay / vite origins are allowed only in dev and screenshot runs.
const DEV_ORIGINS = (process.env.BROMURE_DEV_URL || SHOT)
  ? 'ws://127.0.0.1:5179 http://127.0.0.1:5179 ws://127.0.0.1:5190 http://127.0.0.1:5190' + (process.env.BROMURE_DEV_URL ? ' ws://localhost:5178 http://localhost:5178 ws://127.0.0.1:5178 http://127.0.0.1:5178' : '')
  : '';
let mainWindow: BrowserWindow | null = null;
let pendingDeepLink: string | null = null;

if (!SHOT && !app.requestSingleInstanceLock()) app.quit();
// Screenshot runs are concurrent (several at once): each gets a throwaway
// profile, or they fight over the IndexedDB lock and lose the device key.
// A shot run never outlives its job, whatever happens to the page or its parent.
if (SHOT) {
  const budget = +(process.env.BROMURE_SHOT_DELAY || 4000) + +(process.env.BROMURE_SHOT_AFTER || 1500) + 60000;
  setTimeout(() => { log('shot: timed out'); app.exit(2); }, budget).unref?.();
  process.on('uncaughtException', e => { log('shot:', e); app.exit(3); });
}
// Concurrent shot runs each get their own profile (scripts/shot.mjs creates it
// and deletes it once this process has fully exited — Chromium holds its
// files until then).
const SHOT_PROFILE = SHOT ? (process.env.BROMURE_SHOT_PROFILE || fs.mkdtempSync(path.join(os.tmpdir(), 'bromure-shot-'))) : null;
if (SHOT_PROFILE) app.setPath('userData', SHOT_PROFILE);

protocol.registerSchemesAsPrivileged([{ scheme: 'app', privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: false } }]);

function createWindow(hash = '') {
  const w = new BrowserWindow({
    width: +(process.env.BROMURE_W || 1320), height: +(process.env.BROMURE_H || 944),
    minWidth: 720, minHeight: 480,
    show: !SHOT,
    frame: false,                       // the app draws its own titlebar strip
    backgroundColor: '#FCFCFB',
    title: 'Bromure',
    webPreferences: {
      // BROMURE_AS_WEB=1 (tests): no bridge — the page runs exactly as the hosted app.
      preload: process.env.BROMURE_AS_WEB ? undefined : path.join(__dirname, 'preload.cjs'),
      contextIsolation: true, sandbox: true, nodeIntegration: false, spellcheck: false,
      offscreen: SHOT ? ({ deviceScaleFactor: +(process.env.BROMURE_SCALE || 2) } as any) : false,
    },
  });
  const query = process.env.BROMURE_QUERY ? '?' + process.env.BROMURE_QUERY : '';
  const devURL = process.env.BROMURE_DEV_URL;
  if (devURL) w.loadURL(devURL + query + hash);
  else w.loadURL('app://bromure/index.html' + query + hash);
  w.on('maximize', () => w.webContents.send('win:state', { maximized: true, focused: w.isFocused() }));
  w.on('unmaximize', () => w.webContents.send('win:state', { maximized: false, focused: w.isFocused() }));
  w.on('focus', () => w.webContents.send('win:state', { maximized: w.isMaximized(), focused: true }));
  w.on('blur', () => w.webContents.send('win:state', { maximized: w.isMaximized(), focused: false }));
  w.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:/.test(url)) shell.openExternal(url); return { action: 'deny' }; });
  w.webContents.on('will-navigate', (e, url) => { if (!url.startsWith('app://') && !(devURL && url.startsWith(devURL))) { e.preventDefault(); if (/^https?:/.test(url)) shell.openExternal(url); } });
  if (SHOT) {
    const delay = +(process.env.BROMURE_SHOT_DELAY || 4000);
    w.webContents.once('did-finish-load', () => setTimeout(async () => {
      const js = process.env.BROMURE_SHOT_JS;
      if (js) { await w.webContents.executeJavaScript(js).catch(e => log(e)); await new Promise(r => setTimeout(r, +(process.env.BROMURE_SHOT_AFTER || 1500))); }
      const img = await w.webContents.capturePage();
      fs.writeFileSync(SHOT, img.toPNG());
      try { console.log('shot', SHOT, img.getSize()); } catch {}
      app.quit();
    }, delay));
    w.webContents.on('console-message', (e: any) => { if ((e?.level === 'error' || e?.level === 'warning')) log('[page]', e.message); });
  }
  return w;
}

// ── TCP bridge (direct hosts) ─────────────────────────────────────────────
// The renderer can only reach a host:port the USER approved in a native
// dialog here (persisted) — a compromised page can't turn this into an open
// TCP proxy into the LAN. Sockets belong to the window that opened them.
const sockets = new Map<number, { s: net.Socket; owner: number }>();
let nextSock = 1;
const ALLOWED_FILE = () => path.join(app.getPath('userData'), 'allowed-hosts.json');
function allowedHosts(): Set<string> {
  try { return new Set(JSON.parse(fs.readFileSync(ALLOWED_FILE(), 'utf8'))); } catch { return new Set(); }
}
async function approveHost(e: Electron.IpcMainInvokeEvent, host: string, port: number): Promise<boolean> {
  if (typeof host !== 'string' || !host || host.length > 253 || !Number.isInteger(port) || port < 1 || port > 65535) return false;
  if (SHOT) return true;                      // unattended screenshot / smoke runs
  const key = `${host.toLowerCase()}:${port}`;
  const allowed = allowedHosts();
  if (allowed.has(key)) return true;
  const w = BrowserWindow.fromWebContents(e.sender) ?? undefined;
  const r = await dialog.showMessageBox(w!, {
    type: 'question', buttons: ['Connect', 'Cancel'], defaultId: 0, cancelId: 1,
    message: `Connect to ${host}:${port}?`,
    detail: 'Bromure will open an SSH connection to this address. Only allow servers you added yourself.',
  });
  if (r.response !== 0) return false;
  allowed.add(key);
  try { fs.writeFileSync(ALLOWED_FILE(), JSON.stringify([...allowed])); } catch {}
  return true;
}
ipcMain.handle('tcp:open', async (e, host: string, port: number) => {
  if (!(await approveHost(e, host, port))) throw new Error('Connection not allowed.');
  return new Promise<number>((resolve, reject) => {
    const id = nextSock++;
    const s = net.connect({ host, port });
    s.setNoDelay(true);
    s.setKeepAlive(true, 30000);
    const wc = e.sender;
    s.once('connect', () => { sockets.set(id, { s, owner: wc.id }); resolve(id); });
    s.once('error', err => { if (!sockets.has(id)) reject(new Error(friendlyNetError(err, host, port))); else wc.send('tcp:event', id, 'error', null, err.message); });
    s.on('data', (d: Buffer) => { if (!wc.isDestroyed()) wc.send('tcp:event', id, 'data', new Uint8Array(d)); });
    s.on('close', () => { sockets.delete(id); if (!wc.isDestroyed()) wc.send('tcp:event', id, 'close'); });
    s.setTimeout(15000, () => { if (!sockets.has(id)) { s.destroy(); reject(new Error(`Timed out reaching ${host}:${port}`)); } else s.setTimeout(0); });
  });
});
const owned = (e: Electron.IpcMainEvent, id: number) => { const x = sockets.get(id); return x && x.owner === e.sender.id ? x.s : undefined; };
ipcMain.on('tcp:write', (e, id: number, data: Uint8Array) => { owned(e, id)?.write(data); });
ipcMain.on('tcp:close', (e, id: number) => { const s = owned(e, id); if (s) { s.destroy(); sockets.delete(id); } });

function friendlyNetError(err: any, host: string, port: number) {
  switch (err?.code) {
    case 'ECONNREFUSED': return `${host}:${port} refused the connection — is Remote Access on?`;
    case 'ENOTFOUND': return `Can't find ${host}.`;
    case 'EHOSTUNREACH': case 'ENETUNREACH': return `${host} isn't reachable from this network.`;
    case 'ETIMEDOUT': return `Timed out reaching ${host}:${port}`;
    default: return err?.message ?? 'Connection failed';
  }
}

// ── bromure.io HTTP (no CORS from the main process) ────────────────────────
const ALLOWED_API = /^https:\/\/([a-z0-9-]+\.)*bromure\.io\//;
ipcMain.handle('http', async (_e, url: string, init: { method: string; headers: Record<string, string>; body?: string }) => {
  if (!ALLOWED_API.test(url) && !process.env.BROMURE_API_DEV) throw new Error('blocked: ' + url);
  const r = await enet.fetch(url, { method: init.method, headers: init.headers, body: init.body });
  let json: any = {};
  try { json = await r.json(); } catch {}
  return { status: r.status, json };
});

ipcMain.on('open-external', (_e, url: string) => { if (/^https?:\/\//.test(url)) shell.openExternal(url); });
ipcMain.on('win', (e, action: string) => {
  const w = BrowserWindow.fromWebContents(e.sender); if (!w) return;
  if (action === 'close') w.close(); else if (action === 'minimize') w.minimize();
  else if (action === 'maximize') w.isMaximized() ? w.unmaximize() : w.maximize();
});
ipcMain.on('set-title', (e, t: string) => BrowserWindow.fromWebContents(e.sender)?.setTitle(t));
ipcMain.handle('save-file', async (e, name: string, data: Uint8Array) => {
  const w = BrowserWindow.fromWebContents(e.sender)!;
  const r = await dialog.showSaveDialog(w, { defaultPath: name });
  if (r.canceled || !r.filePath) return false;
  fs.writeFileSync(r.filePath, Buffer.from(data));
  return true;
});
ipcMain.handle('deeplink:pending', () => { const d = pendingDeepLink; pendingDeepLink = null; return d; });

function handleDeepLink(url: string) {
  if (!url.startsWith('bromure://')) return;
  if (mainWindow) { mainWindow.webContents.send('deeplink', url); if (mainWindow.isMinimized()) mainWindow.restore(); mainWindow.focus(); }
  else pendingDeepLink = url;
}
app.on('second-instance', (_e, argv) => { const u = argv.find(a => a.startsWith('bromure://')); if (u) handleDeepLink(u); });
app.on('open-url', (e, url) => { e.preventDefault(); handleDeepLink(url); });

app.whenReady().then(() => {
  // Serve the bundle from app:// (a real origin: IndexedDB/WebCrypto persist,
  // CSP applies) instead of file://.
  protocol.handle('app', req => {
    const u = new URL(req.url);
    let p = path.normalize(decodeURIComponent(u.pathname)).replace(/^([/\\])+/, '');
    const file = path.resolve(DIST, p || 'index.html');
    if (file !== DIST && !file.startsWith(DIST + path.sep)) return new Response('forbidden', { status: 403 });
    return enet.fetch('file://' + (fs.existsSync(file) ? file : path.join(DIST, 'index.html')));
  });
  session.defaultSession.webRequest.onHeadersReceived((details, cb) => {
    cb({ responseHeaders: { ...details.responseHeaders,
      'Content-Security-Policy': ["default-src 'self'; script-src 'self'" + (process.env.BROMURE_DEV_URL ? " 'unsafe-inline'" : '') + "; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' https://bromure.io wss://bromure.io" + (DEV_ORIGINS ? ' ' + DEV_ORIGINS : '')] } });
  });
  const argLink = process.argv.find(a => a.startsWith('bromure://'));
  if (argLink) pendingDeepLink = argLink;
  mainWindow = createWindow(process.env.BROMURE_HASH || '');
  mainWindow.on('closed', () => { mainWindow = null; });
});
app.on('window-all-closed', () => app.quit());
