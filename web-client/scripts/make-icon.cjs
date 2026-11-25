// Regenerate build/icon.ico (Windows: exe, taskbar, installer) and
// build/icon.png (Linux window icon, 512 px) from the Agentic Coding app icon,
// Resources/BromureACIcon.icns. No dependency: Electron's own nativeImage does
// the resampling, so this runs under Electron —
//   npm run make:icon
// The outputs are committed; rerun only when the artwork changes.
const { app, nativeImage } = require('electron');
const fs = require('node:fs');
const path = require('node:path');

const SRC = path.resolve(__dirname, '..', '..', 'Resources', 'BromureACIcon.icns');
const OUT = path.resolve(__dirname, '..', 'build');
const ICO_SIZES = [16, 24, 32, 48, 64, 128, 256];

// An .icns is a list of (4-char type, u32 length incl. the 8-byte header)
// chunks; the large ones hold PNG files. Take the biggest PNG.
function largestPng(icns) {
  if (icns.toString('latin1', 0, 4) !== 'icns') throw new Error('not an .icns: ' + SRC);
  let best = null;
  for (let o = 8; o + 8 <= icns.length;) {
    const len = icns.readUInt32BE(o + 4);
    if (len < 8) break;
    const body = icns.subarray(o + 8, o + len);
    if (body.length > 24 && body.readUInt32BE(0) === 0x89504e47) {
      const width = body.readUInt32BE(16);          // IHDR width
      if (!best || width > best.width) best = { width, body };
    }
    o += len;
  }
  if (!best) throw new Error('no PNG in ' + SRC);
  return best;
}

// ICO with PNG-compressed entries (Windows Vista and later read them at every size).
function ico(entries) {
  const head = Buffer.alloc(6 + 16 * entries.length);
  head.writeUInt16LE(0, 0); head.writeUInt16LE(1, 2); head.writeUInt16LE(entries.length, 4);
  let offset = head.length;
  entries.forEach(({ size, png }, i) => {
    const e = 6 + 16 * i;
    head.writeUInt8(size === 256 ? 0 : size, e);     // width  (0 = 256)
    head.writeUInt8(size === 256 ? 0 : size, e + 1); // height
    head.writeUInt8(0, e + 2); head.writeUInt8(0, e + 3);
    head.writeUInt16LE(1, e + 4);                    // planes
    head.writeUInt16LE(32, e + 6);                   // bits per pixel
    head.writeUInt32LE(png.length, e + 8);
    head.writeUInt32LE(offset, e + 12);
    offset += png.length;
  });
  return Buffer.concat([head, ...entries.map(e => e.png)]);
}

app.whenReady().then(() => {
  try {
    const { width, body } = largestPng(fs.readFileSync(SRC));
    const src = nativeImage.createFromBuffer(body);
    if (src.isEmpty()) throw new Error('could not decode the icon PNG');
    const at = size => src.resize({ width: size, height: size, quality: 'best' }).toPNG();
    fs.mkdirSync(OUT, { recursive: true });
    fs.writeFileSync(path.join(OUT, 'icon.ico'), ico(ICO_SIZES.map(size => ({ size, png: at(size) }))));
    fs.writeFileSync(path.join(OUT, 'icon.png'), at(512));
    console.log(`icon: ${width}px source → build/icon.ico (${ICO_SIZES.join('/')}), build/icon.png (512)`);
    app.exit(0);
  } catch (e) { console.error(String(e)); app.exit(1); }
});
