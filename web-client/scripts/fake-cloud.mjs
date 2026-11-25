// Test-only stand-in for bromure.io's control plane, implementing the agreed
// contract (bromure-infra): two-phase Ed25519 enrollment, /v1/devices,
// /v1/devices/ssh-key, /v1/connections, the signaling device-channel and the
// ws-relay (bearer via Sec-WebSocket-Protocol). The "server" device is the
// demo server: a ws-relay offer makes this process join the relay as the
// LISTENER and splice it to 127.0.0.1:<DEMO_SSH_PORT> — what bromure-ac's
// WSRelayListener does for real. Lets the hosted client's whole cloud path
// (sign-in → directory → grant → signaling → relay → SSH) run end to end.
//
//   node scripts/fake-cloud.mjs      (127.0.0.1:5190; API base http://127.0.0.1:5190)
import http from 'node:http';
import net from 'node:net';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { WebSocketServer } from 'ws';
import fs from 'node:fs';
import path from 'node:path';

const PORT = +(process.env.FAKE_CLOUD_PORT || 5190);
const SSH_PORT = +(process.env.DEMO_SSH_PORT || 2399);
const SOCK = process.env.DEMO_SOCK || '/private/tmp/brmW/Library/Application Support/BromureAC/control.sock';
const SERVER = { id: 'srv-demo-0001', name: 'Demo server', capability: 'server', p2pServer: true, online: true,
                 sshUsername: process.env.USER, lastSeenAt: new Date().toISOString() };

const challenges = new Map();     // challengeId -> { challenge, pubkeyHex, name }
const tokens = new Map();         // deviceToken -> deviceId
const csrfOf = new Map();         // cookie deviceToken -> csrf token
// The hosted app is served same-origin from here (production: bromure.io/client)
// so the httpOnly-cookie identity works exactly as it will in production.
const STATIC = process.env.FAKE_CLOUD_STATIC || path.resolve('.build-qa');
const grants = new Map();         // connectionId -> { dialer, expires }
const relays = new Map();         // connectionId -> { dialer?: ws, listener?: net.Socket, buf: [] }
const log = (...a) => console.log('[fake-cloud]', ...a);

function json(res, status, body) { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); }
function cookies(req) {
  return Object.fromEntries((req.headers.cookie || '').split(';').map(c => c.trim().split('=')).filter(p => p[0]).map(([k, ...v]) => [k, decodeURIComponent(v.join('='))]));
}
function bearer(req) {
  const h = req.headers.authorization;
  if (h?.startsWith('Bearer ')) return h.slice(7);
  const c = cookies(req).bromure_device;
  if (c) return c;
  const proto = (req.headers['sec-websocket-protocol'] || '').split(',').map(s => s.trim());
  const b = proto.find(p => p.startsWith('bearer.'));
  return b ? b.slice(7) : null;
}
function authed(req) { const t = bearer(req); return t && tokens.has(t) ? tokens.get(t) : null; }

const server = http.createServer((req, res) => {
  // Like bromure-infra in dev mode: reflect the Origin (prod is same-origin).
  if (req.headers.origin) {
    res.setHeader('Access-Control-Allow-Origin', req.headers.origin);
    res.setHeader('Access-Control-Allow-Headers', 'authorization, content-type');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, DELETE');
  }
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
  // Static hosted app at /client/ (same origin as the API, like bromure.io).
  if (req.method === 'GET' && req.url.startsWith('/client')) {
    let rel = decodeURIComponent(new URL(req.url, 'http://x').pathname.replace(/^\/client\/?/, '')) || 'index.html';
    const file = path.resolve(STATIC, rel);
    if (!file.startsWith(STATIC + path.sep) || !fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
    const type = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2' }[path.extname(file)] || 'application/octet-stream';
    res.writeHead(200, { 'content-type': type }); fs.createReadStream(file).pipe(res); return;
  }
  // Production mounts the device API under /api.
  if (req.url.startsWith('/api/')) req.url = req.url.slice(4);
  let body = '';
  req.on('data', d => body += d);
  req.on('end', () => {
    let j = {}; try { j = body ? JSON.parse(body) : {}; } catch {}
    const url = new URL(req.url, 'http://x');
    if (req.method === 'POST' && url.pathname === '/v1/devices/enroll') {
      if (j.code) {
        const challengeId = crypto.randomUUID(), challenge = crypto.randomBytes(32).toString('base64url');
        challenges.set(challengeId, { challenge, pubkeyHex: j.devicePubkey, name: j.deviceName });
        return json(res, 200, { challengeId, challenge, signPayload: `bromure-p2p-enroll:v1:${challengeId}:${challenge}`, capability: 'client' });
      }
      const c = challenges.get(j.challengeId);
      if (!c) return json(res, 400, { error: 'unknown challenge' });
      const key = crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(c.pubkeyHex, 'hex')]), format: 'der', type: 'spki' });
      const ok = crypto.verify(null, Buffer.from(`bromure-p2p-enroll:v1:${j.challengeId}:${c.challenge}`), key, Buffer.from(j.signature, 'base64'));
      if (!ok) return json(res, 401, { error: 'bad signature' });
      const deviceId = 'dev-' + crypto.randomUUID(), deviceToken = 'tok-' + crypto.randomBytes(24).toString('hex');
      tokens.set(deviceToken, deviceId);
      log('enrolled', deviceId, JSON.stringify(c.name), j.delivery === 'cookie' ? '(cookie delivery)' : '(bearer)');
      if (j.delivery === 'cookie') {
        const csrfToken = crypto.randomBytes(16).toString('hex');
        csrfOf.set(deviceToken, csrfToken);
        res.setHeader('Set-Cookie', [`bromure_device=${deviceToken}; HttpOnly; SameSite=Strict; Path=/`, `bromure_device_csrf=${csrfToken}; SameSite=Strict; Path=/`]);
        return json(res, 201, { deviceId, capability: 'client', orgKind: 'individual', userId: 'u1', orgSlug: 'personal', delivery: 'cookie', csrfToken });
      }
      return json(res, 201, { deviceId, deviceToken, capability: 'client', orgKind: 'individual', userId: 'u1', orgSlug: 'personal' });
    }
    const dev = authed(req);
    if (!dev) return json(res, 401, { error: 'unauthorized' });
    // Cookie-authed mutations need the CSRF header (double-submit).
    const viaCookie = !req.headers.authorization;
    if (viaCookie && req.method !== 'GET' && req.headers['x-csrf-token'] !== csrfOf.get(bearer(req))) {
      log('CSRF rejected', req.method, url.pathname);
      return json(res, 403, { error: 'csrf' });
    }
    if (req.method === 'POST' && url.pathname === '/v1/devices/heartbeat') { log('heartbeat'); return json(res, 200, { ok: true }); }
    if (req.method === 'POST' && url.pathname === '/v1/devices/web/logout') {
      tokens.delete(bearer(req));
      res.setHeader('Set-Cookie', ['bromure_device=; Max-Age=0; Path=/', 'bromure_device_csrf=; Max-Age=0; Path=/']);
      log('web logout'); return json(res, 200, { ok: true });
    }
    if (req.method === 'GET' && url.pathname === '/v1/devices') return json(res, 200, { devices: [SERVER, { id: dev, name: 'This device', capability: 'client' }] });
    if (req.method === 'POST' && url.pathname === '/v1/devices/ssh-key') {
      // The server's account-key sync, short-circuited: authorize on the demo server.
      execFileSync('curl', ['-fsS', '-m', '10', '--unix-socket', SOCK, '-X', 'POST', '-d', JSON.stringify({ key: j.sshPublicKey }), 'http://x/remote/keys']);
      log('ssh key published + authorized on the demo server');
      return json(res, 200, { ok: true });
    }
    if (req.method === 'POST' && url.pathname === '/v1/connections') {
      if (j.deviceId !== SERVER.id) return json(res, 404, { error: 'unknown device' });
      const id = crypto.randomUUID();
      grants.set(id, { dialer: dev, expires: Date.now() + 45000 });
      return json(res, 200, { connection: { id, expiresAt: new Date(Date.now() + 45000).toISOString(), self: { deviceId: dev, role: 'client' }, peer: { deviceId: SERVER.id, role: 'server' } } });
    }
    if (req.method === 'DELETE' || url.pathname === '/v1/devices/self-revoke') return json(res, 200, { ok: true });
    json(res, 404, { error: 'not found' });
  });
});

const wss = new WebSocketServer({ noServer: true, handleProtocols: protos => [...protos].find(p => p === 'bromure.device.v1' || p === 'bromure.relay.v1') ?? false });
server.on('upgrade', (req, sock, head) => {
  if (req.url.startsWith('/api/')) req.url = req.url.slice(4);
  const url = new URL(req.url, 'http://x');
  const dev = authed(req);
  if (!dev) { sock.end('HTTP/1.1 401 Unauthorized\r\n\r\n'); return; }
  const relay = /^\/v1\/connections\/([A-Za-z0-9_-]+)\/relay$/.exec(url.pathname);
  if (url.pathname === '/v1/device-channel') {
    wss.handleUpgrade(req, sock, head, ws => {
      ws.on('message', (d, isBinary) => {
        if (isBinary) return;
        let f; try { f = JSON.parse(String(d)); } catch { return; }
        const g = grants.get(f.connectionId);
        if (!g || g.dialer !== dev) { ws.send(JSON.stringify({ type: 'error', error: 'unknown_connection', connectionId: f.connectionId })); return; }
        if (f.kind === 'offer' && f.payload?.note === 'ws-relay') {
          // The server's broker sees the offer and joins the relay as listener.
          log('ws-relay offer for', f.connectionId, '— listener joining');
          const r = relays.get(f.connectionId) ?? { buf: [] };
          relays.set(f.connectionId, r);
          const s = net.connect({ host: '127.0.0.1', port: SSH_PORT });
          r.listener = s;
          for (const b of r.pending ?? []) s.write(b);
          r.pending = [];
          s.on('data', b => { if (r.dialer?.readyState === 1) r.dialer.send(b); else r.buf.push(b); });
          s.on('close', () => r.dialer?.close());
        }
      });
    });
    return;
  }
  if (relay) {
    const g = grants.get(relay[1]);
    if (!g) { sock.end('HTTP/1.1 404 Not Found\r\n\r\n'); return; }
    if (g.dialer !== dev) { sock.end('HTTP/1.1 404 Not Found\r\n\r\n'); return; }
    wss.handleUpgrade(req, sock, head, ws => {
      const r = relays.get(relay[1]) ?? { buf: [] };
      relays.set(relay[1], r);
      r.dialer = ws;
      for (const b of r.buf) ws.send(b);
      r.buf = [];
      log('relay paired', relay[1]);
      ws.on('message', (d, isBinary) => {
        if (!isBinary) { ws.close(1003, 'binary only'); return; }
        if (r.listener) r.listener.write(d); else (r.pending ??= []).push(Buffer.from(d));
      });
      ws.on('close', () => r.listener?.destroy());
    });
    return;
  }
  sock.end('HTTP/1.1 404 Not Found\r\n\r\n');
});
server.listen(PORT, '127.0.0.1', () => log(`listening on http://127.0.0.1:${PORT}`));
