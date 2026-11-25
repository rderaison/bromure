// The task review window (TaskReviewWindow.swift): the summary banner with
// the landing actions, the branch's changed files and their diff with line
// comments — read from the remote guest through the host's /vms/<id>/exec —
// and the task transcript window (TaskTranscriptWindow.swift).

import React, { useCallback, useEffect, useState } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import { seg } from '../../core/remote/host';
import { useRemote } from '../../app/store';
import { useHostCtx } from '../../app/hostContext';
import { useWindows, type WindowSpec } from '../../app/windows';
import { SF } from '../../ui/icons';
import { Button, Checkbox, PopUp, Sheet, Spinner, cx, useMenu, type MenuItem, safeHref } from '../../ui/kit';
import { type CodingTask, tasksOf, workspaceOf, accentOf, isNoCode, landingLine, landingTarget, workerName, unsentComments, taskSession } from './model';
import { Markdown } from './Markdown';
import { parseTranscript, TranscriptView, b64utf8, type Item } from './Transcript';
import { confirm, Loading } from './kanban';
import { droppedSuffix } from './TaskBoard';
import './boards.css';

type WM = { open: (w: WindowSpec) => void; close: (id: string) => void };
const post = (host: RemoteHost, id: string, action: string, body?: unknown) => host.send('POST', `/tasks/${seg(id)}/${action}`, body);

// ── Guest commands (TaskReviewData / TaskReviewSummary / RepoGitPrograms) ─

const q = (s: string) => "'" + s.replace(/'/g, "'\\''") + "'";
const PROGRAM_KEYS = String.raw`^(filter\..*\.(clean|smudge|process)|merge\..*\.driver|gpg\.([^.]*\.)?program)$`;
const DIFF_FLAGS = '--no-ext-diff --no-textconv --ignore-submodules=dirty';
const STATUS_FILTER = String.raw`grep -vE '^\?\? (.*/)?(__pycache__/|node_modules/|\.DS_Store$|[^/]*\.pyc$)'`;
const PATH_FILTER = String.raw`grep -vE '(^|/)(__pycache__|node_modules)/|(^|/)\.DS_Store$|\.pyc$'`;
const EMPTY_TREE = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';

/** RepoGitPrograms.off: what the repository's own config names never runs. */
function gitProgramsOff(dir: string) {
  const read = `git -C ${dir} config --show-scope --name-only --get-regexp '${PROGRAM_KEYS}'`;
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
}

type Base = { kind: 'branch'; parent: string } | { kind: 'uncommitted' } | { kind: 'lastCommit' };
function reviewCommand(dir: string, base: Base) {
  const setBase = base.kind === 'branch' ? `b=$(git merge-base ${q(base.parent)} HEAD 2>/dev/null || echo ${q(base.parent)})`
    : base.kind === 'lastCommit' ? `b=HEAD~1; git rev-parse -q --verify "$b^{tree}" >/dev/null 2>&1 || b=${EMPTY_TREE}`
    : `b=HEAD; git rev-parse -q --verify "$b^{tree}" >/dev/null 2>&1 || b=${EMPTY_TREE}`;
  const untracked = `git ls-files --others --exclude-standard 2>/dev/null | ${PATH_FILTER} | head -n 40 `
    + `| while IFS= read -r f; do [ "$(stat -c%s "$f" 2>/dev/null || echo 0)" -lt 204800 ] && git diff ${DIFF_FLAGS} --no-index -- /dev/null "$f"; done`;
  const diff = base.kind === 'lastCommit' ? `git diff ${DIFF_FLAGS} "$b" HEAD -- 2>/dev/null` : `{ git diff ${DIFF_FLAGS} "$b" -- 2>/dev/null; ${untracked}; }`;
  return `cd ${q(dir)} || exit 1; ${gitProgramsOff('.')}${setBase}; echo ===BASE===; git rev-parse --short "$b" 2>/dev/null; `
    + `echo ===LOG===; [ "$b" = HEAD ] || git log --oneline "$b..HEAD" 2>/dev/null | head -50; `
    + `echo ===STATUS===; git status --porcelain --ignore-submodules=dirty 2>/dev/null | ${STATUS_FILTER} | head -100; `
    + `echo ===DIFF===; ${diff} | { head -c 600000; cat >/dev/null; }; true`;
}

function summaryCommand(root: string, wt: string | undefined, branch: string, target: string) {
  let cmd = `r=${q(root)}; ${gitProgramsOff('"$r"')}echo "AB $(git -C "$r" rev-list --left-right --count ${q(target + '...' + branch)} 2>/dev/null)"; `;
  if (wt) {
    cmd += `w=${q(wt)}; m=$(git -C "$w" merge-base ${q(target)} HEAD 2>/dev/null); `
      + `echo "SS $(git -C "$w" diff ${DIFF_FLAGS} --shortstat "$m" 2>/dev/null)"; `
      + `echo "UC $(git -C "$w" status --porcelain --untracked-files=all --ignore-submodules=dirty 2>/dev/null | ${STATUS_FILTER} | wc -l | tr -d ' ')"; `;
  } else cmd += `echo "SS $(git -C "$r" diff --shortstat ${q(target + '...' + branch)} 2>/dev/null)"; echo 'UC 0'; `;
  cmd += `d=$(git -C "$r" worktree list --porcelain 2>/dev/null | awk -v want=${q('branch refs/heads/' + target)} '/^worktree /{w=substr($0,10)} $0==want{print w; exit}'); echo "TD $d"; `
    + `[ -n "$d" ] && echo "TC $(git -C "$d" status --porcelain --ignore-submodules=dirty 2>/dev/null | ${STATUS_FILTER} | wc -l | tr -d ' ')"; `
    + `rm=$(git -C "$r" remote 2>/dev/null | grep -v '^-' | head -1); echo "RM $rm"; true`;
  return cmd;
}

interface Summary { ahead: number; behind: number; files: number; ins: number; del: number; uncommitted: number; targetDirty?: number; remote?: string }
function parseSummary(out: string): Summary {
  const s: Summary = { ahead: 0, behind: 0, files: 0, ins: 0, del: 0, uncommitted: 0 };
  for (const line of out.split('\n')) {
    const tag = line.slice(0, 2), rest = line.slice(3).trim();
    if (tag === 'AB') { const n = rest.split(/\s+/).map(Number); if (n.length === 2 && n.every(x => !isNaN(x))) { s.behind = n[0]; s.ahead = n[1]; } }
    else if (tag === 'SS') for (const part of rest.split(',')) { const n = parseInt(part); if (isNaN(n)) continue; if (part.includes('file')) s.files = n; else if (part.includes('insertion')) s.ins = n; else if (part.includes('deletion')) s.del = n; }
    else if (tag === 'UC') s.uncommitted = +rest || 0;
    else if (tag === 'TC') s.targetDirty = +rest || 0;
    else if (tag === 'RM') s.remote = rest && /^[A-Za-z0-9._-]+$/.test(rest) ? rest : undefined;
  }
  return s;
}

export interface DiffLine { kind: 'ctx' | 'add' | 'del' | 'hunk' | 'meta'; text: string; newLine?: number; oldLine?: number }
export interface DiffFile { path: string; status: 'added' | 'deleted' | 'modified' | 'renamed'; adds: number; dels: number; lines: DiffLine[]; binary?: boolean }
export function parseDiff(text: string): DiffFile[] {
  const files: DiffFile[] = []; let f: DiffFile | null = null; let o = 0, n = 0;
  for (const line of text.split('\n')) {
    if (line.startsWith('diff --git ')) {
      const m = /^diff --git a\/(.*) b\/(.*)$/.exec(line);
      f = { path: m?.[2] ?? line.slice(11), status: 'modified', adds: 0, dels: 0, lines: [] };
      files.push(f); continue;
    }
    if (!f) continue;
    if (line.startsWith('new file')) { f.status = 'added'; continue; }
    if (line.startsWith('deleted file')) { f.status = 'deleted'; continue; }
    if (line.startsWith('rename to ')) { f.status = 'renamed'; f.path = line.slice(10); continue; }
    if (line.startsWith('Binary files')) { f.binary = true; continue; }
    if (line.startsWith('index ') || line.startsWith('--- ') || line.startsWith('+++ ') || line.startsWith('similarity') || line.startsWith('rename from') || line.startsWith('old mode') || line.startsWith('new mode')) continue;
    const h = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$/.exec(line);
    if (h) { o = +h[1]; n = +h[2]; f.lines.push({ kind: 'hunk', text: line }); continue; }
    if (line.startsWith('+')) { f.adds++; f.lines.push({ kind: 'add', text: line.slice(1), newLine: n++ }); }
    else if (line.startsWith('-')) { f.dels++; f.lines.push({ kind: 'del', text: line.slice(1), oldLine: o++ }); }
    else if (line.startsWith(' ')) f.lines.push({ kind: 'ctx', text: line.slice(1), oldLine: o++, newLine: n++ });
    else if (line.startsWith('\\')) f.lines.push({ kind: 'meta', text: line });
  }
  return files;
}
function parseReview(raw: string) {
  let sec = ''; const log: string[] = [], status: string[] = [], diff: string[] = []; let baseRef = '';
  for (const line of raw.split('\n')) {
    if (line === '===BASE===') { sec = 'base'; continue; }
    if (line === '===LOG===') { sec = 'log'; continue; }
    if (line === '===STATUS===') { sec = 'status'; continue; }
    if (line === '===DIFF===') { sec = 'diff'; continue; }
    if (sec === 'base' && line && !baseRef) baseRef = line;
    else if (sec === 'log' && line) log.push(line);
    else if (sec === 'status' && line) status.push(line);
    else if (sec === 'diff') diff.push(line);
  }
  return { baseRef, log, status, files: parseDiff(diff.join('\n')) };
}

// ── Windows ─────────────────────────────────────────────────────────────

export function openTaskReview(wm: WM, host: RemoteHost, id: string, confirmMode?: 'merge' | 'squash' | 'pr') {
  const t = tasksOf(host.state).find(x => x.id === id);
  wm.open({
    id: 'task-review:' + id, title: t?.title ?? 'Review', width: 1100, height: 760, minWidth: 640, minHeight: 420,
    render: ctx => <TaskReviewView host={host} id={id} confirmMode={confirmMode} close={ctx.close} />,
  });
}

export function openTaskTranscript(wm: WM, host: RemoteHost, id: string) {
  const t = tasksOf(host.state).find(x => x.id === id);
  wm.open({
    id: 'task-transcript:' + id, title: `Transcript — ${t?.title ?? ''}`, width: 760, height: 640, minWidth: 520, minHeight: 400,
    render: () => <TaskTranscriptView host={host} id={id} />,
  });
}

function TaskTranscriptView({ host, id }: { host: RemoteHost; id: string }) {
  const st = useRemote(host, s => s);
  const t = tasksOf(st).find(x => x.id === id);
  const [items, setItems] = useState<Item[] | null | 'none'>(null);
  useEffect(() => {
    let live = true;
    host.request<any>('GET', `/tasks/${seg(id)}/transcript`, undefined, { timeoutMs: 100_000 } as any)
      .then(r => { if (!live) return; const raw = r?.transcript ? b64utf8(r.transcript) : ''; const p = raw ? parseTranscript(raw) : []; setItems(p.length ? p : 'none'); })
      .catch(() => live && setItems('none'));
    return () => { live = false; };
  }, [host, id]);
  return (
    <div className="bx-rw">
      <div className="bx-rw-head">
        <span className="bx-rw-bar" style={{ background: accentOf(st, t?.profileID), height: 30 }} />
        <div className="bd-stack" style={{ gap: 2, minWidth: 0 }}>
          <div className="bx-rw-title truncate">{t?.title ?? ''}</div>
          <div className="bx-rw-sub">{workspaceOf(st, t?.profileID)?.name ?? ''}</div>
        </div>
      </div>
      {items === null ? <Loading text="Reading the transcript…" />
        : items === 'none' ? (
          <div className="empty-state" style={{ flex: 1 }}>
            <SF name="doc.questionmark" size={34} color="var(--label-tertiary)" />
            <h3>Transcript unavailable</h3><span>No transcript was found for this task in the workspace's home.</span>
          </div>
        ) : <TranscriptView items={items} />}
    </div>
  );
}

function TaskReviewView({ host, id, confirmMode, close }: { host: RemoteHost; id: string; confirmMode?: 'merge' | 'squash' | 'pr'; close: () => void }) {
  const st = useRemote(host, s => s);
  const ctx = useHostCtx();
  const t = tasksOf(st).find(x => x.id === id);
  const [baseKind, setBaseKind] = useState<'branch' | 'uncommitted' | 'lastCommit'>(t?.parentBranch ? 'branch' : 'uncommitted');
  const [data, setData] = useState<ReturnType<typeof parseReview> | null | 'failed'>(null);
  const [summary, setSummary] = useState<Summary | null | 'failed'>(null);
  const [sel, setSel] = useState<string | null>(null);
  const [landing, setLanding] = useState<{ mode: 'merge' | 'squash' | 'pr'; pick?: boolean } | null>(null);
  const [branches, setBranches] = useState<string[]>([]);
  const [reloads, setReloads] = useState(0);
  const [report, setReport] = useState<string | null>(null);
  const openMenu = useMenu();
  const wm = useWindows();
  const noCode = t ? isNoCode(t) : false;
  const target = t ? landingTarget(t) ?? '' : '';

  const load = useCallback(async () => {
    if (!t) return;
    setData(null);
    if (t.worktreeDir) {
      const base: Base = baseKind === 'branch' && t.parentBranch ? { kind: 'branch', parent: t.parentBranch } : baseKind === 'lastCommit' ? { kind: 'lastCommit' } : { kind: 'uncommitted' };
      try { const out = await host.guestExec(t.profileID, reviewCommand(t.worktreeDir, base), 30); const d = parseReview(out); setData(d); setSel(s => s && d.files.some(f => f.path === s) ? s : d.files[0]?.path ?? null); }
      catch { setData('failed'); }
    } else setData('failed');
    if (t.branch && target && (t.rootRepo || t.worktreeDir)) {
      try { setSummary(parseSummary(await host.guestExec(t.profileID, summaryCommand(t.rootRepo ?? t.worktreeDir!, t.worktreeDir, t.branch, target), 20))); }
      catch { setSummary('failed'); }
    } else setSummary('failed');
    if (t.rootRepo) {
      try {
        const out = await host.guestExec(t.profileID, `git -C ${q(t.rootRepo)} for-each-ref refs/heads --format='%(refname:short)' 2>/dev/null | head -50`, 15);
        setBranches(out.split('\n').filter(b => b && !b.startsWith('wt/')));
      } catch {}
    }
    if (isNoCode(t) && report == null) {
      host.request<any>('GET', `/tasks/${seg(t.id)}/transcript`, undefined, { timeoutMs: 100_000 } as any).then(r => {
        if (!r?.transcript) return;
        const items = parseTranscript(b64utf8(r.transcript));
        const turn: string[] = [];
        for (let i = items.length - 1; i >= 0; i--) { const it = items[i]; if (it.kind === 'user') break; if (it.kind === 'assistant' && it.text.trim()) turn.unshift(it.text.trim()); }
        setReport(turn.slice(-3).join('\n\n') || null);
      }).catch(() => {});
    }
  }, [host, t?.id, t?.worktreeDir, baseKind, reloads]); // eslint-disable-line
  useEffect(() => { load(); }, [load]);
  useEffect(() => { if (confirmMode && t?.stage === 'testing') setLanding({ mode: confirmMode }); }, []); // eslint-disable-line
  useEffect(() => { if (t && t.stage !== 'testing' && t.stage !== 'inProgress') { /* left Review */ } }, [t?.stage]); // eslint-disable-line

  if (!t || !st) return <div className="bx-rv"><Loading /></div>;

  const agent = workerName(t);
  const ws = workspaceOf(st, t.profileID)?.name ?? '';
  const parts: string[] = [t.branch ? `${agent} worked on ${t.branch} in ${ws}` : `${agent} worked in ${ws}`, t.repoPath];
  if (summary && summary !== 'failed' && !noCode) {
    parts.push(summary.ahead === 1 ? '1 commit' : `${summary.ahead} commits`);
    parts.push(`${summary.files === 1 ? '1 file' : `${summary.files} files`} (+${summary.ins} −${summary.del}) vs ${target}`);
    if (summary.uncommitted > 0) parts.push(`${summary.uncommitted} uncommitted`);
    if (summary.behind > 0) parts.push(summary.behind === 1 ? `${target} moved 1 commit since` : `${target} moved ${summary.behind} commits since`);
    parts.push(summary.targetDirty == null ? `${target} not checked out` : summary.targetDirty === 0 ? `${target} checkout clean` : `${target} checkout has uncommitted changes`);
    parts.push(`remote: ${summary.remote ?? 'none'}`);
  } else if (summary === 'failed' && t.branch) parts.push("can't reach the machine for the details");
  const sumText = parts.filter(Boolean).join(' · ');
  const markDone = () => confirm({
    title: 'Mark done without merging?',
    message: `Nothing is merged. The branch ${t.branch ?? ''} and its checkout are kept in the workspace.` + droppedSuffix(t),
    buttons: [{ label: 'Mark Done', role: 'default', action: () => { post(host, t.id, 'mark-done'); close(); } }, { label: 'Cancel', role: 'cancel' }],
  });
  const discard = () => confirm({
    title: 'Discard this branch?',
    message: `The branch ${t.branch ?? ''} and its checkout are deleted and the agent's session is put away. The task goes to Done as closed without merging; its transcript is kept.` + droppedSuffix(t),
    buttons: [{ label: 'Discard Branch', role: 'destructive', action: () => { post(host, t.id, 'close-no-merge'); close(); } }, { label: 'Cancel', role: 'cancel' }],
  });
  const openSession = () => { const s = taskSession(t, st); if (s) ctx.select({ kind: 'session', sessionID: s.id }); else ctx.select({ kind: 'workspace', workspaceID: t.profileID }); };
  const prFirst = (t.finish === 'pullRequest' || (st.workspaces?.find(w => w.id === t.profileID) as any)?.taskFinish === 'pullRequest') && (summary === 'failed' || (summary && summary.remote));
  const landingBusy = !!t.landing && t.landing.phase !== 'needsYou';
  const undelivered = (t.comments ?? []).filter(c => !c.sentAt && c.undelivered).length;
  const file = data && data !== 'failed' ? data.files.find(f => f.path === sel) : undefined;

  return (
    <div className="bx-rv">
      <div className="bx-rv-banner">
        <div className="bx-rv-summary l2 selectable" title={sumText}>{sumText}</div>
        {noCode && (
          <div className="bx-rv-report">
            <div className="bd-hrow" style={{ gap: 8 }}>
              <span className="bx-rv-report-title"><SF name="chevron.down" size={10} />{agent}'s final report</span>
              <span className="secondary" style={{ fontSize: 10.5 }}>No code changes to merge</span>
              <span className="spacer" />
              <Button size="small" onClick={() => openTaskTranscript(wm, host, t.id)}>View Transcript</Button>
            </div>
            {(report ?? t.deliverySummary) ? <div className="bx-rv-report-body"><Markdown compact text={report ?? t.deliverySummary ?? ''} /></div>
              : <div className="tertiary" style={{ fontSize: 11 }}>Reading the agent's report…</div>}
          </div>
        )}
        {t.landing && t.stage === 'testing' && (
          <div className="bd-hrow bx-rv-landing" style={{ gap: 8 }}>
            {t.landing.phase === 'needsYou' ? <>
              <SF name="hand.raised.fill" size={12} color="var(--red)" />
              <span className="l3" style={{ color: 'var(--red)' }}>Needs you — {t.landing.detail ?? ''}</span><span className="spacer" />
              <Button size="small" onClick={openSession}>Open Session</Button>
              <Button size="small" onClick={() => post(host, t.id, 'retry-landing')}>Retry</Button>
              <Button size="small" onClick={() => post(host, t.id, 'cancel-landing')}>Cancel Landing</Button>
            </> : <>
              <Spinner size={12} /><span className="l2">{landingLine(t)}</span><span className="spacer" />
              {t.landing.phase === 'agentLanding' && <><Button size="small" onClick={openSession}>Open Session</Button><Button size="small" onClick={() => post(host, t.id, 'cancel-landing')}>Cancel Landing</Button></>}
            </>}
          </div>
        )}
        {t.stage === 'testing' && undelivered > 0 && (
          <div className="bd-hrow bx-rv-landing" style={{ gap: 8 }}>
            <SF name="exclamationmark.bubble.fill" size={12} color="var(--orange)" />
            <span className="l2">{undelivered === 1 ? "1 comment didn't reach the agent before it handed the task back. Send it back again?" : `${undelivered} comments didn't reach the agent before it handed the task back. Send them back again?`}</span>
            <span className="spacer" /><Button size="small" onClick={() => { post(host, t.id, 'send-back'); close(); }}>Send Back Again</Button>
          </div>
        )}
        <div className="bd-hrow" style={{ gap: 8 }}>
          {t.stage !== 'testing' ? <span className="secondary" style={{ fontSize: 11 }}>This task isn't in Review any more.</span>
            : noCode ? <Button variant="prominent" icon="checkmark.circle.fill" title="The task produced no code: it goes to Done as it is." onClick={() => { post(host, t.id, 'mark-done'); close(); }}>Mark Done</Button>
            : t.pullRequestURL && t.delegationID ? <>
              <Button variant="prominent" icon="arrow.triangle.pull" onClick={() => { const u = safeHref(t.pullRequestURL); if (u) window.open(u, '_blank', 'noopener'); }}>View Pull Request #{t.pullRequestURL.split('/').pop()}</Button>
              <Button title="The pull request was merged on the forge: the task goes to Done as merged." onClick={() => { post(host, t.id, 'mark-merged'); close(); }}>Mark Merged</Button>
              <Button icon="checkmark.circle" onClick={markDone} title="Mark done without merging — the branch is kept.">Mark Done</Button>
            </> : <>
              {summary == null ? <Button disabled><Spinner size={12} /> Checking the branch…</Button> : (
                <span className="bx-rv-split">
                  <Button variant="prominent" disabled={landingBusy} icon={prFirst ? 'arrow.triangle.pull' : 'arrow.triangle.merge'}
                          title={prFirst ? 'Open a pull request for the branch.' : 'Merge the branch.'}
                          onClick={() => setLanding({ mode: prFirst ? 'pr' : 'merge' })}>{prFirst ? 'Open Pull Request' : `Merge into ${target || 'parent'}`}</Button>
                  <Button variant="prominent" disabled={landingBusy} title="Other ways to land it" icon="chevron.down" onClick={e => {
                    const items: MenuItem[] = [];
                    if (prFirst) items.push({ label: `Merge into ${target || 'parent'}`, action: () => setLanding({ mode: 'merge' }) });
                    else if (summary !== 'failed' && summary.remote) items.push({ label: 'Open Pull Request', action: () => setLanding({ mode: 'pr' }) });
                    items.push({ label: `Squash & Merge into ${target || 'parent'}`, action: () => setLanding({ mode: 'squash' }) },
                      { label: 'Merge into Another Branch…', action: () => setLanding({ mode: 'merge', pick: true }) }, { separator: true },
                      { label: 'Keep Branch — Mark Done', action: markDone });
                    openMenu((e.currentTarget as HTMLElement).getBoundingClientRect(), items);
                  }} />
                </span>
              )}
              <Button icon="checkmark.circle" onClick={markDone} title="Mark done without merging — the branch is kept.">Mark Done</Button>
            </>}
          {t.stage === 'testing' && (
            <Button icon="ellipsis.circle" onClick={e => openMenu((e.currentTarget as HTMLElement).getBoundingClientRect(), [
              { label: 'Open Session', action: openSession },
              { label: 'View Transcript', action: () => openTaskTranscript(wm, host, t.id) },
              ...(t.branch ? [{ separator: true } as MenuItem, { label: 'Discard Branch…', destructive: true, action: discard }] : []),
            ])}>More</Button>
          )}
          <span className="spacer" />
        </div>
      </div>
      {!noCode && (
        <div className="bx-rv-body">
          <div className="bx-rv-files">
            <div className="bx-rv-files-head">
              <PopUp value={baseKind} onChange={v => setBaseKind(v as any)} options={[
                ...(t.parentBranch ? [{ value: 'branch' as const, label: `Since ${t.parentBranch}` }] : []),
                { value: 'uncommitted' as const, label: 'Uncommitted' }, { value: 'lastCommit' as const, label: 'Last commit' }]} />
              <span className="spacer" />
              <button className="btn icon" title="Reload" onClick={() => setReloads(r => r + 1)}><SF name="arrow.clockwise" size={13} /></button>
            </div>
            {data === null ? <Loading /> : data === 'failed' ? <div className="bx-rv-empty">Can't read the branch — the workspace isn't reachable or its worktree is gone.</div>
              : data.files.length === 0 ? <div className="bx-rv-empty">No changes</div>
              : data.files.map(f => (
                <button key={f.path} className={cx('bx-rv-file', f.path === sel && 'on')} onClick={() => setSel(f.path)} title={f.path}>
                  <span className={'bx-rv-st ' + f.status}>{f.status === 'added' ? 'A' : f.status === 'deleted' ? 'D' : f.status === 'renamed' ? 'R' : 'M'}</span>
                  <span className="truncate" style={{ flex: 1, direction: 'rtl', textAlign: 'left' }}>{f.path}</span>
                  {(t.comments ?? []).some(c => c.file === f.path) && <SF name="text.bubble.fill" size={10} color="var(--purple)" />}
                  <span className="bx-rv-counts"><span style={{ color: 'var(--green)' }}>+{f.adds}</span> <span style={{ color: 'var(--red)' }}>−{f.dels}</span></span>
                </button>
              ))}
            {data && data !== 'failed' && data.log.length > 0 && (
              <div className="bx-rv-log"><div className="bx-te-label">Commits</div>{data.log.map((l, i) => <div key={i} className="mono truncate" title={l}>{l}</div>)}</div>
            )}
          </div>
          <div className="bx-rv-diff">
            {file ? <DiffView host={host} t={t} file={file} /> : <div className="bx-rv-empty" style={{ margin: 'auto' }}>{data && data !== 'failed' && data.files.length ? 'Select a file' : ''}</div>}
            <GeneralComments host={host} t={t} />
          </div>
        </div>
      )}
      {landing && t && (
        <LandingSheet t={t} mode={landing.mode} pick={!!landing.pick} summary={summary && summary !== 'failed' ? summary : undefined} branches={branches.filter(b => b !== t.branch)}
                      onCancel={() => setLanding(null)}
                      onConfirm={(tgt, keep, push) => {
                        const body: any = { mode: landing.mode, keepBranch: keep, push };
                        if (tgt) body.target = tgt;
                        post(host, t.id, 'land', body); setLanding(null);
                      }} />
      )}
    </div>
  );
}

function DiffView({ host, t, file }: { host: RemoteHost; t: CodingTask; file: DiffFile }) {
  const [commenting, setCommenting] = useState<number | null>(null);
  const [text, setText] = useState('');
  const comments = (t.comments ?? []).filter(c => c.file === file.path);
  const submit = () => {
    if (!text.trim() || commenting == null) return;
    post(host, t.id, 'comment', { text: text.trim(), file: file.path, line: commenting });
    setText(''); setCommenting(null);
  };
  return (
    <div className="bx-rv-diff-file">
      <div className="bx-rv-diff-head mono">{file.path}<span className="spacer" /><span className="bx-rv-counts"><span style={{ color: 'var(--green)' }}>+{file.adds}</span> <span style={{ color: 'var(--red)' }}>−{file.dels}</span></span></div>
      {file.binary ? <div className="bx-rv-empty">Binary file</div> : (
        <div className="bx-rv-lines mono selectable">
          {file.lines.map((l, i) => (
            <React.Fragment key={i}>
              <div className={'bx-rv-line ' + l.kind} onDoubleClick={() => l.newLine != null && setCommenting(l.newLine)}>
                <span className="bx-rv-ln">{l.kind === 'hunk' ? '' : l.oldLine ?? ''}</span>
                <span className="bx-rv-ln">{l.kind === 'hunk' ? '' : l.newLine ?? ''}</span>
                {l.newLine != null && <button className="bx-rv-add-c" title="Comment on this line" onClick={() => setCommenting(l.newLine!)}><SF name="plus" size={10} weight={700} /></button>}
                <span className="bx-rv-code">{l.kind === 'add' ? '+' : l.kind === 'del' ? '-' : l.kind === 'ctx' ? ' ' : ''}{l.text}</span>
              </div>
              {l.newLine != null && comments.filter(c => c.line === l.newLine).map(c => <CommentRow key={c.id} host={host} t={t} c={c} />)}
              {commenting != null && commenting === l.newLine && l.kind !== 'del' && (
                <div className="bx-rv-cbox">
                  <textarea autoFocus value={text} placeholder="Leave a comment for the agent…" onChange={e => setText(e.target.value)}
                            onKeyDown={e => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) submit(); if (e.key === 'Escape') setCommenting(null); }} />
                  <div className="bd-hrow" style={{ gap: 6, justifyContent: 'flex-end' }}>
                    <Button size="small" onClick={() => setCommenting(null)}>Cancel</Button>
                    <Button size="small" variant="prominent" disabled={!text.trim()} onClick={submit}>Comment</Button>
                  </div>
                </div>
              )}
            </React.Fragment>
          ))}
        </div>
      )}
    </div>
  );
}

function CommentRow({ host, t, c }: { host: RemoteHost; t: CodingTask; c: CodingTask['comments'][number] }) {
  return (
    <div className="bx-rv-comment">
      <SF name="text.bubble.fill" size={11} color="var(--purple)" />
      <span className="selectable" style={{ flex: 1 }}>{c.text}</span>
      <span className="tertiary" style={{ fontSize: 10 }}>{c.sentAt ? 'sent' : 'draft'}</span>
      {!c.sentAt && <button className="bd-link-btn" title="Remove" onClick={() => post(host, t.id, 'comment-remove', { comment: c.id })}><SF name="xmark" size={10} /></button>}
    </div>
  );
}

function GeneralComments({ host, t }: { host: RemoteHost; t: CodingTask }) {
  const [text, setText] = useState('');
  const general = (t.comments ?? []).filter(c => !c.file);
  const unsent = unsentComments(t);
  return (
    <div className="bx-rv-general">
      {general.map(c => <CommentRow key={c.id} host={host} t={t} c={c} />)}
      <div className="bd-hrow" style={{ gap: 6 }}>
        <input className="field" style={{ flex: 1, height: 26 }} value={text} placeholder="A comment on the whole change…" onChange={e => setText(e.target.value)}
               onKeyDown={e => { if (e.key === 'Enter' && text.trim()) { post(host, t.id, 'comment', { text: text.trim() }); setText(''); } }} />
        {unsent > 0 && t.stage === 'testing' && (
          <Button variant="prominent" icon="arrow.uturn.backward" title="Send the comments to the agent: the task goes back to In Progress."
                  onClick={() => post(host, t.id, 'send-back')}>Send Back ({unsent === 1 ? '1 comment' : `${unsent} comments`})</Button>
        )}
      </div>
    </div>
  );
}

function LandingSheet({ t, mode, pick, summary, branches, onCancel, onConfirm }: {
  t: CodingTask; mode: 'merge' | 'squash' | 'pr'; pick: boolean; summary?: Summary; branches: string[];
  onCancel: () => void; onConfirm: (target: string, keep: boolean, push: boolean) => void;
}) {
  const [target, setTarget] = useState(pick ? branches[0] ?? '' : landingTarget(t) ?? '');
  const [keep, setKeep] = useState(false);
  const [push, setPush] = useState(() => { try { return localStorage.getItem('bromure.tasks.landing.push') === '1'; } catch { return false; } });
  const agent = workerName(t), branch = t.branch ?? '';
  const known = target === (landingTarget(t) ?? '') ? summary : undefined;
  const remote = mode === 'pr' ? undefined : summary?.remote;
  const title = mode === 'pr' ? `Open a pull request into ${target}?` : mode === 'squash' ? `Squash & merge into ${target}?` : `Merge into ${target}?`;
  let warning: string | undefined;
  if (mode !== 'pr' && known?.targetDirty) warning = `The ${target} checkout has uncommitted changes — if they touch the same files, ${agent} can't merge until you commit or stash them there.`;
  let text: string;
  if (mode === 'pr') text = `${agent}, the agent that wrote it, will rebase onto ${target}, run the tests, push ${branch} to ${known?.remote ?? 'origin'} and open a pull request. You'll see its progress on the task and in its session.`;
  else if (!known) text = `${agent}, the agent that wrote it, will rebase onto ${target}, fix conflicts, run the tests and merge. You'll see its progress on the task and in its session.`;
  else if (known.ahead === 0 && known.uncommitted === 0) { text = `${branch} adds nothing ${target} doesn't already have: the task goes to Done.`; warning = undefined; }
  else if (known.behind === 0 && known.uncommitted === 0 && known.ahead > 0 && (mode !== 'squash' || known.ahead === 1))
    text = known.targetDirty ? `${branch} is ahead of ${target}: Bromure merges it directly.` : `${branch} is ahead of ${target} with nothing in the way: Bromure merges it directly.`;
  else {
    const steps: string[] = [];
    if (known.uncommitted > 0) steps.push("commit what's left uncommitted");
    if (known.behind > 0) steps.push(`rebase onto ${target} and fix conflicts`);
    if (mode === 'squash' && known.ahead + (known.uncommitted > 0 ? 1 : 0) > 1) steps.push('squash it into one commit');
    steps.push('run the tests', 'merge');
    text = `${agent}, the agent that wrote it, will ${new Intl.ListFormat('en', { type: 'conjunction' }).format(steps)}. You'll see its progress on the task and in its session.`;
  }
  const pending = unsentComments(t);
  return (
    <Sheet width={480} onClose={onCancel}>
      <div className="bx-bm">
        <div className="bx-bm-title">{title}</div>
        {pick && <div className="bd-hrow" style={{ gap: 8 }}>Into <PopUp bordered value={target} onChange={setTarget} options={branches.map(b => ({ value: b, label: b }))} /></div>}
        <div className="bx-bm-text">{text}</div>
        {warning && <div className="bx-bm-warn"><SF name="exclamationmark.triangle.fill" size={12} />{warning}</div>}
        {pending > 0 && <div className="bx-bm-warn"><SF name="exclamationmark.bubble.fill" size={12} />{pending === 1 ? "1 review comment hasn't reached the agent yet — landing now merges without it." : `${pending} review comments haven't reached the agent yet — landing now merges without them.`}</div>}
        {mode === 'pr' ? <div className="secondary" style={{ fontSize: 12 }}>Afterwards the session is archived; the branch stays for the pull request.</div>
          : !t.delegationID && <>
            <div className="secondary" style={{ fontSize: 12 }}>{keep ? 'Afterwards the session is archived; the branch and its checkout are kept.' : 'Afterwards the branch is removed and the session archived.'}</div>
            <Checkbox checked={keep} onChange={setKeep}>Keep branch</Checkbox>
          </>}
        {remote && (
          <div className="bd-stack" style={{ gap: 4 }}>
            <Checkbox checked={push} onChange={v => { setPush(v); try { localStorage.setItem('bromure.tasks.landing.push', v ? '1' : '0'); } catch {} }}>Push {target} to {remote}</Checkbox>
            {push && <div className="secondary" style={{ fontSize: 12 }}>Done once {remote}/{target} has it. If {target} moved on, {agent} pulls, resolves conflicts and pushes.</div>}
          </div>
        )}
        <div className="bd-hrow" style={{ gap: 8, justifyContent: 'flex-end' }}>
          <Button onClick={onCancel}>Cancel</Button>
          <Button variant="prominent" disabled={!target} onClick={() => onConfirm(target, keep, !!remote && push)}>
            {mode === 'pr' ? 'Open Pull Request' : remote && push ? 'Merge & Push' : 'Merge'}
          </Button>
        </div>
      </div>
    </Sheet>
  );
}
