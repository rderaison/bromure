// Shared helpers for the machines surface: formatters (the Swift's String
// formats), shell quoting, guest paths, and the guest-side git hardening
// (RepoGitPrograms.swift) every git command run in a guest carries.

import type { RemoteState, VMInfo, Workspace } from '../../core/remote/types';

export type RunState = 'running' | 'booting' | 'suspended' | 'off';

export function runState(ws: Workspace | undefined, vm?: VMInfo): RunState {
  const s = (ws?.state ?? vm?.state ?? 'off') as string;
  if (s === 'running' || s === 'booting' || s === 'suspended') return s;
  if (s === 'starting') return 'booting';
  return 'off';
}
export const isUp = (s: RunState) => s === 'running' || s === 'booting';

export function vmFor(state: RemoteState | null | undefined, id: string): VMInfo | undefined {
  return state?.vms?.find(v => v.id.toUpperCase() === id.toUpperCase());
}
export function workspaceFor(state: RemoteState | null | undefined, id: string): Workspace | undefined {
  return state?.workspaces?.find(w => w.id.toUpperCase() === id.toUpperCase());
}

/** Single-quote for POSIX sh: ' → '\''. */
export const shellQuote = (s: string) => "'" + s.replace(/'/g, "'\\''") + "'";

/** "~" conventions → an absolute guest path (SessionHome.guestPath). */
export function guestPath(path: string | undefined): string {
  const home = '/home/ubuntu';
  const t = (path ?? '').trim();
  if (!t || t === '~') return home;
  if (t.startsWith('~/')) return home + t.slice(1);
  if (t.startsWith('/')) return t;
  return home + '/' + t;
}
/** /home/ubuntu/x → ~/x (prettyGuestPath). */
export function prettyGuestPath(p: string): string {
  if (p === '/home/ubuntu') return '~';
  if (p.startsWith('/home/ubuntu/')) return '~' + p.slice('/home/ubuntu'.length);
  return p;
}
export const lastPathComponent = (p: string) => { const t = p.replace(/\/+$/, ''); const i = t.lastIndexOf('/'); return i >= 0 ? t.slice(i + 1) || '/' : t; };
export const dirname = (p: string) => { const i = p.lastIndexOf('/'); return i > 0 ? p.slice(0, i) : i === 0 ? '/' : ''; };
export const joinPath = (a: string, b: string) => (a.endsWith('/') ? a : a + '/') + b.replace(/^\/+/, '');
/** A relative path from a drop/upload, or null when it could escape its
 *  folder (a `..` member, NUL, absolute) — never written then. */
export function safeRelativePath(p: string): string | null {
  if (!p || p.includes('\0')) return null;
  const parts = p.replace(/\\/g, '/').split('/').filter(x => x && x !== '.');
  if (!parts.length || parts.some(x => x === '..')) return null;
  return parts.join('/');
}

// ── formatters ───────────────────────────────────────────────────────────

/** KB → "N.N GB" / "N MB" (VMDashboard.gb). */
export function gbKB(kb: number): string {
  const mb = kb / 1024;
  return mb >= 1024 ? `${(mb / 1024).toFixed(1)} GB` : `${mb.toFixed(0)} MB`;
}
export function gbBytes(b: number): string {
  const g = b / 1_073_741_824;
  return g >= 1 ? `${g.toFixed(1)} GB` : `${(b / 1_048_576).toFixed(0)} MB`;
}
/** kubeFormatBytes. */
export function kubeBytes(b: number): string {
  const tb = 2 ** 40, gb = 2 ** 30, mb = 2 ** 20, kb = 2 ** 10;
  if (b >= tb) return `${(b / tb).toFixed(1)} TB`;
  if (b >= gb) return `${(b / gb).toFixed(1)} GB`;
  if (b >= mb) return `${(b / mb).toFixed(0)} MB`;
  if (b >= kb) return `${(b / kb).toFixed(0)} KB`;
  return `${b} B`;
}
/** ByteCountFormatter .file (decimal units, like Finder). */
export function fileBytes(b: number): string {
  if (b < 1000) return b === 0 ? 'Zero KB' : `${b} bytes`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let v = b / 1000, i = 0;
  while (v >= 1000 && i < units.length - 1) { v /= 1000; i++; }
  return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}
export function kubeUptime(since: Date): string {
  const s = Math.floor((Date.now() - since.getTime()) / 1000);
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
  return `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h`;
}
/** RelativeDateTimeFormatter, abbreviated ("6m ago", "2h ago", "in 3d"). */
export function relativeShort(d: Date, now = Date.now()): string {
  const s = Math.round((d.getTime() - now) / 1000);
  const a = Math.abs(s);
  const [n, u] = a < 60 ? [a, 'sec.'] : a < 3600 ? [Math.round(a / 60), 'min.'] : a < 86400 ? [Math.round(a / 3600), 'hr.'] : a < 604800 ? [Math.round(a / 86400), 'day'] : a < 2629800 ? [Math.round(a / 604800), 'wk.'] : [Math.round(a / 2629800), 'mo.'];
  const unit = u === 'day' && n !== 1 ? 'days' : u;
  return s <= 0 ? `${n} ${unit} ago` : `in ${n} ${unit}`;
}
/** .abbreviated units style ("6m ago"). */
export function relativeAbbrev(d: Date, now = Date.now()): string {
  const s = Math.round((d.getTime() - now) / 1000);
  const a = Math.abs(s);
  const t = a < 60 ? `${a}s` : a < 3600 ? `${Math.round(a / 60)}m` : a < 86400 ? `${Math.round(a / 3600)}h` : a < 604800 ? `${Math.round(a / 86400)}d` : `${Math.round(a / 604800)}w`;
  return s <= 0 ? `${t} ago` : `in ${t}`;
}
/** Date.formatted(date: .abbreviated, time: .shortened): "Nov 25, 2026 at 8:15 AM". */
export function abbreviatedDateTime(d: Date): string {
  const date = d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
  const time = d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
  return `${date} at ${time}`;
}

export function copyText(text: string) {
  try { void navigator.clipboard.writeText(text); } catch { /* insecure context */ }
}

// ── the guest's git hardening (RepoGitPrograms.swift), verbatim ──────────

const programKeys = String.raw`^(filter\..*\.(clean|smudge|process)|merge\..*\.driver|gpg\.([^.]*\.)?program)$`;

export const RepoGitPrograms = {
  /** Shell that switches off every program the repository's own config names. */
  off(dir: string): string {
    const read = `git -C ${dir} config --show-scope --name-only --get-regexp '${programKeys}'`;
    const userValue = `_bg() { git -C ${dir} config -z --show-scope --get-all "$1" 2>/dev/null `
      + String.raw`| LC_ALL=C tr '\n\000' '\001\n' | LC_ALL=C awk 'NR % 2 == 1 { s = $0; next } s == "global" || s == "system" { v = $0; f = 1 } END { if (f) { gsub(/\001/, "\n", v); print v }; exit !f }'; }; `;
    return userValue + `_bk=$( { ${read}; } 2>/dev/null `
      + String.raw`| awk '{ s = $0; sub(/\t.*/, "", s); if (s == "local" || s == "worktree") { sub(/^[^\t]*\t/, ""); print } }'); `
      + 'export GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null '
      + 'GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=false; _bn=2; '
      + "set -f; _bo=$IFS; IFS=$(printf '\\n_'); IFS=${IFS%_}; "
      + 'for _bx in $_bk; do '
      + '_bv=$(_bg "$_bx") '
      + '|| case "$_bx" in (filter.*.clean|filter.*.smudge) _bv=cat ;; '
      + '(filter.*.process) _bv=; _bd=${_bx%.process}; _br=false; '
      + 'if [ -n "$( { _bg "$_bd.clean" || :; _bg "$_bd.smudge" || :; } )" ]; then _br=true; fi; '
      + 'export "GIT_CONFIG_KEY_$_bn=$_bd.required" "GIT_CONFIG_VALUE_$_bn=$_br"; _bn=$((_bn + 1)) ;; '
      + '(*) _bv= ;; esac; '
      + 'export "GIT_CONFIG_KEY_$_bn=$_bx" "GIT_CONFIG_VALUE_$_bn=$_bv"; _bn=$((_bn + 1)); done; '
      + 'IFS=$_bo; set +f; export GIT_CONFIG_COUNT=$_bn; ';
  },
  statusFailedLine: '!! (git status failed)',
  get statusFailed() { return ` || echo '${this.statusFailedLine}'`; },
  dirtySubmodules(dir: string, nul = false): string {
    const end = nul ? '\\0' : '\\n';
    const unquote = String.raw`{ s = substr($0, 2, length($0) - 2); o = ""; for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c != "\\") { o = o c; continue }; c = substr(s, ++i, 1); if (c ~ /[0-7]/) { o = o sprintf("%c", c * 64 + substr(s, i + 1, 1) * 8 + substr(s, i + 2, 1)); i += 2 } else if (c == "n") o = o "\n"; else if (c == "t") o = o "\t"; else if (c == "r") o = o "\r"; else if (c == "a") o = o "\007"; else if (c == "b") o = o "\b"; else if (c == "f") o = o "\f"; else if (c == "v") o = o "\v"; else o = o c }; printf "%s", o }`;
    return `_bsl() { git -c core.quotePath=false -C "$1" ls-files --stage 2>/dev/null `
      + `| awk -F'\\t' '$1 ~ /^160000 /{print $2}'; }; `
      + `_bsp() { case "$1" in (\\"*) _p=$(printf '%s\\n' "$1" | LC_ALL=C awk '${unquote}'; printf x); _p=\${_p%x} ;; (*) _p=$1 ;; esac; }; `
      + `_bsd() { [ -n "$( ( cd "$1" || { echo '!!'; exit; }; ${this.off('.')}git status --porcelain --ignore-submodules=dirty${this.statusFailed} ) 2>/dev/null | head -c1)" ] `
      + `&& return 0; _bsl "$1" | { while IFS= read -r _s; do _bsp "$_s"; [ -e "$1/$_p/.git" ] && _bsd "$1/$_p" && exit 0; done; exit 1; }; }; `
      + `_bsl ${dir} | while IFS= read -r _s; do _bsp "$_s"; _q=$_p; [ -e ${dir}/"$_q/.git" ] && _bsd ${dir}/"$_q" `
      + `&& printf ' M %s${end}' "${nul ? '$_q' : '$_s'}"; done; `;
  },
  diffFlags: '--no-ext-diff --no-textconv --ignore-submodules=dirty',
};

// ── base64 ───────────────────────────────────────────────────────────────

export function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64.replace(/\s+/g, ''));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
export function bytesToB64(bytes: Uint8Array): string {
  let s = '';
  const CH = 0x8000;
  for (let i = 0; i < bytes.length; i += CH) s += String.fromCharCode(...bytes.subarray(i, i + CH));
  return btoa(s);
}
export const decodeUTF8 = (b: Uint8Array) => new TextDecoder().decode(b);

/** The workspace accent color (`accentHex`, else the ProfileColor). */
const PROFILE_COLORS: Record<string, string> = {
  blue: '#3B82F6', purple: '#A855F7', green: '#22C55E', orange: '#F97316', red: '#EF4444',
  pink: '#EC4899', teal: '#14B8A6', yellow: '#EAB308', indigo: '#6366F1', gray: '#6B7280', graphite: '#6B7280',
};
export function accentOf(ws?: Workspace): string {
  return ws?.accentHex || PROFILE_COLORS[ws?.color ?? ''] || '#3B82F6';
}
