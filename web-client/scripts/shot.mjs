// Render the app in (offscreen) Electron at 2x and save a PNG — the web
// client's counterpart to the native app's /debug/ui-shot, for side-by-side
// pixel comparison with web-client/.reference/*.png.
//
//   node scripts/shot.mjs OUT.png [--hash '#/host/demo'] [--query 'dev=demo'] [--w 1320 --h 944]
//        [--dark] [--delay 5000] [--js 'document.querySelector(...).click()'] [--after 1500]
// Needs a build: `npx vite build --outDir .build-<you>` then `--dist .build-<you>`
// (default dist/), and `npm run build:electron` once.
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import electron from 'electron';
import fs from 'node:fs';
import os from 'node:os';

const args = process.argv.slice(2);
const out = path.resolve(args[0]);
const opt = k => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : undefined; };
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'bromure-shot-'));
const env = { ...process.env, ...(opt('url') ? { BROMURE_DEV_URL: opt('url') } : {}), BROMURE_SHOT: out, BROMURE_SHOT_PROFILE: profile, ...(args.includes('--web') ? { BROMURE_AS_WEB: '1' } : {}), ...(opt('dist') ? { BROMURE_DIST: path.resolve(opt('dist')) } : {}),
  BROMURE_HASH: opt('hash') ?? '', BROMURE_QUERY: [opt('query'), args.includes('--dark') ? 'appearance=dark' : 'appearance=light', 'devRelay=ws://127.0.0.1:5179', 'autotrust=1'].filter(Boolean).join('&'),
  BROMURE_W: opt('w') ?? '1320', BROMURE_H: opt('h') ?? '944', BROMURE_SHOT_DELAY: opt('delay') ?? '5000',
  BROMURE_SHOT_JS: opt('js') ?? '', BROMURE_SHOT_AFTER: opt('after') ?? '1500' };
const r = spawnSync(electron, ['--force-device-scale-factor=2', '.'], { env, stdio: 'inherit', cwd: path.resolve(path.dirname(new URL(import.meta.url).pathname), '..') });
fs.rmSync(profile, { recursive: true, force: true });
process.exit(r.status ?? 1);
