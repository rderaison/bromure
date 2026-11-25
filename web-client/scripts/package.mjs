// Package the Electron app for Linux / Windows with @electron/packager
// (x64 + arm64). Output: out/Bromure-<platform>-<arch>/ (+ a .zip / .tar.gz).
// Only dist/, dist-electron/ and package.json go in the app — no node_modules
// (the main process bundles everything with esbuild).
import { packager } from '@electron/packager';
import { execFileSync } from 'node:child_process';
import path from 'node:path';

const platform = process.argv[2] ?? 'linux';
const arch = (process.argv[3] ?? 'x64,arm64').split(',');
const keep = /^\/(dist|dist-electron)(\/|$)|^\/package\.json$|^$/;
const noMaps = (p) => !p.endsWith('.map');
const paths = await packager({
  dir: '.', out: 'out', overwrite: true, platform, arch,
  name: 'Bromure Client', executableName: platform === 'win32' ? 'Bromure Client' : 'bromure-client',
  appBundleId: 'io.bromure.client', appCopyright: '© Bromure',
  protocols: [{ name: 'Bromure', schemes: ['bromure'] }],
  asar: true, prune: false,
  ignore: p => p !== '' && (!keep.test(p) || !noMaps(p)),
  win32metadata: { CompanyName: 'Bromure', ProductName: 'Bromure Client', FileDescription: 'Bromure Client' },
});
for (const p of paths) {
  const base = path.basename(p);
  if (platform === 'win32') execFileSync('zip', ['-qryX', `${base}.zip`, base, '-x', '*/.DS_Store', '*/._*'], { cwd: 'out' });
  // No AppleDouble files / macOS xattrs in a Linux tarball (GNU tar warns on each).
  else execFileSync('tar', ['--no-xattrs', '-czf', `${base}.tar.gz`, base], { cwd: 'out', env: { ...process.env, COPYFILE_DISABLE: '1' } });
  console.log('packaged', p);
}
