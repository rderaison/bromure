// Live probe against a running server:  npx vite-node? → we use tsx-less esbuild run.
// Usage: node test/run.mjs test/live-probe.ts <host> <port> <user> <keyjwk> [path] [outfile]
import fs from 'node:fs';
import { SSHConnection } from '../src/core/ssh/client';
import { importJWKKey } from '../src/core/ssh/keys';
import { controlRequest } from '../src/core/control/http';
import { nodeTcp } from './node-stream';

const [host, port, user, keyFile, path = '/state', out] = process.argv.slice(2);
const key = await importJWKKey(JSON.parse(fs.readFileSync(keyFile, 'utf8')));
const t0 = Date.now();
const conn = await SSHConnection.connect(await nodeTcp(host, +port), {
  username: user, key,
  verifyHostKey: async info => { console.error('host key', info.fingerprint); return true; },
});
console.error('connected in', Date.now() - t0, 'ms via', conn.authMethod);
const r = await controlRequest(conn, 'GET', path);
console.error('status', r.status, 'bytes', r.raw.length);
if (out) fs.writeFileSync(out, JSON.stringify(r.json, null, 2)); else console.log(JSON.stringify(r.json, null, 2).slice(0, 3000));
conn.close();
process.exit(0);
