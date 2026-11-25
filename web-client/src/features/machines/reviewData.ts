// TaskReviewData / TaskDiffParser (TaskReviewWindow.swift, CodingTasks.swift):
// what an agent changed, read live from the machine — base, log, status and
// a capped diff in one guest command — and the worktree registry listing the
// Branches window shows (WorktreeEntry, AgentSessions.swift).

import { RepoGitPrograms, shellQuote as q, dirname } from './util';

export type Base = { kind: 'uncommitted' } | { kind: 'branch'; parent: string } | { kind: 'lastCommit' } | { kind: 'since'; at: Date };
export const baseKey = (b: Base) => b.kind === 'branch' ? `branch:${b.parent}` : b.kind === 'since' ? `since:${b.at.getTime()}` : b.kind;

export interface DiffFileLine { id: number; kind: 'context' | 'added' | 'removed' | 'hunk'; text: string; newLine?: number }
export interface DiffFile { path: string; lines: DiffFileLine[]; raw: string; added: number; removed: number }
export interface ReviewData { baseRef: string; logLines: string[]; statusLines: string[]; statusFailed: boolean; diffFailed: boolean; files: DiffFile[] }

const DIFF_FAILED = '!! (git diff failed)';
const EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';
const statusFilter = String.raw`grep -vE '^\?\? (.*/)?(__pycache__/|node_modules/|\.DS_Store$|[^/]*\.pyc$)'`;
const pathFilter = String.raw`grep -vE '(^|/)(__pycache__|node_modules)/|(^|/)\.DS_Store$|\.pyc$'`;

export function sessionReviewCommand(dir: string, base: Base, focusFiles: string[] = []): string {
  const parents = focusFiles.filter(f => f.startsWith('/')).slice(0, 12).map(dirname);
  const enter = parents.length
    ? `d=; for p in ${parents.map(q).join(' ')}; do d=$(git -C "$p" rev-parse --show-toplevel 2>/dev/null) && [ -n "$d" ] && break; d=; done; [ -n "$d" ] || d=${q(dir)}; cd "$d" || exit 1`
    : `cd ${q(dir)} || exit 1`;
  let setBase: string, withWorktree = true;
  switch (base.kind) {
    case 'uncommitted': setBase = 'b=HEAD'; break;
    case 'branch': setBase = `b=$(git merge-base ${q(base.parent)} HEAD 2>/dev/null || echo ${q(base.parent)})`; break;
    case 'lastCommit': setBase = 'b=HEAD~1'; withWorktree = false; break;
    case 'since': setBase = `b=$(git rev-list -1 --before=@${Math.floor(base.at.getTime() / 1000)} HEAD 2>/dev/null); [ -n "$b" ] || b=${EMPTY_TREE}`; break;
  }
  const fallback = base.kind === 'uncommitted' || base.kind === 'lastCommit' ? `; git rev-parse -q --verify "$b^{tree}" >/dev/null 2>&1 || b=${EMPTY_TREE}` : '';
  const df = RepoGitPrograms.diffFlags;
  const exists = (rev: string) => `git rev-parse -q --verify "${rev}^{tree}" >/dev/null 2>&1`;
  const failed = 'echo 1 > "$dfail"';
  const untracked = `git ls-files --others --exclude-standard 2>/dev/null | ${pathFilter} | head -n 40 `
    + `| while IFS= read -r f; do [ "$(stat -c%s "$f" 2>/dev/null || echo 0)" -lt 204800 ] `
    + `&& git diff ${df} --no-index -- /dev/null "$f"; done`;
  const diff = withWorktree
    ? `{ if git diff ${df} "$b" -- 2>/dev/null; then ${untracked}; elif ${exists('$b')}; then ${failed}; else ${untracked}; fi; }`
    : `{ git diff ${df} "$b" HEAD -- 2>/dev/null || { ${exists('$b')} && ${exists('HEAD')} && ${failed}; }; }`;
  return `${enter}; ${RepoGitPrograms.off('.')}${setBase}${fallback}; echo ===BASE===; git rev-parse --short "$b" 2>/dev/null; `
    + `echo ===LOG===; [ "$b" = HEAD ] || git log --oneline "$b..HEAD" 2>/dev/null | head -50; `
    + `echo ===STATUS===; { git status --porcelain --ignore-submodules=dirty 2>/dev/null${RepoGitPrograms.statusFailed}; ${RepoGitPrograms.dirtySubmodules('.')} } | ${statusFilter} | head -100; `
    + `echo ===DIFF===; dfail=$(mktemp 2>/dev/null) || dfail=/tmp/bromure-review.$$; : > "$dfail"; `
    + `${diff} | { head -c 600000; cat >/dev/null; }; `
    + `[ -s "$dfail" ] && printf '\\n%s\\n' '${DIFF_FAILED}'; rm -f "$dfail"; true`;
}

export function parseReview(raw: string): ReviewData {
  const out: ReviewData = { baseRef: '', logLines: [], statusLines: [], statusFailed: false, diffFailed: false, files: [] };
  let section = '';
  const diff: string[] = [];
  for (const line of raw.split('\n')) {
    if (line === '===BASE===') { section = 'base'; continue; }
    if (line === '===LOG===') { section = 'log'; continue; }
    if (line === '===STATUS===') { section = 'status'; continue; }
    if (line === '===DIFF===') { section = 'diff'; continue; }
    if (section === 'base') { if (line && !out.baseRef) out.baseRef = line; }
    else if (section === 'log') { if (line) out.logLines.push(line); }
    else if (section === 'status') { if (line) out.statusLines.push(line); }
    else if (section === 'diff') { if (line === DIFF_FAILED) out.diffFailed = true; else diff.push(line); }
  }
  out.statusFailed = out.statusLines.includes(RepoGitPrograms.statusFailedLine);
  out.files = out.diffFailed ? [] : parseDiffFiles(diff.join('\n'));
  return out;
}

export function parseDiffFiles(raw: string): DiffFile[] {
  const files: DiffFile[] = [];
  let cur: DiffFile | null = null, rawLines: string[] = [], id = 0, newCounter = 0;
  const close = () => {
    if (!cur) return;
    while (rawLines.length && rawLines[rawLines.length - 1] === '') rawLines.pop();
    cur.raw = rawLines.join('\n') + '\n';
    cur.added = cur.lines.filter(l => l.kind === 'added').length;
    cur.removed = cur.lines.filter(l => l.kind === 'removed').length;
    files.push(cur); rawLines = [];
  };
  for (const line of raw.split('\n')) {
    if (line.startsWith('diff --git ')) {
      close();
      const t = line.trim(), i = t.lastIndexOf(' b/');
      cur = { path: i >= 0 ? t.slice(i + 3) : t.split(' ').pop()!, lines: [], raw: '', added: 0, removed: 0 };
      rawLines = [line];
      continue;
    }
    if (!cur) continue;
    rawLines.push(line);
    if (/^(index |--- |\+\+\+ |new file|deleted file|similarity|rename |Binary files|old mode|new mode)/.test(line)) continue;
    id++;
    const kind: DiffFileLine['kind'] = line.startsWith('@@') ? 'hunk' : line.startsWith('+') ? 'added' : line.startsWith('-') ? 'removed' : 'context';
    let newLine: number | undefined;
    if (kind === 'hunk') { const m = /\+(\d+)/.exec(line.split('@@')[1] ?? ''); if (m) newCounter = +m[1]; }
    else if (kind === 'added' || kind === 'context') newLine = newCounter++;
    cur.lines.push({ id, kind, text: line, newLine });
  }
  close();
  return files;
}

/** FNV-1a over the file's lines — the "viewed" mark's version. */
export function fingerprint(f: DiffFile): string {
  let h = 0xcbf29ce484222325n;
  const P = 0x100000001b3n, M = (1n << 64n) - 1n;
  const enc = new TextEncoder();
  for (const l of f.lines) {
    for (const b of enc.encode(l.text)) h = ((h ^ BigInt(b)) * P) & M;
    h = ((h ^ 0x0an) * P) & M;
  }
  return h.toString(16);
}
export const patchOf = (files: DiffFile[]) => files.map(f => f.raw.endsWith('\n') ? f.raw : f.raw + '\n').join('');

// ── worktrees (Branches window) ──────────────────────────────────────────

export interface WorktreeEntry { dir: string; root: string; branch: string; parent: string; ahead: number; changed: number; lastCommit: Date | null; display: string }
export const worktreeIsEmpty = (e: WorktreeEntry) => e.ahead === 0 && e.changed === 0;

export function worktreeListCommand(): string {
  return `for d in "$HOME"/.bromure/worktrees/*/*/; do d="\${d%/}"; [ -e "$d/.git" ] || continue; `
    + `cd "$d" 2>/dev/null || continue; `
    + `r=$(git worktree list --porcelain 2>/dev/null | head -1 | cut -c10-); `
    + `b=$(git rev-parse --abbrev-ref HEAD 2>/dev/null); `
    + `reg="$(dirname "$d")/.registry"; p=""; disp=""; `
    + `[ -f "$reg" ] && p=$(awk -F"$(printf '\\037')" -v b="$b" '$1==b{print $2}' "$reg" | tail -1) `
    + `&& disp=$(awk -F"$(printf '\\037')" -v b="$b" '$1==b{print $3}' "$reg" | tail -1); `
    + `[ -n "$p" ] || p=$(git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null); `
    + `a=$(git rev-list --count "$p..HEAD" 2>/dev/null || echo 0); `
    + `c=$( { ${RepoGitPrograms.off('.')}git status --porcelain --ignore-submodules=dirty 2>/dev/null${RepoGitPrograms.statusFailed}; ${RepoGitPrograms.dirtySubmodules('.')} } | wc -l | tr -d ' '); `
    + `t=$(git log -1 --format=%ct 2>/dev/null || echo 0); `
    + `printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$d" "$r" "$b" "$p" "$a" "$c" "$t" "$disp"; `
    + `done; true`;
}
export function parseWorktrees(out: string): WorktreeEntry[] {
  return out.split('\n').map(line => line.split('\t')).filter(f => f.length >= 8 && f[0] && f[2]).map(f => {
    const t = parseFloat(f[6]) || 0;
    return { dir: f[0], root: f[1], branch: f[2], parent: f[3], ahead: parseInt(f[4], 10) || 0, changed: parseInt(f[5], 10) || 0,
             lastCommit: t > 0 ? new Date(t * 1000) : null, display: f[7] };
  });
}
