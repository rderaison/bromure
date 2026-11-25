import { safeRelativePath } from './util';
// A dropped folder travels as one gzipped ustar archive the guest unpacks
// (FolderUpload.swift; the macOS app shells out to /usr/bin/tar). Built here
// from the browser's File objects (webkitRelativePath / DataTransfer entries)
// and CompressionStream('gzip').

export interface TarEntry { path: string; file?: File; dir?: boolean }

const enc = new TextEncoder();

function header(name: string, size: number, type: '0' | '5', mtime: number): Uint8Array {
  const h = new Uint8Array(512);
  const put = (s: string, off: number, len: number) => { const b = enc.encode(s); h.set(b.subarray(0, len), off); };
  const oct = (n: number, len: number) => n.toString(8).padStart(len - 1, '0') + '\0';
  let prefix = '';
  let nm = name;
  if (enc.encode(nm).length > 100) {
    // ustar: split at a '/' so name ≤ 100 and prefix ≤ 155 bytes.
    let cut = -1;
    for (let j = nm.indexOf('/'); j >= 0; j = nm.indexOf('/', j + 1)) {
      if (enc.encode(nm.slice(0, j)).length <= 155 && enc.encode(nm.slice(j + 1)).length <= 100) { cut = j; break; }
    }
    if (cut < 0) throw new Error(`Path too long to archive: ${name}`);
    prefix = nm.slice(0, cut); nm = nm.slice(cut + 1);
  }
  put(nm, 0, 100);
  put(oct(type === '5' ? 0o755 : 0o644, 8), 100, 8);
  put(oct(0, 8), 108, 8); put(oct(0, 8), 116, 8);
  put(oct(size, 12), 124, 12);
  put(oct(Math.floor(mtime / 1000), 12), 136, 12);
  for (let i = 148; i < 156; i++) h[i] = 0x20;
  h[156] = type.charCodeAt(0);
  put('ustar\0', 257, 6); put('00', 263, 2);
  put(prefix, 345, 155);
  let sum = 0;
  for (let i = 0; i < 512; i++) sum += h[i];
  put(sum.toString(8).padStart(6, '0') + '\0 ', 148, 8);
  return h;
}

/** A .tgz of the entries (paths relative to the archive root, "./x/y"). */
export async function tarGz(entries: TarEntry[]): Promise<Uint8Array> {
  const parts: Uint8Array[] = [];
  for (const e of entries) {
    const rel = safeRelativePath(e.path);
    if (!rel) continue;                                // a `..` / absolute member never goes in
    const p = './' + rel;
    if (e.dir) { parts.push(header(p.endsWith('/') ? p : p + '/', 0, '5', Date.now())); continue; }
    const data = new Uint8Array(await e.file!.arrayBuffer());
    parts.push(header(p, data.length, '0', e.file!.lastModified || Date.now()));
    parts.push(data);
    const pad = (512 - (data.length % 512)) % 512;
    if (pad) parts.push(new Uint8Array(pad));
  }
  parts.push(new Uint8Array(1024));
  const blob = new Blob(parts as BlobPart[]);
  const gz = blob.stream().pipeThrough(new CompressionStream('gzip'));
  return new Uint8Array(await new Response(gz).arrayBuffer());
}

/** Walk dropped items: files and whole folders (FileSystemEntry API). */
export async function collectDropped(dt: DataTransfer): Promise<{ name: string; isDir: boolean; file?: File; entries?: TarEntry[] }[]> {
  const out: { name: string; isDir: boolean; file?: File; entries?: TarEntry[] }[] = [];
  const items = [...dt.items].filter(i => i.kind === 'file');
  const roots = items.map(i => (i as any).webkitGetAsEntry?.() as FileSystemEntry | null);
  if (roots.every(r => !r)) {
    for (const f of [...dt.files]) out.push({ name: f.name, isDir: false, file: f });
    return out;
  }
  for (const r of roots) {
    if (!r) continue;
    if (r.isFile) { out.push({ name: r.name, isDir: false, file: await fileOf(r as FileSystemFileEntry) }); continue; }
    const entries: TarEntry[] = [];
    await walk(r as FileSystemDirectoryEntry, '', entries);
    out.push({ name: r.name, isDir: true, entries });
  }
  return out;
}
const fileOf = (e: FileSystemFileEntry) => new Promise<File>((res, rej) => e.file(res, rej));
async function walk(dir: FileSystemDirectoryEntry, rel: string, out: TarEntry[]) {
  const reader = dir.createReader();
  const all: FileSystemEntry[] = [];
  for (;;) {
    const batch = await new Promise<FileSystemEntry[]>((res, rej) => reader.readEntries(res, rej));
    if (!batch.length) break;
    all.push(...batch);
  }
  for (const e of all) {
    const p = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory) { out.push({ path: p, dir: true }); await walk(e as FileSystemDirectoryEntry, p, out); }
    else if (e.isFile) out.push({ path: p, file: await fileOf(e as FileSystemFileEntry) });
  }
}
