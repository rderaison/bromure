// Package the Electron app for Linux / Windows with @electron/packager
// (x64 + arm64). Output: out/Bromure Client-<platform>-<arch>/ (+ a .zip on
// Windows; on Linux a .tar.gz and a .deb, see package-linux.mjs).
// Only dist/, dist-electron/ and package.json go in the app — no node_modules
// (the main process bundles everything with esbuild).
import { packager } from '@electron/packager';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
import { packageLinux } from './package-linux.mjs';

const platform = process.argv[2] ?? 'linux';
const arch = (process.argv[3] ?? 'x64,arm64').split(',');
const keep = /^\/(dist|dist-electron)(\/|$)|^\/build(\/icon\.(png|ico))?$|^\/package\.json$|^$/;
const noMaps = (p) => !p.endsWith('.map');
const paths = await packager({
  dir: '.', out: 'out', overwrite: true, platform, arch,
  name: 'Bromure Client', executableName: platform === 'win32' ? 'Bromure Client' : 'bromure-client',
  appBundleId: 'io.bromure.client', appCopyright: '© Bromure',
  protocols: [{ name: 'Bromure Client', schemes: ['bromure-client'] }],
  icon: 'build/icon',          // build/icon.ico for the Windows exe (scripts/make-icon.cjs); unused on Linux
  asar: true, prune: false,
  ignore: p => p !== '' && (!keep.test(p) || !noMaps(p)),
  win32metadata: { CompanyName: 'Bromure', ProductName: 'Bromure Client', FileDescription: 'Bromure Client' },
});
for (const p of paths) {
  const base = path.basename(p);
  // Packaging ON Windows: there is no `zip`, but the bsdtar that ships with
  // Windows 10+ writes one (`-a` picks the format from the extension). Its full
  // path, so a GNU tar earlier on PATH (Git Bash) isn't picked up instead.
  if (platform === 'win32' && process.platform === 'win32') {
    fs.rmSync(path.join('out', `${base}.zip`), { force: true });
    execFileSync(path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'tar.exe'), ['-a', '-cf', `${base}.zip`, base], { cwd: 'out' });
  } else if (platform === 'win32') execFileSync('zip', ['-qryX', `${base}.zip`, base, '-x', '*/.DS_Store', '*/._*'], { cwd: 'out' });
  // Linux: a tarball (space-free folder name) + a .deb — scripts/package-linux.mjs.
  else packageLinux(p, base.slice(base.lastIndexOf('-') + 1));
  console.log('packaged', p);
}
