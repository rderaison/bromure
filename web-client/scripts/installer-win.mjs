// Build the Windows installers with NSIS from what `npm run package:win` left
// in out/:  out/BromureClient-<version>-<arch>-setup.exe  (x64, arm64).
//   npm run package:win && npm run installer:win [-- x64]
// Needs makensis 3.08+ (winget install NSIS.NSIS · brew install makensis ·
// apt install nsis); it runs on Windows, macOS and Linux alike.
// Signing: BROMURE_SIGN_SCRIPT=/abs/sign.sh signs the uninstaller and the setup
// (same hook as sidecar/installer/BromureSidecar.nsi).
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const { version } = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
const archs = (process.argv[2] ?? 'x64,arm64').split(',');

function findMakensis() {
  const candidates = ['makensis'];
  if (process.platform === 'win32') {
    for (const pf of [process.env['ProgramFiles(x86)'], process.env.ProgramFiles]) if (pf) candidates.push(path.join(pf, 'NSIS', 'makensis.exe'));
  }
  for (const c of candidates) {
    try { execFileSync(c, ['-VERSION'], { stdio: 'pipe' }); return c; } catch {}
  }
  throw new Error('makensis not found — install NSIS 3.08+ (winget install NSIS.NSIS / brew install makensis / apt install nsis)');
}

const makensis = findMakensis();
let built = 0;
for (const arch of archs) {
  const app = path.join(root, 'out', `Bromure Client-win32-${arch}`);
  if (!fs.existsSync(path.join(app, 'Bromure Client.exe'))) { console.warn(`skip ${arch}: ${app} is missing (run npm run package:win)`); continue; }
  const defs = [`-DVERSION=${version}`, `-DARCH=${arch}`];
  if (process.env.BROMURE_SIGN_SCRIPT) defs.push(`-DSIGN_SCRIPT=${process.env.BROMURE_SIGN_SCRIPT}`);
  execFileSync(makensis, ['-V2', '-INPUTCHARSET', 'UTF8', ...defs, 'BromureClient.nsi'], { cwd: path.join(root, 'installer'), stdio: 'inherit' });
  console.log('installer', path.join('out', `BromureClient-${version}-${arch}-setup.exe`));
  built++;
}
if (!built) { console.error('nothing to build'); process.exit(1); }
