// FileExplorer.swift's FileExplorerModel: the Files pane's data, all read
// INSIDE the guest — one shell round trip per refresh lists the folder on
// show plus every unfolded folder, finds the repositories in play and their
// git status (base64-wrapped: names are raw bytes). Transfers ride the
// guest file service (`POST /vms/<id>/file`: read / write / mkdir / untar).

import type { RemoteHost } from '../../core/remote/host';
import { saveFile } from '../../platform';
import { RepoGitPrograms, shellQuote as q, b64ToBytes, bytesToB64, decodeUTF8, joinPath, safeRelativePath, dirname, lastPathComponent, fileBytes } from './util';
import { tarGzStream, type TarEntry } from './tar';
import { writeGuestFile, replaceGuestFile } from '../../core/remote/chunkedWrite';

export type GitStatus = 'modified' | 'added' | 'untracked' | 'deleted' | 'renamed' | 'conflicted';
export const STATUS_TINT: Record<GitStatus, string> = {
  modified: 'var(--orange)', added: 'var(--green)', untracked: 'var(--green)', deleted: 'var(--red)', renamed: 'var(--blue)', conflicted: 'var(--purple)',
};
export const STATUS_BADGE: Record<GitStatus, string> = { modified: 'M', added: 'A', untracked: 'U', deleted: 'D', renamed: 'R', conflicted: '!' };

function porcelainStatus(xy: string): GitStatus | null {
  if (xy.length !== 2) return null;
  const x = xy[0], y = xy[1];
  if (x === '?' && y === '?') return 'untracked';
  if (x === 'U' || y === 'U' || (x === 'A' && y === 'A') || (x === 'D' && y === 'D')) return 'conflicted';
  if (x === 'R' || y === 'R') return 'renamed';
  if (x === 'D' || y === 'D') return 'deleted';
  if (x === 'A') return 'added';
  if ('MT'.includes(x) || 'MT'.includes(y)) return 'modified';
  return null;
}
export function parsePorcelain(raw: string): Map<string, GitStatus> {
  const out = new Map<string, GitStatus>();
  const tokens = raw.split('\0').filter(Boolean);
  for (let i = 0; i < tokens.length; i++) {
    const e = tokens[i];
    if (e.length <= 3) continue;
    const xy = e.slice(0, 2), path = e.slice(3);
    if ('RC'.includes(xy[0]) || 'RC'.includes(xy[1])) i++;
    const s = porcelainStatus(xy);
    if (s) out.set(path, s);
  }
  return out;
}

export interface FileNode { name: string; path: string; isDir: boolean; children: FileNode[]; status?: GitStatus; containsChanges: boolean }

export interface DiffLine { id: number; kind: 'hunk' | 'addition' | 'deletion' | 'context' | 'meta'; text: string; oldLine?: number; newLine?: number }
export function parseUnifiedDiff(diff: string): { lines: DiffLine[]; additions: number; deletions: number } {
  const lines: DiffLine[] = [];
  let o = 0, n = 0, id = 0, additions = 0, deletions = 0;
  for (const text of diff.split('\n')) {
    id++;
    if (text.startsWith('@@')) {
      const m = /^@@ -(\d+)(?:,\d+)? \+(\d+)/.exec(text);
      if (m) { o = +m[1]; n = +m[2]; }
      lines.push({ id, kind: 'hunk', text });
    } else if (text.startsWith('+') && !text.startsWith('+++')) { lines.push({ id, kind: 'addition', text: text.slice(1), newLine: n++ }); additions++; }
    else if (text.startsWith('-') && !text.startsWith('---')) { lines.push({ id, kind: 'deletion', text: text.slice(1), oldLine: o++ }); deletions++; }
    else if (text.startsWith(' ')) lines.push({ id, kind: 'context', text: text.slice(1), oldLine: o++, newLine: n++ });
    else if (text) lines.push({ id, kind: 'meta', text });
  }
  return { lines, additions, deletions };
}

export type Detail =
  | { kind: 'none' } | { kind: 'loading' }
  | { kind: 'diff'; doc: ReturnType<typeof parseUnifiedDiff> }
  | { kind: 'markdown'; text: string } | { kind: 'code'; text: string; language?: string }
  | { kind: 'image'; url: string } | { kind: 'binary' } | { kind: 'tooLarge' } | { kind: 'error'; message: string };

const IMG = /\.(png|jpe?g|gif|webp|svg|bmp|ico|avif)$/i;
const MAX_PREVIEW = 512 * 1024, MAX_DIFF = 1024 * 1024, CHUNK = 6 * 1024 * 1024, MAX_IMAGE = 24 * 1024 * 1024;

export class FileExplorerModel {
  profileID: string | null = null;
  root: string | null = null;
  repoRoot: string | null = null;
  expanded = new Set<string>();
  rootNodes: FileNode[] = [];
  statuses = new Map<string, GitStatus>();
  origins = new Map<string, { repo: string; path: string }>();
  statusFailed = false;
  loading = false;
  loadError: string | null = null;
  changedOnly = false;
  transferText: string | null = null;
  selectedPath: string | null = null;
  detail: Detail = { kind: 'none' };
  detailMode: 'diff' | 'preview' = 'preview';
  version = 0;

  private manualRoot: string | null = null;
  private contextCwd: string | null = null;
  private contextRepo: string | null = null;
  private refreshGen = 0;
  private detailGen = 0;
  private shownDetailKey: string | null = null;
  refreshInFlight = false;
  private listeners = new Set<() => void>();
  private imageURL: string | null = null;

  constructor(private host: RemoteHost) {}

  subscribe = (l: () => void) => { this.listeners.add(l); return () => { this.listeners.delete(l); }; };
  snapshot = () => this.version;
  private emit() { this.version++; for (const l of [...this.listeners]) l(); }

  get canGoUp() { return (this.root ?? '/') !== '/'; }
  get canTransfer() { return !!this.root && !!this.profileID; }
  get selectionHasDiff() { const s = this.selectedPath ? this.statuses.get(this.selectedPath) : undefined; return !!s && s !== 'untracked' && s !== 'added'; }

  private exec(cmd: string, timeout = 30) {
    if (!this.profileID) return Promise.reject(new Error('The machine isn\'t running.'));
    return this.host.guestExec(this.profileID, cmd, timeout);
  }
  private fileOp(op: Record<string, unknown>, timeout = 30) {
    if (!this.profileID) return Promise.reject(new Error('The machine isn\'t running.'));
    return this.host.guestFileOp(this.profileID, op, timeout);
  }

  setLocation(profileID: string | null, cwd: string | null, repoHint: string | null) {
    const changed = profileID !== this.profileID || cwd !== this.contextCwd || repoHint !== this.contextRepo;
    if (changed) this.manualRoot = null;
    this.contextCwd = cwd; this.contextRepo = repoHint;
    const newRoot = this.manualRoot ?? repoHint ?? cwd;
    if (!changed && newRoot === this.root) return;
    this.profileID = profileID;
    this.show(newRoot);
  }
  goUp() {
    if (!this.root || this.root === '/') return;
    this.manualRoot = dirname(this.root) || '/';
    this.show(this.manualRoot);
  }
  enter(dir: string) { if (!this.root) return; this.manualRoot = joinPath(this.root, dir); this.show(this.manualRoot); }
  toggleExpanded(dir: string) {
    if (this.expanded.has(dir)) { this.expanded.delete(dir); this.rebuild(); this.emit(); }
    else { this.expanded.add(dir); this.emit(); void this.refresh(); }
  }
  expand(dirs: Iterable<string>) {
    let added = false;
    for (const d of dirs) if (!this.expanded.has(d)) { this.expanded.add(d); added = true; }
    if (added) void this.refresh();
  }
  setChangedOnly(v: boolean) { this.changedOnly = v; this.emit(); }

  private show(root: string | null) {
    this.root = root;
    this.repoRoot = root && this.contextRepo && (root === this.contextRepo || root.startsWith(this.contextRepo + '/')) ? this.contextRepo : null;
    this.refreshGen++; this.detailGen++;
    this.shownDetailKey = null;
    this.rootNodes = []; this.statuses = new Map(); this.origins = new Map(); this.expanded = new Set();
    this.selectedPath = null; this.setDetail({ kind: 'none' });
    this.loadError = null; this.loading = root != null; this.refreshInFlight = false;
    this.lastListings = new Map();
    this.emit();
    if (root) void this.refresh();
  }

  async pollRefresh() { if (!this.refreshInFlight) await this.refresh(); }

  private lastListings = new Map<string, { name: string; isDir: boolean }[]>();

  async refresh() {
    const root = this.root;
    if (!root) return;
    const gen = ++this.refreshGen;
    this.refreshInFlight = true;
    const dirs = [root, ...[...this.expanded].sort().map(d => joinPath(root, d))];
    const listing = dirs.map(d => `printf '\\002%s\\001' ${q(d)}; find -L ${q(d)} -mindepth 1 -maxdepth 1 ! -name .git -printf '%y%f\\0' 2>/dev/null`).join('; ');
    const probe = dirs.map(q).join(' ');
    const cmd = `{ t=$(git -C ${q(root)} rev-parse --show-toplevel 2>/dev/null); printf '%s\\003' "$t"; `
      + `${listing}; printf '\\003'; `
      + `for d in ${probe}; do git -C "$d" rev-parse --show-toplevel 2>/dev/null; done | sort -u `
      + `| while IFS= read -r r; do [ -n "$r" ] || continue; printf '\\002%s\\001' "$r"; `
      + `${RepoGitPrograms.off('"$r"')}git -C "$r" status --porcelain -z --ignore-submodules=dirty 2>/dev/null `
      + `|| printf '%s\\0' ${q(RepoGitPrograms.statusFailedLine)}; ${RepoGitPrograms.dirtySubmodules('"$r"', true)}done; true; } | base64 -w0`;
    try {
      const out = await this.exec(cmd);
      if (gen !== this.refreshGen || root !== this.root) return;
      const data = b64ToBytes(out);
      const parts = splitBytes(data, 0x03, 3);
      const top = decodeUTF8(parts[0] ?? new Uint8Array()).trim();
      this.repoRoot = top || null;
      const sections: { top: string; porcelain: string }[] = [];
      if (parts.length > 2) for (const sec of splitBytes(parts[2], 0x02).filter(s => s.length)) {
        const [k, v] = splitBytes(sec, 0x01, 2);
        sections.push({ top: decodeUTF8(k).trim(), porcelain: v ? decodeUTF8(v) : '' });
      }
      const { statuses, origins } = mapStatuses(root, sections);
      this.statuses = statuses; this.origins = origins;
      this.statusFailed = sections.some(s => s.porcelain.split('\0').includes(RepoGitPrograms.statusFailedLine));
      const byDir = new Map<string, { name: string; isDir: boolean }[]>();
      if (parts.length > 1) for (const sec of splitBytes(parts[1], 0x02).filter(s => s.length)) {
        const [k, v] = splitBytes(sec, 0x01, 2);
        const entries = v ? splitBytes(v, 0).filter(e => e.length) : [];
        byDir.set(decodeUTF8(k), entries.map(e => ({ name: decodeUTF8(e.subarray(1)), isDir: e[0] === 0x64 /* d */ })));
      }
      this.lastListings = byDir;
      this.rebuild();
      this.loadError = null; this.loading = false;
      this.emit();
      if (this.selectedPath) await this.loadDetail();
    } catch (e: any) {
      if (gen !== this.refreshGen) return;
      this.loadError = e?.message ?? String(e);
      this.loading = false;
      this.emit();
    } finally {
      if (gen === this.refreshGen) this.refreshInFlight = false;
    }
  }

  private rebuild() {
    if (!this.root) return;
    const dirty = new Set<string>();
    for (const k of this.statuses.keys()) { let p = k; let i; while ((i = p.lastIndexOf('/')) > 0) { p = p.slice(0, i); dirty.add(p); } }
    const build = (abs: string, rel: string): FileNode[] => {
      const out = (this.lastListings.get(abs) ?? []).map(e => {
        const path = rel ? `${rel}/${e.name}` : e.name;
        const n: FileNode = { name: e.name, path, isDir: e.isDir, children: [], containsChanges: false };
        if (e.isDir) { n.containsChanges = dirty.has(path); if (this.expanded.has(path)) n.children = build(joinPath(abs, e.name), path); }
        else n.status = this.statuses.get(path);
        return n;
      });
      return out.sort((a, b) => (a.isDir !== b.isDir ? (a.isDir ? -1 : 1) : a.name.localeCompare(b.name, undefined, { sensitivity: 'base' })));
    };
    this.rootNodes = build(this.root, '');
  }

  // ── selection + detail ─────────────────────────────────────────────────

  select(path: string | null) {
    this.selectedPath = path;
    const s = path ? this.statuses.get(path) : undefined;
    this.detailMode = s && s !== 'untracked' && s !== 'added' ? 'diff' : 'preview';
    this.emit();
    void this.loadDetail();
  }
  setDetailMode(m: 'diff' | 'preview') { if (m !== this.detailMode) { this.detailMode = m; this.emit(); void this.loadDetail(); } }
  private setDetail(d: Detail) {
    if (this.imageURL && !(d.kind === 'image' && d.url === this.imageURL)) { URL.revokeObjectURL(this.imageURL); this.imageURL = null; }
    this.detail = d;
  }

  private async loadDetail() {
    const root = this.root, path = this.selectedPath;
    if (!root || !path) { this.setDetail({ kind: 'none' }); this.shownDetailKey = null; this.emit(); return; }
    const gen = ++this.detailGen;
    const key = `${path}|${this.detailMode}`;
    if (this.shownDetailKey !== key) { this.setDetail({ kind: 'loading' }); this.shownDetailKey = key; this.emit(); }
    try {
      if (this.detailMode === 'diff' && this.selectionHasDiff) {
        const o = this.origins.get(path);
        const [qr, qf] = o ? [q(o.repo), q(o.path)] : [q(root), q(path)];
        const out = await this.exec(`${RepoGitPrograms.off(qr)}git -C ${qr} diff HEAD --no-color ${RepoGitPrograms.diffFlags} -- ${qf} | head -c ${MAX_DIFF} | base64 -w0`);
        if (gen !== this.detailGen) return;
        this.setDetail({ kind: 'diff', doc: parseUnifiedDiff(decodeUTF8(b64ToBytes(out))) });
      } else if (this.statuses.get(path) === 'deleted') {
        if (gen !== this.detailGen) return;
        this.setDetail({ kind: 'error', message: 'File was deleted — switch to Diff to see what was removed.' });
      } else if (IMG.test(path)) {
        if (this.detail.kind === 'image' && this.shownDetailKey === key) return;   // a poll: keep the shown picture
        const bytes = await this.readAll(joinPath(root, path), MAX_IMAGE);
        if (gen !== this.detailGen) return;
        if (!bytes) { this.setDetail({ kind: 'tooLarge' }); }
        else {
          const ext = path.split('.').pop()!.toLowerCase();
          const mime = ext === 'svg' ? 'image/svg+xml' : ext === 'jpg' ? 'image/jpeg' : `image/${ext}`;
          const url = URL.createObjectURL(new Blob([bytes as BlobPart], { type: mime }));
          this.setDetail({ kind: 'image', url }); this.imageURL = url;
        }
      } else {
        const out = await this.exec(`head -c ${MAX_PREVIEW + 1} ${q(root)}/${q(path)} | base64 -w0`);
        if (gen !== this.detailGen) return;
        const data = b64ToBytes(out);
        if (data.length > MAX_PREVIEW) this.setDetail({ kind: 'tooLarge' });
        else if (data.subarray(0, 8192).includes(0)) this.setDetail({ kind: 'binary' });
        else {
          const text = decodeUTF8(data);
          const ext = (path.split('.').pop() ?? '').toLowerCase();
          this.setDetail(ext === 'md' || ext === 'markdown' ? { kind: 'markdown', text } : { kind: 'code', text, language: ext });
        }
      }
    } catch (e: any) {
      if (gen !== this.detailGen) return;
      this.setDetail({ kind: 'error', message: e?.message ?? String(e) });
    }
    this.emit();
  }

  // ── transfers ──────────────────────────────────────────────────────────

  /** The whole file (chunked reads); null past `cap` bytes. */
  private async readAll(guestPath: string, cap = Infinity, progress?: (n: number) => void): Promise<Uint8Array | null> {
    const chunks: Uint8Array[] = [];
    let offset = 0;
    for (;;) {
      const r = await this.fileOp({ op: 'read', path: guestPath, offset, length: CHUNK }, 60);
      const data = b64ToBytes(r?.data ?? '');
      chunks.push(data);
      offset += data.length;
      progress?.(offset);
      if (offset > cap) return null;
      const eof = r?.eof === true || r?.eof === 1 || data.length === 0;
      if (eof) break;
    }
    const out = new Uint8Array(offset);
    let at = 0;
    for (const c of chunks) { out.set(c, at); at += c.length; }
    return out;
  }

  /** Save to Downloads: download, then hand to the platform's save. */
  async saveToDownloads(relPath: string) {
    if (!this.root) return;
    const name = lastPathComponent(relPath);
    try {
      const bytes = await this.readAll(joinPath(this.root, relPath), Infinity, n => {
        this.transferText = `Copying ${name} out… ${fileBytes(n)}`; this.emit();
      });
      this.transferText = null; this.emit();
      if (bytes) await saveFile(name, bytes);
    } catch (e: any) {
      this.loadError = e?.message ?? String(e); this.transferText = null; this.emit();
    }
  }

  /** Copy dropped files (and whole folders, as one archive) into the folder on show. */
  async receive(items: { name: string; isDir: boolean; file?: File; entries?: TarEntry[] }[], intoDir?: string) {
    if (!this.root || !this.canTransfer) return;
    const base = intoDir ? joinPath(this.root, intoDir) : this.root;
    let note: string | null = null;
    for (const it of items) {
      const name = safeRelativePath(it.name);
      if (!name || name.includes('/')) continue;      // a drop's top-level item is one name
      const dest = joinPath(base, name);
      try {
        if (it.isDir) note = await this.uploadFolder(it.name, it.entries ?? [], dest) ?? note;
        else if (it.file) await this.uploadFile(it.file, dest, it.name);
      } catch (e: any) { note = e?.message ?? String(e); }
    }
    this.transferText = null;
    this.emit();
    await this.refresh();
    if (note) { this.loadError = note; this.emit(); }
  }

  /** Stream into a guest file, one CHUNK in memory at a time. */
  /** Stream into a guest file, one CHUNK in memory at a time; a copy that
   *  fails part-way leaves no partial file (writeGuestFile). */
  private async writeStream(stream: ReadableStream<Uint8Array>, guestPath: string, label: string, staged = false) {
    await writeGuestFile(stream, guestPath, CHUNK, (op, t) => this.fileOp(op, t), bytesToB64,
      sent => { this.transferText = `Copying ${label} in… ${fileBytes(sent)}`; this.emit(); }, staged);
  }
  /** A dropped file lands on its destination only once complete: a copy
   *  that fails part-way leaves a file already there untouched. */
  private async uploadFile(file: File, guestPath: string, label: string) {
    await replaceGuestFile(() => file.stream(), guestPath, CHUNK, (op, t) => this.fileOp(op, t), bytesToB64,
      sent => { this.transferText = `Copying ${label} in… ${fileBytes(sent)}`; this.emit(); });
  }
  private async uploadFolder(name: string, entries: TarEntry[], guestDir: string): Promise<string | null> {
    this.transferText = `Packing ${name}…`; this.emit();
    const guestArchive = `/tmp/bromure-drop-${crypto.randomUUID().toUpperCase()}.tgz`;
    // Owner-only while it fills and until it's unpacked (CWE-200).
    await this.writeStream(tarGzStream(entries), guestArchive, name, true);
    this.transferText = `Unpacking ${name}…`; this.emit();
    try {
      const r = await this.fileOp({ op: 'untar', path: guestDir, archive: guestArchive }, 600);
      const skipped = r?.skippedCount ?? 0;
      return skipped > 0 ? `${skipped} items in “${name}” weren't copied: they point outside the folder or aren't regular files.` : null;
    } catch {
      await this.fileOp({ op: 'remove', path: guestArchive }).catch(() => {});
      await this.fileOp({ op: 'mkdir', path: guestDir });
      for (const e of entries) {
        const rel = safeRelativePath(e.path);
        if (!rel) continue;                            // would escape the folder: never written
        const dest = joinPath(guestDir, rel);
        if (e.dir) await this.fileOp({ op: 'mkdir', path: dest });
        else if (e.file) await this.uploadFile(e.file, dest, lastPathComponent(e.path));
      }
      return null;
    }
  }

  dispose() { this.refreshGen++; this.detailGen++; this.setDetail({ kind: 'none' }); this.listeners.clear(); }
}

function splitBytes(b: Uint8Array, sep: number, max = Infinity): Uint8Array[] {
  const out: Uint8Array[] = [];
  let start = 0;
  for (let i = 0; i < b.length && out.length < max - 1; i++) if (b[i] === sep) { out.push(b.subarray(start, i)); start = i + 1; }
  out.push(b.subarray(start));
  return out;
}

function mapStatuses(root: string, sections: { top: string; porcelain: string }[]) {
  const statuses = new Map<string, GitStatus>(), origins = new Map<string, { repo: string; path: string }>();
  const rootPrefix = root.endsWith('/') ? root : root + '/';
  for (const { top, porcelain } of sections) {
    if (!top) continue;
    const parsed = parsePorcelain(porcelain);
    if (top === root) for (const [k, v] of parsed) { statuses.set(k, v); origins.set(k, { repo: top, path: k }); }
    else if (root.startsWith(top + '/')) {
      const prefix = root.slice(top.length + 1) + '/';
      for (const [k, v] of parsed) if (k.startsWith(prefix)) { const rel = k.slice(prefix.length); statuses.set(rel, v); origins.set(rel, { repo: top, path: k }); }
    } else if (top.startsWith(rootPrefix)) {
      const prefix = top.slice(rootPrefix.length) + '/';
      for (const [k, v] of parsed) { statuses.set(prefix + k, v); origins.set(prefix + k, { repo: top, path: k }); }
    }
  }
  return { statuses, origins };
}
