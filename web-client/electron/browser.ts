// The desktop app's built-in browser — the macOS fat client's browser pane
// (BrowserPane.swift + FatClientPAC), minus the local browser VM: a window
// with an address bar whose page reaches the remote's workspace VMs at their
// literal addresses (http://192.168.64.x:port), everything else directly.
//
//   the page's session: in memory (nothing persists past the app), its proxy
//     a PAC sending only the workspace subnet to our SOCKS5 server, the rest
//     DIRECT — as FatClientPAC.script does for the browser VM;
//   the SOCKS5 server (127.0.0.1, ephemeral port): each CONNECT inside that
//     subnet becomes a flow to the main window's renderer, which owns the SSH
//     connection and the device key, and opens `bromure-fatclient/1 forward
//     <ip> <port>` on its forward connection; the bytes ride IPC both ways.
//     Anything outside the subnet is refused (the PAC never sends it here).
//
// Backpressure as in tunnel.ts: local → remote at most FLOW_HIGH bytes in
// flight before the socket is paused; remote → local the renderer pauses the
// channel while the socket is full.

import { BrowserWindow, WebContentsView, ipcMain, session, shell, type WebContents } from 'electron';
import net from 'node:net';
import { cidrMatch, validSubnet, pacScript, socksHandshake, toURL } from './browserProxy';

const FLOW_HIGH = 1 << 20;
const FLOW_LOW = 256 << 10;
const PARTITION = 'bromure-browser';     // no `persist:` — gone when the app quits
const BAR_H = 40;

interface Flow { sock: net.Socket; inflight: number; paused: boolean; opened: boolean }

let owner: WebContents | null = null;
let cidr = '';
let server: net.Server | null = null;
let port = 0;
let win: BrowserWindow | null = null;
let page: WebContentsView | null = null;
let bar: WebContentsView | null = null;
const flows = new Map<number, Flow>();
let nextFlow = 1;

function send(channel: string, ...args: unknown[]) {
  if (owner && !owner.isDestroyed()) owner.send(channel, ...args);
}

function acceptSocks(sock: net.Socket) {
  sock.on('error', () => {});
  // Generous: the first flow also sets up the SSH forward connection.
  sock.setTimeout(60000, () => sock.destroy());
  socksHandshake(sock, (ip, p, rest) => {
    const refuse = (code: number) => { try { sock.end(Buffer.from([5, code, 0, 1, 0, 0, 0, 0, 0, 0])); } catch {} };
    // Only the workspace subnet, only while a renderer serves the flows.
    if (!cidrMatch(ip, cidr) || p < 1 || p > 65535) { refuse(2); return; }
    if (!owner || owner.isDestroyed()) { refuse(1); return; }
    const id = nextFlow++;
    flows.set(id, { sock, inflight: 0, paused: false, opened: false });
    if (rest.length) sock.unshift(rest);
    sock.on('close', () => { if (flows.delete(id)) send('browser:flow-close', id); });
    if (process.env.BROMURE_BROWSER_DEBUG) console.error(`[browser] flow ${id} → ${ip}:${p}`);
    send('browser:flow', id, `forward ${ip} ${p}`);
  });
}

function flowOpened(id: number, ok: boolean, error?: string) {
  if (process.env.BROMURE_BROWSER_DEBUG) console.error(`[browser] flow ${id} ${ok ? 'open' : 'refused: ' + error}`);
  const f = flows.get(id);
  if (!f) return;
  if (!ok) { flows.delete(id); try { f.sock.end(Buffer.from([5, 5, 0, 1, 0, 0, 0, 0, 0, 0])); } catch {} return; }
  f.opened = true;
  f.sock.setTimeout(0);
  f.sock.write(Buffer.from([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]));
  f.sock.on('data', (d: Buffer) => {
    send('browser:flow-data', id, new Uint8Array(d.buffer, d.byteOffset, d.length));
    f.inflight += d.length;
    if (f.inflight > FLOW_HIGH && !f.paused) { f.paused = true; f.sock.pause(); }
  });
  f.sock.on('end', () => send('browser:flow-end', id));
  f.sock.on('drain', () => send('browser:flow-pause', id, false));
  f.sock.resume();
}

async function ensureServer() {
  if (server) return;
  const s = net.createServer({ allowHalfOpen: true }, acceptSocks);
  await new Promise<void>((resolve, reject) => { s.once('error', reject); s.listen(0, '127.0.0.1', () => resolve()); });
  server = s;
  port = (s.address() as net.AddressInfo).port;
}

async function applyProxy() {
  const ses = session.fromPartition(PARTITION);
  const pac = pacScript(cidr, port);
  await ses.setProxy({ mode: 'pac_script', pacScript: 'data:application/x-ns-proxy-autoconfig;base64,' + Buffer.from(pac).toString('base64') });
  await ses.closeAllConnections();
}

// The address bar: a small local page with no preload. It talks to us by
// setting its own document title (`go=…`, `back`, … — a data: page can't
// change its fragment); we answer by calling its setState().
const BAR_HTML = `<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
<style>
:root { color-scheme: light dark; }
body { margin: 0; height: ${BAR_H}px; display: flex; align-items: center; gap: 4px; padding: 0 8px; box-sizing: border-box;
  font: 13px system-ui, -apple-system, 'Segoe UI', sans-serif; background: Canvas; color: CanvasText; border-bottom: 1px solid color-mix(in srgb, CanvasText 12%, transparent); }
button { width: 28px; height: 26px; border: none; border-radius: 6px; background: transparent; color: inherit; font-size: 15px; line-height: 1; }
button:hover:not(:disabled) { background: color-mix(in srgb, CanvasText 8%, transparent); }
button:disabled { opacity: .35; }
input { flex: 1; height: 26px; border-radius: 7px; border: 1px solid color-mix(in srgb, CanvasText 15%, transparent); padding: 0 10px;
  background: color-mix(in srgb, CanvasText 4%, Canvas); color: inherit; font: inherit; outline: none; }
input:focus { border-color: AccentColor; }
.note { font-size: 11px; opacity: .6; white-space: nowrap; }
</style></head><body>
<button id="b" title="Back" disabled>&#8249;</button><button id="f" title="Forward" disabled>&#8250;</button><button id="r" title="Reload">&#8635;</button>
<input id="u" spellcheck="false" placeholder="Address — workspace machines answer at their own addresses">
<span class="note" id="n"></span>
<script>
const say = c => { document.title = c + '|' + Date.now(); };
b.onclick = () => say('back'); f.onclick = () => say('forward'); r.onclick = () => say('reload');
u.onkeydown = e => { if (e.key === 'Enter') { say('go=' + encodeURIComponent(u.value)); u.blur(); } if (e.key === 'Escape') u.blur(); };
u.onfocus = () => setTimeout(() => u.select(), 0);
window.setState = s => { if (document.activeElement !== u) u.value = s.url; b.disabled = !s.back; f.disabled = !s.forward; n.textContent = s.note || ''; };
window.focusAddress = () => { u.focus(); };
</script></body></html>`;

function syncBar() {
  if (!bar || !page || page.webContents.isDestroyed()) return;
  const wc = page.webContents, h = wc.navigationHistory;
  const url = wc.getURL();
  const state = { url: url === 'about:blank' ? '' : url, back: h.canGoBack(), forward: h.canGoForward(), note: validSubnet(cidr) ? `via SSH: ${cidr}` : '' };
  bar.webContents.executeJavaScript(`window.setState && window.setState(${JSON.stringify(state)})`).catch(() => {});
  if (win && !win.isDestroyed()) win.setTitle(wc.getTitle() && url !== 'about:blank' ? `${wc.getTitle()} — Browser` : 'Browser');
}

function layout() {
  if (!win || !page || !bar) return;
  const [w, h] = win.getContentSize();
  bar.setBounds({ x: 0, y: 0, width: w, height: BAR_H });
  page.setBounds({ x: 0, y: BAR_H, width: w, height: Math.max(0, h - BAR_H) });
}

function openWindow(parent: BrowserWindow | null, title: string) {
  if (win && !win.isDestroyed()) { win.show(); win.focus(); return; }
  const w = new BrowserWindow({ width: 1200, height: 820, title: `Browser — ${title}`, backgroundColor: '#ffffff', autoHideMenuBar: true,
    webPreferences: { sandbox: true, contextIsolation: true, nodeIntegration: false } });
  win = w;
  const strict = { sandbox: true, contextIsolation: true, nodeIntegration: false, webSecurity: true, webviewTag: false };
  // Its own in-memory session: the default one carries the app's CSP, which
  // (rightly) forbids the bar's inline script.
  bar = new WebContentsView({ webPreferences: { ...strict, partition: 'bromure-browser-bar' } });
  page = new WebContentsView({ webPreferences: { ...strict, partition: PARTITION } });
  w.contentView.addChildView(bar);
  w.contentView.addChildView(page);
  layout();
  w.on('resize', layout);
  // The proxy lives only while a browser window does.
  w.on('closed', () => {
    win = null; page = null; bar = null;
    for (const f of flows.values()) f.sock.destroy();
    flows.clear();
    server?.close(); server = null; port = 0;
  });

  const ses = session.fromPartition(PARTITION);
  // No camera, microphone, notifications, … for pages in here.
  ses.setPermissionRequestHandler((_wc, _perm, cb) => cb(false));
  ses.setPermissionCheckHandler(() => false);

  const bwc = bar.webContents;
  bwc.setWindowOpenHandler(() => ({ action: 'deny' }));
  bwc.on('will-navigate', e => e.preventDefault());
  bwc.on('page-title-updated', (e, title) => {
    e.preventDefault();
    const cmd = title.replace(/\|\d+$/, '');
    const pw = page?.webContents; if (!pw) return;
    if (cmd === 'back') pw.navigationHistory.goBack();
    else if (cmd === 'forward') pw.navigationHistory.goForward();
    else if (cmd === 'reload') pw.reload();
    else if (cmd.startsWith('go=')) { pw.loadURL(toURL(decodeURIComponent(cmd.slice(3)))).catch(() => {}); pw.focus(); }
  });
  bwc.on('did-finish-load', () => { syncBar(); bwc.executeJavaScript('window.focusAddress()').catch(() => {}); });
  bwc.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(BAR_HTML));

  const pwc = page.webContents;
  // Links that open a window load here instead; other schemes go to the OS.
  pwc.setWindowOpenHandler(({ url }) => {
    if (/^https?:/i.test(url)) pwc.loadURL(url).catch(() => {});
    else if (/^mailto:/i.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  pwc.on('will-navigate', (e, url) => { if (!/^(https?|about|data|blob):/i.test(url)) { e.preventDefault(); } });
  for (const ev of ['did-navigate', 'did-navigate-in-page', 'page-title-updated', 'did-stop-loading'] as const) pwc.on(ev as any, syncBar);
  pwc.loadURL('about:blank');
  void parent;
}

/** Wires the IPC. Only the main window's renderer may drive the browser. */
export function setupBrowser(mainWindow: () => BrowserWindow | null) {
  const fromMain = (e: Electron.IpcMainEvent | Electron.IpcMainInvokeEvent) => e.sender === mainWindow()?.webContents;
  ipcMain.handle('browser:toggle', async (e, subnet: string, title: string) => {
    if (!fromMain(e)) return { ok: false };
    if (win && !win.isDestroyed() && win.isVisible() && win.isFocused()) { win.close(); return { ok: true, open: false }; }
    owner = e.sender;
    cidr = validSubnet(String(subnet ?? '')) ? String(subnet) : '';
    await ensureServer();
    await applyProxy();
    openWindow(mainWindow(), String(title ?? '').slice(0, 80));
    syncBar();
    return { ok: true, open: true };
  });
  ipcMain.on('browser:subnet', async (e, subnet: string) => {
    if (!fromMain(e)) return;
    const next = validSubnet(String(subnet ?? '')) ? String(subnet) : '';
    if (next === cidr) return;
    cidr = next;
    if (server) await applyProxy().catch(() => {});
    syncBar();
  });
  ipcMain.on('browser:flow-opened', (e, id: number, ok: boolean, error?: string) => { if (fromMain(e)) flowOpened(id, !!ok, error); });
  ipcMain.on('browser:flow-ack', (e, id: number, n: number) => {
    const f = fromMain(e) ? flows.get(id) : undefined;
    if (!f) return;
    f.inflight = Math.max(0, f.inflight - (+n || 0));
    if (f.paused && f.inflight < FLOW_LOW) { f.paused = false; f.sock.resume(); }
  });
  ipcMain.on('browser:flow-recv', (e, id: number, data: Uint8Array) => {
    const f = fromMain(e) ? flows.get(id) : undefined;
    if (!f || !f.opened) return;
    if (!f.sock.write(data)) send('browser:flow-pause', id, true);
  });
  ipcMain.on('browser:flow-eof', (e, id: number) => { const f = fromMain(e) ? flows.get(id) : undefined; f?.sock.end(); });
  ipcMain.on('browser:flow-destroy', (e, id: number) => {
    const f = fromMain(e) ? flows.get(id) : undefined;
    if (!f) return;
    flows.delete(id);
    f.sock.end();
    setTimeout(() => f.sock.destroy(), 30000).unref();
  });
}

/** The main window went away: the browser and its flows go with it. */
export function stopBrowser() {
  for (const f of flows.values()) f.sock.destroy();
  flows.clear();
  if (win && !win.isDestroyed()) win.close();
  server?.close(); server = null; port = 0; owner = null;
}
