// Dev-only stand-in for bromure.io's ws-relay: the browser (vite dev or a
// built page) opens ws://127.0.0.1:5179/ssh?port=2399 and this pipes the
// bytes to 127.0.0.1:<port> — SSH stays end to end, exactly like production.
// Also: POST /authorize {key} adds a browser's public key to the DEMO server
// (scripts/demo-server.sh) so dev sessions are passwordless.
import { WebSocketServer } from 'ws';
import http from 'node:http';
import net from 'node:net';
import { execFileSync } from 'node:child_process';

const PORT = +(process.env.DEV_RELAY_PORT || 5179);
const SOCK = process.env.DEMO_SOCK || '/private/tmp/brmW/Library/Application Support/BromureAC/control.sock';

const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'content-type');
  if (req.method === 'OPTIONS') { res.end(); return; }
  if (req.method === 'POST' && req.url === '/authorize') {
    let body = '';
    req.on('data', d => body += d);
    req.on('end', () => {
      try {
        const { key } = JSON.parse(body);
        if (!/^ssh-ed25519 [A-Za-z0-9+/=]+( [\w.@-]+)?$/.test(key)) throw new Error('bad key');
        execFileSync('curl', ['-fsS', '-m', '10', '--unix-socket', SOCK, '-X', 'POST', '-d', JSON.stringify({ key }), 'http://x/remote/keys']);
        res.end('{"ok":true}');
      } catch (e) { res.statusCode = 400; res.end(JSON.stringify({ error: String(e) })); }
    });
    return;
  }
  if (req.url === '/whoami') { res.end(JSON.stringify({ user: process.env.USER })); return; }
  res.statusCode = 404; res.end();
});
const wss = new WebSocketServer({ server, path: '/ssh' });
wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://x');
  const port = +(url.searchParams.get('port') || 2399);
  const host = url.searchParams.get('host') || '127.0.0.1';
  if (!['127.0.0.1', 'localhost'].includes(host)) { ws.close(1008, 'loopback only'); return; }
  const sock = net.connect({ host, port });
  const pending = [];
  sock.on('connect', () => { for (const p of pending) sock.write(p); pending.length = 0; });
  sock.on('data', d => ws.readyState === 1 && ws.send(d));
  sock.on('close', () => ws.close());
  sock.on('error', () => ws.close(1011, 'tcp error'));
  ws.on('message', d => { const b = Buffer.from(d); sock.connecting ? pending.push(b) : sock.write(b); });
  ws.on('close', () => sock.destroy());
});
server.listen(PORT, '127.0.0.1', () => console.log(`dev relay ws://127.0.0.1:${PORT}/ssh  (→ 127.0.0.1:<port>)`));
