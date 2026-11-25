// Linux deliverables from an @electron/packager output dir (scripts/package.mjs):
//
//   out/bromure-client-<ver>-linux-<arch>.tar.gz   portable: a space-free top
//       folder (xdg-open's generic fallback can't run an Exec path with a
//       space), the app registers its own .desktop entry + bromure-client://
//       handler in ~/.local/share on first launch (electron/main.ts).
//   out/bromure-client_<ver>_<debarch>.deb         /opt/bromure-client, a
//       system .desktop entry (scheme handler), icon, /usr/bin symlink, and the
//       sandbox set up (AppArmor userns profile on Ubuntu 24.04+, setuid
//       chrome-sandbox elsewhere).
//
// No dpkg-deb needed (so it also runs on macOS): a .deb is an `ar` archive of
// debian-binary + control.tar.gz + data.tar.gz, written here; tar is the
// system's (GNU or bsdtar).
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const ID = 'io.bromure.client';
const PKG = 'bromure-client';
const PREFIX = `/opt/${PKG}`;
const DEB_ARCH = { x64: 'amd64', arm64: 'arm64', armv7l: 'armhf' };
// Runtime libraries of Electron's Chromium (as Chrome's/VS Code's .deb list
// them); "a-t64 | a" covers Ubuntu 24.04+ and Debian 12 / Ubuntu 22.04. The
// t64 name goes FIRST: on 24.04 the old name is only virtual, and apt would
// satisfy "libasound2" with liboss4-salsa-asound2 (an OSS shim missing ALSA
// symbols — the app dies on snd_device_name_get_hint).
const DEPENDS = [
  'libasound2t64 | libasound2', 'libatk-bridge2.0-0t64 | libatk-bridge2.0-0', 'libatk1.0-0t64 | libatk1.0-0',
  'libatspi2.0-0t64 | libatspi2.0-0', 'libc6', 'libcairo2', 'libcups2t64 | libcups2', 'libdbus-1-3', 'libdrm2',
  'libexpat1', 'libgbm1', 'libglib2.0-0t64 | libglib2.0-0', 'libgtk-3-0t64 | libgtk-3-0', 'libnspr4', 'libnss3',
  'libpango-1.0-0', 'libx11-6', 'libxcb1', 'libxcomposite1', 'libxdamage1', 'libxext6', 'libxfixes3',
  'libxkbcommon0', 'libxrandr2', 'xdg-utils',
].join(', ');

const pkgJson = JSON.parse(fs.readFileSync('package.json', 'utf8'));
const VERSION = pkgJson.version;
const MAINTAINER = process.env.BROMURE_DEB_MAINTAINER || 'Bromure <support@bromure.io>';

const gnuTar = (() => { try { return execFileSync('tar', ['--version']).toString().includes('GNU'); } catch { return false; } })();
/** tar -czf out -C dir <entries>, everything owned by root, modes kept, no macOS xattrs. */
function tarGz(out, dir, entries, { root = false } = {}) {
  const own = !root ? [] : gnuTar ? ['--owner=0', '--group=0', '--numeric-owner'] : ['--uid', '0', '--gid', '0', '--uname', 'root', '--gname', 'root'];
  const fmt = gnuTar ? ['--format=gnu', '--sort=name'] : ['--format', 'gnutar'];
  execFileSync('tar', [...fmt, ...own, '--no-xattrs', '-czf', path.resolve(out), ...entries], { cwd: dir, env: { ...process.env, COPYFILE_DISABLE: '1' } });
}

function desktopEntry(exec) {
  return ['[Desktop Entry]', 'Type=Application', 'Name=Bromure Client', 'GenericName=Remote Bromure Client',
    'Comment=Mirror a remote Bromure Agentic Coding server', `Exec=${exec}`, `Icon=${ID}`, 'Terminal=false',
    'Categories=Development;', `StartupWMClass=${ID}`, 'StartupNotify=true',
    'MimeType=x-scheme-handler/bromure-client;', ''].join('\n');
}

// Ubuntu 24.04+ restricts unprivileged user namespaces to AppArmor-profiled
// programs; without this Chromium's sandbox aborts at startup
// ("credentials.cc: Check failed: Permission denied").
const APPARMOR = `# Bromure Client: allow Chromium's user-namespace sandbox (Ubuntu 24.04+).
abi <abi/4.0>,
include <tunables/global>

profile ${PKG} ${PREFIX}/${PKG} flags=(unconfined) {
  userns,

  include if exists <local/${PKG}>
}
`;

const POSTINST = `#!/bin/sh
set -e
# Setuid sandbox helper: the fallback when user namespaces are unavailable.
chown root:root '${PREFIX}/chrome-sandbox' && chmod 4755 '${PREFIX}/chrome-sandbox' || true
# AppArmor 4 (Ubuntu 24.04+): let the app create its sandbox's user namespace.
if [ -f /etc/apparmor.d/abi/4.0 ] && command -v apparmor_parser >/dev/null 2>&1; then
  cp '${PREFIX}/resources/apparmor-profile' /etc/apparmor.d/${PKG}
  if aa-enabled --quiet 2>/dev/null || [ -d /sys/kernel/security/apparmor ]; then
    apparmor_parser --replace --write-cache --skip-read-cache /etc/apparmor.d/${PKG} || true
  fi
fi
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
exit 0
`;
const POSTRM = `#!/bin/sh
set -e
if [ "$1" = remove ] || [ "$1" = purge ]; then
  if [ -f /etc/apparmor.d/${PKG} ]; then
    command -v apparmor_parser >/dev/null 2>&1 && apparmor_parser --remove /etc/apparmor.d/${PKG} 2>/dev/null || true
    rm -f /etc/apparmor.d/${PKG}
  fi
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
exit 0
`;

const README = `Bromure Client for Linux
========================

Run ./${PKG}. On first launch it adds itself to your applications menu and
registers the bromure-client:// link handler (in ~/.local/share), pointing at
this folder — launch it again after moving the folder.

Prefer the .deb on Debian/Ubuntu: it sets all of this up system-wide.

"Check failed: Permission denied" / "No usable sandbox" at startup
------------------------------------------------------------------
Ubuntu 24.04 and later only let AppArmor-profiled programs create the user
namespace Chromium's sandbox needs. Make the sandbox helper setuid root once:

    sudo chown root:root chrome-sandbox && sudo chmod 4755 chrome-sandbox

(or install the .deb). Running with --no-sandbox also works but turns off the
renderer sandbox; don't make it a habit.

Wayland / X11
-------------
It runs natively on Wayland in a Wayland session (XDG_SESSION_TYPE=wayland)
and on X11 otherwise. Force one with --ozone-platform=x11 or
--ozone-platform=wayland.
`;

/** A .deb is an ar archive (common format, "!<arch>\\n" + 60-byte headers). */
function writeAr(out, members) {
  const parts = [Buffer.from('!<arch>\n')];
  const mtime = Math.floor(Date.now() / 1000);
  for (const [name, data] of members) {
    const h = name.padEnd(16) + String(mtime).padEnd(12) + '0'.padEnd(6) + '0'.padEnd(6) + '100644'.padEnd(8) + String(data.length).padEnd(10) + '`\n';
    parts.push(Buffer.from(h, 'ascii'), data);
    if (data.length % 2) parts.push(Buffer.from('\n'));
  }
  fs.writeFileSync(out, Buffer.concat(parts));
}

function duKiB(dir) {
  let n = 0;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) n += duKiB(p) + 1;
    else n += Math.ceil(fs.lstatSync(p).size / 1024);
  }
  return n;
}

/** Make every dir 755 and every file 644/755 (packager leaves 700 dirs). */
function normalizeModes(dir) {
  fs.chmodSync(dir, 0o755);
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isSymbolicLink()) continue;
    if (e.isDirectory()) normalizeModes(p);
    else fs.chmodSync(p, (fs.statSync(p).mode & 0o111) ? 0o755 : 0o644);
  }
}

export function packageLinux(appDir, arch) {
  const out = path.dirname(appDir);
  normalizeModes(appDir);
  fs.writeFileSync(path.join(appDir, 'resources', 'apparmor-profile'), APPARMOR);

  // ── tarball ──
  const tarName = `${PKG}-${VERSION}-linux-${arch}`;
  const tstage = path.join(out, `.stage-tar-${arch}`);
  fs.rmSync(tstage, { recursive: true, force: true });
  fs.mkdirSync(tstage);
  fs.cpSync(appDir, path.join(tstage, tarName), { recursive: true, verbatimSymlinks: true });
  fs.writeFileSync(path.join(tstage, tarName, 'README-linux.txt'), README);
  tarGz(path.join(out, `${tarName}.tar.gz`), tstage, [tarName]);
  fs.rmSync(tstage, { recursive: true, force: true });
  console.log('packaged', path.join(out, `${tarName}.tar.gz`));

  // ── .deb ──
  const debArch = DEB_ARCH[arch];
  if (!debArch) return;
  const stage = path.join(out, `.stage-deb-${arch}`);
  fs.rmSync(stage, { recursive: true, force: true });
  const data = path.join(stage, 'data'), ctl = path.join(stage, 'control');
  fs.mkdirSync(path.join(data, 'opt'), { recursive: true });
  fs.cpSync(appDir, path.join(data, PREFIX), { recursive: true, verbatimSymlinks: true });
  fs.chmodSync(path.join(data, PREFIX, 'chrome-sandbox'), 0o4755);
  fs.mkdirSync(path.join(data, 'usr/bin'), { recursive: true });
  fs.symlinkSync(`${PREFIX}/${PKG}`, path.join(data, 'usr/bin', PKG));
  fs.mkdirSync(path.join(data, 'usr/share/applications'), { recursive: true });
  fs.writeFileSync(path.join(data, `usr/share/applications/${ID}.desktop`), desktopEntry(`${PREFIX}/${PKG} %U`));
  const icons = path.join(data, 'usr/share/icons/hicolor/512x512/apps');
  fs.mkdirSync(icons, { recursive: true });
  fs.copyFileSync('build/icon.png', path.join(icons, `${ID}.png`));
  fs.mkdirSync(path.join(data, `usr/share/doc/${PKG}`), { recursive: true });
  fs.copyFileSync(path.join(appDir, 'LICENSE'), path.join(data, `usr/share/doc/${PKG}/copyright`));
  normalizeModes(path.join(data, 'usr'));
  for (const d of ['opt']) fs.chmodSync(path.join(data, d), 0o755);
  fs.chmodSync(data, 0o755);
  fs.chmodSync(path.join(data, PREFIX, 'chrome-sandbox'), 0o4755);

  fs.mkdirSync(ctl, { recursive: true });
  fs.writeFileSync(path.join(ctl, 'control'), [
    `Package: ${PKG}`, `Version: ${VERSION}`, `Architecture: ${debArch}`, `Maintainer: ${MAINTAINER}`,
    `Installed-Size: ${duKiB(data)}`, `Depends: ${DEPENDS}`, 'Section: devel', 'Priority: optional',
    'Homepage: https://bromure.io', 'Description: Bromure Client',
    ' Mirror a remote Bromure Agentic Coding server — its workspaces, sessions,',
    ' terminals and automations — over SSH, directly or through bromure.io.', ''].join('\n'));
  fs.writeFileSync(path.join(ctl, 'postinst'), POSTINST, { mode: 0o755 });
  fs.writeFileSync(path.join(ctl, 'postrm'), POSTRM, { mode: 0o755 });
  fs.chmodSync(path.join(ctl, 'postinst'), 0o755); fs.chmodSync(path.join(ctl, 'postrm'), 0o755);

  tarGz(path.join(stage, 'control.tar.gz'), ctl, ['./control', './postinst', './postrm'], { root: true });
  tarGz(path.join(stage, 'data.tar.gz'), data, ['./opt', './usr'], { root: true });
  const deb = path.join(out, `${PKG}_${VERSION}_${debArch}.deb`);
  writeAr(deb, [
    ['debian-binary', Buffer.from('2.0\n')],
    ['control.tar.gz', fs.readFileSync(path.join(stage, 'control.tar.gz'))],
    ['data.tar.gz', fs.readFileSync(path.join(stage, 'data.tar.gz'))],
  ]);
  fs.rmSync(stage, { recursive: true, force: true });
  console.log('packaged', deb);
}
