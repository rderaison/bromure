// Live protocol test against a running Bromure server (scripts/demo-server.sh
// start <pubkey>). Skipped unless BROMURE_LIVE_KEY (a JWK file whose public key
// the server authorizes) is set. Exercises the WebCrypto SSH client end to end:
// kex + host-key signature, publickey auth, many concurrent exec channels, the
// control HTTP contract, the delta push stream, and an interactive PTY.
import fs from 'node:fs';
import { describe, it, expect } from 'vitest';
import { SSHConnection } from '../src/core/ssh/client';
import { importJWKKey } from '../src/core/ssh/keys';
import { controlRequest, controlOpenStream } from '../src/core/control/http';
import { ptyFrame, PTY } from '../src/core/remote/host';
import { concat, fromUtf8, utf8 } from '../src/core/ssh/wire';
import { nodeTcp } from './node-stream';

const KEY = process.env.BROMURE_LIVE_KEY;
const PORT = +(process.env.BROMURE_LIVE_PORT ?? 2399);
const USER = process.env.BROMURE_LIVE_USER ?? process.env.USER ?? '';

async function connect() {
  const key = await importJWKKey(JSON.parse(fs.readFileSync(KEY!, 'utf8')));
  return SSHConnection.connect(await nodeTcp('127.0.0.1', PORT), { username: USER, key, verifyHostKey: async () => true });
}

describe.skipIf(!KEY)('live SSH + control protocol', () => {
  it('authenticates and serves /state', async () => {
    const c = await connect();
    expect(c.authMethod).toBe('publickey');
    expect(c.hostKey?.fingerprint).toMatch(/^SHA256:/);
    const r = await controlRequest(c, 'GET', '/state');
    expect(r.status).toBe(200);
    expect(Array.isArray(r.json.workspaces)).toBe(true);
    c.close();
  });

  it('multiplexes 30 concurrent requests on one connection', async () => {
    const c = await connect();
    const rs = await Promise.all(Array.from({ length: 30 }, () => controlRequest(c, 'GET', '/health')));
    expect(rs.every(r => r.status === 200)).toBe(true);
    const big = await controlRequest(c, 'GET', '/state');   // a large, gzip'd body over the same link
    expect(big.raw.length).toBeGreaterThan(1000);
    c.close();
  });

  it('streams /state/subscribe frames', async () => {
    const c = await connect();
    const ch = await controlOpenStream(c, 'GET', '/state/subscribe', {}, { 'X-Bromure-State-Delta': '1' });
    const first = await new Promise<Uint8Array>((resolve, reject) => {
      let buf: Uint8Array = new Uint8Array(0);
      const t = setTimeout(() => reject(new Error('no frame')), 10000);
      ch.onData = d => { buf = concat(buf, d); if (buf.length >= 5) { const len = (buf[0] << 24 | buf[1] << 16 | buf[2] << 8 | buf[3]) >>> 0; if (buf.length >= 4 + len) { clearTimeout(t); resolve(buf); } } };
      ch.resume();
    });
    expect(first.length).toBeGreaterThan(5);
    ch.close(); c.close();
  });

  it('runs an interactive PTY in a running workspace', async () => {
    const c = await connect();
    const st = (await controlRequest(c, 'GET', '/state')).json;
    const vm = (st.vms ?? []).find((v: any) => v.state === 'running' && (v.tabs ?? []).length);
    if (!vm) { c.close(); return; }   // no live VM on this server
    const ch = await controlOpenStream(c, 'POST', `/vms/${encodeURIComponent(vm.id)}/exec`,
      { command: "sh -c 'read x; echo got:$x'", interactive: true, cols: 80, rows: 24 });
    let out = '';
    const done = new Promise<void>((resolve, reject) => {
      const t = setTimeout(() => reject(new Error('pty timeout: ' + out)), 20000);
      let buf: Uint8Array = new Uint8Array(0);
      ch.onData = d => {
        buf = concat(buf, d);
        while (buf.length >= 5) {
          const len = (buf[1] << 24 | buf[2] << 16 | buf[3] << 8 | buf[4]) >>> 0;
          if (buf.length < 5 + len) break;
          if (buf[0] === PTY.data) out += fromUtf8(buf.subarray(5, 5 + len));
          if (buf[0] === PTY.exit || out.includes('got:ping')) { clearTimeout(t); resolve(); }
          buf = buf.slice(5 + len);
        }
      };
      ch.onClose = () => { clearTimeout(t); resolve(); };
      ch.resume();
    });
    setTimeout(() => ch.write(ptyFrame(PTY.data, utf8('ping\r'))), 1500);
    await done;
    expect(out).toContain('got:ping');
    ch.close(); c.close();
  }, 30000);
});
